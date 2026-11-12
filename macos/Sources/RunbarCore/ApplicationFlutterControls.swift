import Foundation

/// Uses the compiler services registered by a *live* Flutter tool. A standalone
/// VM's reloadSources/reassemble cannot compile changed Flutter source files.
public actor ApplicationFlutterControls {
    public struct Availability: Equatable, Sendable {
        public let actions: Set<FlutterRunAction>
        public let message: String
    }
    private enum Failure: Error, LocalizedError {
        case unavailable, wrongProcess, notReady, ambiguous, rejected(Int), timeout
        var errorDescription: String? {
            switch self {
            case .unavailable: return "热更新连接已中断，请重新连接 App；日志和网络监听可继续使用。"
            case .wrongProcess: return "调试服务已不属于所选 App，已停止热更新连接。"
            case .notReady: return "当前 App 尚未提供此操作；请保持原 IDE / flutter run 调试会话连接。"
            case .ambiguous: return "检测到多个 Flutter 编译服务，暂不执行操作，请在原调试工具中处理。"
            case .rejected(let code): return "Flutter 工具未能完成操作（错误码 \(code)），请查看原 IDE / flutter run 的编译输出。"
            case .timeout: return "热更新等待超时，目标可能仍在处理。请在原调试工具确认结果后重新连接 App。"
            }
        }
    }
    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
        let sender: Task<Void, Never>
    }
    private let processID: Int32
    private let connection: any VMEventConnection
    private let handler: @Sendable (Availability) async -> Void
    private var startup: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var pending: [String: Pending] = [:]
    private var services: [String: FlutterRunAction] = [:]
    private var ready = false
    private var closed = false
    private var working = false
    private var lastAvailability: Availability?

    public init(endpoint: VMServiceEndpoint, processID: Int32, connection: (any VMEventConnection)? = nil,
                handler: @escaping @Sendable (Availability) async -> Void) {
        self.processID = processID; self.connection = connection ?? VMEventSocket(endpoint: endpoint)
        self.handler = handler
    }
    public func start() {
        guard startup == nil, !closed else { return }
        startup = Task { await self.initialize() }
    }
    public func disconnect() async {
        await finish(CancellationError(), notify: false)
    }
    private func initialize() async {
        receiver = Task { await self.receive() }
        do {
            try await checkProcess()
            _ = try await request("streamListen", parameters: ["streamId": "Service"])
            try Task.checkCancellation()
            guard !closed else { return }
            ready = true
            await publish()
        } catch {
            await finish(error, notify: !(error is CancellationError))
        }
    }

    public func perform(_ action: FlutterRunAction) async throws {
        guard ready, !closed, !working, action == .hotReload || action == .hotRestart else { throw Failure.notReady }
        let method = try service(for: action)
        working = true
        defer { working = false }
        do {
            // Recheck identity and registration after each suspension. Never send
            // a command based on a historical PID, isolate, or tool registration.
            try await checkProcess()
            var parameters: [String: Any] = ["pause": false]
            if action == .hotReload {
                let result = try responseObject(try await request("_flutter.listViews"))
                let views = result["views"] as? [[String: Any]] ?? []
                let isolates = Set(views.compactMap { ($0["isolate"] as? [String: Any])?["id"] as? String })
                guard isolates.count == 1, let isolate = isolates.first, isolate.utf8.count <= 512 else { throw Failure.notReady }
                parameters["isolateId"] = isolate; parameters["force"] = false
            }
            try Task.checkCancellation()
            guard !closed, try service(for: action) == method else { throw Failure.notReady }
            let response = try responseObject(try await request(method, parameters: parameters, seconds: 120))
            guard response["type"] as? String == "Success" else { throw Failure.rejected(-1) }
        } catch let failure as Failure {
            // A timed-out mutation may still be running at the tool. Close this
            // control session instead of enabling an accidental second restart.
            if case .timeout = failure { await finish(failure, notify: true) }
            if case .wrongProcess = failure { await finish(failure, notify: true) }
            throw failure
        }
    }
    private func checkProcess() async throws {
        let object = try responseObject(try await request("getVM"))
        guard (object["pid"] as? NSNumber)?.int64Value == Int64(processID) else { throw Failure.wrongProcess }
    }
    private func service(for action: FlutterRunAction) throws -> String {
        let methods = services.filter { $0.value == action }.map(\.key)
        guard methods.count <= 1 else { throw Failure.ambiguous }
        guard let method = methods.first else { throw Failure.notReady }
        return method
    }
    private func publish() async {
        guard ready, !closed else { return }
        let actions = Set([FlutterRunAction.hotReload, .hotRestart].filter { (try? service(for: $0)) != nil })
        let ambiguous = services.values.contains { action in services.values.filter { $0 == action }.count > 1 }
        let state = Availability(actions: actions, message: ambiguous ? Failure.ambiguous.localizedDescription :
            actions.isEmpty ? "未提供热更新服务；请保持原 IDE / flutter run 的 Debug 调试连接，必要时使用其完整 DevTools 链接重新关联。" :
            "通过原 Flutter 调试工具编译并执行；编译详情见原 IDE / flutter run 输出。")
        guard state != lastAvailability else { return }
        lastAvailability = state; await handler(state)
    }

    private func receive() async {
        do {
            while !closed {
                try Task.checkCancellation()
                let data = try await connection.receive()
                guard !closed else { return }
                guard data.count <= 1024 * 1024,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unavailable }
                if let id = object["id"] as? String, pending[id] != nil {
                    if let error = object["error"] as? [String: Any] {
                        resolve(id, .failure(Failure.rejected((error["code"] as? NSNumber)?.intValue ?? -1)))
                    } else { resolve(id, .success(data)) }
                } else if object["method"] as? String == "streamNotify",
                          let params = object["params"] as? [String: Any], params["streamId"] as? String == "Service",
                          let event = params["event"] as? [String: Any],
                          let method = event["method"] as? String, !method.isEmpty, method.utf8.count <= 512 {
                    if event["kind"] as? String == "ServiceUnregistered" { services[method] = nil }
                    else if event["kind"] as? String == "ServiceRegistered", event["alias"] as? String == "Flutter Tools",
                            let service = event["service"] as? String, method.hasSuffix("." + service),
                            method.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) {
                        // Never silently ignore another provider: doing so could
                        // incorrectly make an ambiguous operation look safe.
                        if ["reloadSources", "hotRestart"].contains(service), services[method] == nil, services.count >= 16 {
                            throw Failure.ambiguous
                        }
                        switch service {
                        case "reloadSources": services[method] = .hotReload
                        case "hotRestart": services[method] = .hotRestart
                        default: break
                        }
                    }
                    await publish()
                }
            }
        } catch { await finish((error as? Failure) ?? Failure.unavailable, notify: !Task.isCancelled) }
    }
    private func request(_ method: String, parameters: [String: Any] = [:], seconds: UInt64 = 5) async throws -> Data {
        try Task.checkCancellation()
        guard !closed, pending.count < 4 else { throw Failure.unavailable }
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": parameters])
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task {
                    do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
                    catch { return }
                    self.resolve(id, .failure(Failure.timeout))
                }
                let sender = Task {
                    do { try await self.connection.send(data) }
                    catch { if !Task.isCancelled { await self.finish(Failure.unavailable, notify: true) } }
                }
                pending[id] = Pending(continuation: continuation, timeout: timeout, sender: sender)
            }
        }, onCancel: { Task { await self.cancelRequest(id) } })
    }
    private func cancelRequest(_ id: String) { resolve(id, .failure(CancellationError())) }
    private func resolve(_ id: String, _ value: Result<Data, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        if case .failure = value { request.sender.cancel() }
        request.continuation.resume(with: value)
    }
    private func responseObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any] else { throw Failure.unavailable }
        return result
    }
    private func finish(_ error: Error, notify: Bool) async {
        guard !closed else { return }
        closed = true; ready = false; services.removeAll()
        startup?.cancel(); startup = nil; receiver?.cancel(); receiver = nil
        for id in Array(pending.keys) { resolve(id, .failure(error)) }
        await connection.close()
        if notify {
            // Do not expose raw URLSession / RPC data containing authenticated URLs.
            let message = (error as? Failure)?.localizedDescription ?? Failure.unavailable.localizedDescription
            await handler(Availability(actions: [], message: message))
        }
    }
}
