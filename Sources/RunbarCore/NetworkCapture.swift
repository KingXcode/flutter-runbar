import Foundation

public struct NetworkCaptureUpdate: Sendable {
    public let supported: Bool
    public let requestsUpdated: Int
    public let pausedIsolates: [String]
}

/// One instance per live run. Call poll serially; each request is awaited and
/// payload fetches have a bounded per-poll budget. No list of all requests or
/// pending body jobs is retained in RAM. Pending work is selected from SQLite.
public actor NetworkCaptureSession {
    private let endpoint: VMServiceEndpoint
    private let transport: any VMServiceTransport
    private let limits: NetworkLimits
    private let directory: URL
    private var store: NetworkStore?
    private var finished = false
    private var epoch = UUID().uuidString
    private var vmStart: Int64?
    private var vmPID: Int64?
    private var cursors: [String: Int64] = [:]
    private var lastPaused: [String] = []
    private var bodyTurn = 0
    public init(directory: URL, endpoint: VMServiceEndpoint, transport: any VMServiceTransport = HTTPVMServiceTransport(), limits: NetworkLimits = NetworkLimits()) {
        self.endpoint = endpoint; self.transport = transport; self.limits = limits
        self.directory = directory
    }
    private func rpc(_ method: String, _ parameters: [String: String] = [:]) async throws -> [String: Any] {
        let data = try await transport.call(endpoint: endpoint, method: method, parameters: parameters)
        try Task.checkCancellation()
        guard data.count <= limits.responseBytes else { throw VMServiceError.responseTooLarge }
        return try autoreleasepool {
            guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VMServiceError.invalidResponse }
            if let error = envelope["error"] as? [String: Any] {
                if (error["code"] as? NSNumber)?.intValue == -32601 { throw VMServiceError.unsupported }
                throw VMServiceError.invalidResponse
            }
            guard let result = envelope["result"] as? [String: Any] else { throw VMServiceError.invalidResponse }
            return result
        }
    }
    public func poll() async throws -> NetworkCaptureUpdate {
        guard !finished else { throw CancellationError() }
        if store == nil { store = try NetworkStore(directory: directory, limits: limits) }
        guard let store else { throw CancellationError() }
        let vm = try await rpc("getVM")
        let start = (vm["startTime"] as? NSNumber)?.int64Value
        let pid = (vm["pid"] as? NSNumber)?.int64Value
        // Some Dart VMs derive startTime from wall-clock minus uptime, so it
        // can jitter between calls. Prefer the stable PID; the connection and
        // isolate identity cover hot restart and endpoint replacement.
        let restarted: Bool
        if let pid, let previous = vmPID { restarted = pid != previous }
        else if let start, let previous = vmStart { restarted = abs(Double(start) - Double(previous)) > 2000 }
        else { restarted = false }
        if restarted {
            try store.finalizePending(note: "VM 已重启，正文未缓存"); epoch = UUID().uuidString; cursors = [:]
        }
        vmStart = start; vmPID = pid
        guard let isolates = vm["isolates"] as? [[String: Any]], isolates.count <= 32 else { throw VMServiceError.invalidResponse }
        let ids = Set(isolates.compactMap { $0["id"] as? String })
        cursors = cursors.filter { ids.contains($0.key) }
        var supported = false, updated = 0, paused: [String] = [], bodyAllowance = limits.bodiesPerPoll
        // Rotate priority so one busy isolate cannot starve another's payloads.
        let ordered = Array(isolates.dropFirst(bodyTurn)) + Array(isolates.prefix(bodyTurn))
        bodyTurn = isolates.isEmpty ? 0 : (bodyTurn + 1) % isolates.count
        for reference in ordered {
            try Task.checkCancellation()
            guard let id = reference["id"] as? String else { continue }
            let isolate = try await rpc("getIsolate", ["isolateId": id])
            let extensions = isolate["extensionRPCs"] as? [String] ?? []
            guard extensions.contains("ext.dart.io.getHttpProfile") else { continue }
            supported = true
            let pauseKind = (isolate["pauseEvent"] as? [String: Any])?["kind"] as? String ?? ""
            if pauseKind.hasPrefix("Pause") { paused.append(id) }
            let parameters = ["isolateId": id]
            _ = try await rpc("ext.dart.io.httpEnableTimelineLogging", parameters.merging(["enabled": "true"]) { _, rhs in rhs })
            if cursors[id] == nil {
                // Obtain the VM's own clock without pulling its whole retained
                // history. A small overlap covers requests during attachment.
                let baseline = try await rpc("ext.dart.io.getHttpProfile", parameters.merging(["updatedSince": String(Int64.max)]) { _, rhs in rhs })
                guard let time = baseline["timestamp"] as? NSNumber else { throw VMServiceError.invalidResponse }
                cursors[id] = time.int64Value
            }
            let since = max(0, cursors[id]! - 1_000_000)
            let profile = try await rpc("ext.dart.io.getHttpProfile", parameters.merging(["updatedSince": String(since)]) { _, rhs in rhs })
            guard let values = profile["requests"] as? [[String: Any]], let timestamp = profile["timestamp"] as? NSNumber else { throw VMServiceError.invalidResponse }
            guard values.count <= limits.batchRequests else { throw RunbarError.message("单批网络请求超过 \(limits.batchRequests) 条，已暂停接收。") }
            let records = try autoreleasepool { try values.map { try NetworkRecord.parse($0, epoch: epoch, isolate: id) } }
            try store.upsert(records); updated += records.count
            cursors[id] = timestamp.int64Value
            if bodyAllowance > 0 {
                let pending = try store.pendingBodies(epoch: epoch, isolate: id)
                for record in pending.prefix(bodyAllowance) {
                    try Task.checkCancellation(); bodyAllowance -= 1
                    if (record.requestBytes ?? 0) > Int64(limits.bodyBytes) || (record.responseBytes ?? 0) > Int64(limits.bodyBytes) {
                        try store.markBody(record.id, state: .omitted, note: "请求或响应正文超过 1 MB 限制"); continue
                    }
                    do {
                        let detail = try await rpc("ext.dart.io.getHttpProfileRequest", ["isolateId": id, "id": record.requestID])
                        try Task.checkCancellation()
                        func bytes(_ key: String) throws -> Data {
                            guard let numbers = detail[key] as? [NSNumber] else { throw VMServiceError.invalidResponse }
                            guard numbers.count <= limits.bodyBytes else { throw VMServiceError.responseTooLarge }
                            var data = Data(capacity: numbers.count)
                            for number in numbers {
                                guard number.intValue >= 0 && number.intValue <= 255 else { throw VMServiceError.invalidResponse }
                                data.append(number.uint8Value)
                            }
                            return data
                        }
                        // Absent is different from a captured empty body.
                        guard detail["requestBody"] != nil, detail["responseBody"] != nil else {
                            try store.markBody(record.id, state: .unavailable, note: "当前 VM 未提供完整请求 / 响应正文"); continue
                        }
                        try store.saveBodies(record.id, request: bytes("requestBody"), response: bytes("responseBody"))
                    } catch is CancellationError { throw CancellationError() }
                    catch VMServiceError.responseTooLarge { try store.markBody(record.id, state: .omitted, note: "正文或 VM 返回超过大小限制") }
                    catch VMServiceError.unavailable { throw VMServiceError.unavailable }
                    catch let error as RunbarError { throw error }
                    catch { try store.markBody(record.id, state: .failed, note: "正文格式不受支持，或已被目标进程清理") }
                }
            }
        }
        lastPaused = paused
        return NetworkCaptureUpdate(supported: supported, requestsUpdated: updated, pausedIsolates: paused)
    }
    /// Explicit UI operation: this also clears DevTools' shared VM buffer and
    /// drops profiling for in-flight requests. The local SQLite cache remains.
    public func clearTargetBuffer() async throws {
        for id in Array(cursors.keys) {
            _ = try await rpc("ext.dart.io.clearHttpProfile", ["isolateId": id])
        }
        try store?.finalizePending(note: "目标采集缓冲已清理，正文未缓存"); cursors = [:]
    }
    public func resumePausedApplication() async throws {
        for id in lastPaused { _ = try await rpc("resume", ["isolateId": id]) }
        lastPaused = []
    }
    public func finish() throws {
        finished = true
        defer { store?.close(); store = nil }
        try store?.finalizePending()
    }
}
