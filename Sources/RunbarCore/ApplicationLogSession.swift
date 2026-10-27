import Foundation

public protocol VMEventConnection: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

/// A connection owns its socket only. It never sends kill/resume or OS signals.
public final class VMEventSocket: NSObject, URLSessionTaskDelegate, VMEventConnection, @unchecked Sendable {
    private var session: URLSession!
    private var socket: URLSessionWebSocketTask!
    public init(endpoint: VMServiceEndpoint) {
        super.init()
        var parts = URLComponents(url: endpoint.url.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.httpShouldSetCookies = false; configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 0
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        socket = session.webSocketTask(with: parts.url!); socket.maximumMessageSize = 1024 * 1024
        socket.resume()
    }
    public func send(_ data: Data) async throws { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
    public func receive() async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            let message = try await socket.receive()
            let data: Data
            switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw VMServiceError.invalidResponse }
            guard data.count <= 1024 * 1024 else { throw VMServiceError.responseTooLarge }
            return data
        }, onCancel: { self.socket.cancel(with: .goingAway, reason: nil) })
    }
    public func close() async { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public actor ApplicationLogSession {
    public enum Event: Sendable { case started(RunSession), connected(Set<String>), output(UUID), finished(RunSession) }
    private let root: URL
    private let endpoint: VMServiceEndpoint
    private let attachment: ApplicationAttachment
    private let connection: any VMEventConnection
    private let transport: any VMServiceTransport
    private let handler: @Sendable (Event) async -> Void
    private var task: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var value: RunSession?
    private var log: RunLog?
    private var pending = Data()
    private var ending = false
    private var logFailure = false
    public init(root: URL, endpoint: VMServiceEndpoint, attachment: ApplicationAttachment,
                connection: (any VMEventConnection)? = nil, transport: any VMServiceTransport = HTTPVMServiceTransport(limit: 512 * 1024),
                handler: @escaping @Sendable (Event) async -> Void) {
        self.root = root; self.endpoint = endpoint; self.attachment = attachment
        self.connection = connection ?? VMEventSocket(endpoint: endpoint); self.transport = transport; self.handler = handler
    }
    public func start() {
        guard task == nil, !ending else { return }
        task = Task { await self.run() }
    }
    public func disconnect() async {
        ending = true; task?.cancel(); await connection.close()
        await task?.value
    }
    private func run() async {
        var session = RunSession(projectPath: "", command: "监听 \(attachment.application.name)")
        session.attachment = attachment; value = session
        let store: SessionStore
        do {
            store = try SessionStore(root: root); try store.save(session)
            log = try RunLog(directory: store.directory(session.id))
        } catch {
            session.status = .failed; session.error = "无法创建应用监听记录，请检查本地存储权限。"
            session.endedAt = Date(); await connection.close(); await handler(.finished(session)); return
        }
        await handler(.started(session))
        var problem: String?
        var handshake: Task<Void, Never>?
        do {
            try Task.checkCancellation()
            try await append(Data("[应用监听] 从连接时开始记录；断开不会退出目标 App。\n".utf8))
            flushTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)); try await self?.flush() }
                    catch is CancellationError { return }
                    catch { await self?.storageFailed(); return }
                }
            }
            var waiting = Set(["Stdout", "Stderr", "Logging"]), accepted = Set<String>()
            for stream in waiting.sorted() {
                let request: [String: Any] = ["jsonrpc": "2.0", "id": stream, "method": "streamListen", "params": ["streamId": stream]]
                try await connection.send(JSONSerialization.data(withJSONObject: request))
            }
            handshake = Task { [connection] in
                do { try await Task.sleep(for: .seconds(6)); await connection.close() } catch {}
            }
            while true {
                try Task.checkCancellation()
                let data = try await connection.receive()
                try Task.checkCancellation()
                guard data.count <= 1024 * 1024, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VMServiceError.invalidResponse }
                if let id = object["id"] as? String, waiting.remove(id) != nil {
                    if object["result"] != nil { accepted.insert(id) }
                    if waiting.isEmpty {
                        handshake?.cancel(); handshake = nil
                        if accepted.isEmpty { try await append(Data("[应用监听] 当前 VM 未提供日志事件流；网络采集可单独使用。\n".utf8)) }
                        await handler(.connected(accepted))
                    }
                } else if object["method"] as? String == "streamNotify",
                          let params = object["params"] as? [String: Any], let stream = params["streamId"] as? String,
                          let event = params["event"] as? [String: Any] {
                    if ["Stdout", "Stderr"].contains(stream), let encoded = event["bytes"] as? String {
                        guard let bytes = Data(base64Encoded: encoded) else { throw VMServiceError.invalidResponse }
                        try await append(bytes)
                    } else if stream == "Logging", let record = event["logRecord"] as? [String: Any] {
                        let isolate = (event["isolate"] as? [String: Any])?["id"] as? String
                        let message = await string(record["message"], isolate: isolate)
                        let name = await string(record["loggerName"], isolate: isolate)
                        var text = name.isEmpty ? message : "[\(name)] \(message)"
                        for key in ["error", "stackTrace"] {
                            let detail = await string(record[key], isolate: isolate)
                            if !detail.isEmpty && detail != "null" { text += "\n" + detail }
                        }
                        try await append(Data((text + "\n").utf8))
                    }
                }
            }
        } catch is CancellationError {} catch {
            if !ending && !Task.isCancelled { problem = "应用连接已中断或日志读取失败；已收到的数据保存在本地，可重新连接。" }
        }
        ending = true; handshake?.cancel(); flushTask?.cancel(); flushTask = nil
        if logFailure { problem = "日志落盘失败，记录可能不完整，请检查磁盘空间与权限。" }
        await connection.close()
        do { try await flush(); try log?.close() }
        catch { problem = "日志落盘失败，记录可能不完整，请检查磁盘空间与权限。" }
        log = nil; pending = Data()
        session.endedAt = Date(); session.duration = session.endedAt!.timeIntervalSince(session.startedAt)
        session.status = problem == nil ? .stopped : .interrupted; session.error = problem
        do { try store.save(session) } catch { session.status = .failed; session.error = "监听已结束，但保存记录失败。" }
        value = session; await handler(.finished(session))
    }
    private func append(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        if pending.count + data.count > 64 * 1024 { try await flush() }
        if data.count > 64 * 1024 {
            try log?.append(data); if let value { await handler(.output(value.id)) }
        } else { pending.append(data) }
    }
    private func flush() async throws {
        guard !pending.isEmpty, let log else { return }
        let data = pending; pending = Data(); try log.append(data)
        if let value { await handler(.output(value.id)) }
    }
    private func storageFailed() async { logFailure = true; ending = true; task?.cancel(); await connection.close() }
    private func string(_ object: Any?, isolate: String?) async -> String {
        if let text = object as? String { return String(text.prefix(65_536)) }
        guard let reference = object as? [String: Any], let text = reference["valueAsString"] as? String else { return "" }
        guard reference["valueAsStringIsTruncated"] as? Bool == true else { return String(text.prefix(65_536)) }
        guard let id = reference["id"] as? String, let isolate else { return text + " [日志消息被 VM 截断]" }
        do {
            let data = try await transport.call(endpoint: endpoint, method: "getObject", parameters: ["isolateId": isolate, "objectId": id, "offset": "0", "count": "65536"])
            guard let result = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any],
                  let full = result["valueAsString"] as? String else { return text + " [日志对象已失效]" }
            return String(full.prefix(65_536)) + (result["valueAsStringIsTruncated"] as? Bool == true ? " [消息超过 64K 字符，已截断]" : "")
        } catch { return text + " [未能读取完整日志消息]" }
    }
}
