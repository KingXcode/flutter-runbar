import Foundation
import Darwin
import RunbarProcess

/// One mitmdump per managed command. Pipe ingestion is synchronous on a utility
/// queue: no unbounded Tasks / decoded events accumulate on the Swift side.
public final class ProxyCaptureProcess: @unchecked Sendable {
    private let configuration: ProxyLaunchConfiguration
    private let directory: URL
    private let epoch: String
    private let process = Process()
    private let condition = NSCondition()
    private let ingest = DispatchQueue(label: "runbar.proxy.ingest", qos: .utility)
    private let readers = DispatchGroup()
    private var port: UInt16?
    private var startupError: String?
    private var requestedStop = false
    private var diagnostic = Data()
    // The following properties belong exclusively to ingest.
    private var decoder = ProxyWireDecoder()
    private var network: NetworkStore?
    private var sockets: ProxyWebSocketStore?
    private var status = ProxyCaptureStatus()
    private var lastStatusWrite = Date.distantPast
    private var retryAt = Date.distantPast
    private var decodingFailed = false

    public init(configuration: ProxyLaunchConfiguration, directory: URL, epoch: UUID) {
        self.configuration = configuration; self.directory = directory; self.epoch = epoch.uuidString
    }
    public func start() throws -> ProxySessionInfo {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: configuration.executable.path), fm.fileExists(atPath: configuration.addon.path) else {
            throw RunbarError.message("内置抓包引擎或组件不可用，请重新安装 Runbar，或在高级选项中指定有效的自定义引擎。")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: configuration.certificateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configuration.certificateDirectory.path)
        // Preparing the certificate from the guide and starting another project
        // can overlap. Serialize CA initialization; never generate two roots.
        var certificateLock: Int32 = -1
        let lockError = rb_lock_file(configuration.certificateDirectory.appendingPathComponent(".setup.lock").path, &certificateLock)
        guard lockError == 0 else { throw RunbarError.message("无法准备证书目录：\(String(cString: strerror(lockError)))") }
        defer { rb_unlock_file(certificateLock) }
        ingest.sync { writeStatus(force: true) }
        process.executableURL = configuration.executable
        process.arguments = ["--quiet", "--mode", "regular", "--listen-host", "127.0.0.1", "--listen-port", "0",
            "--set", "confdir=\(configuration.certificateDirectory.path)", "--set", "connection_strategy=lazy",
            "--set", "flow_detail=0", "--set", "ssl_insecure=false", "--scripts", configuration.addon.path]
        var environment = ProcessInfo.processInfo.environment
        environment["RUNBAR_PROXY_DECRYPT_TLS"] = configuration.decryptTLS ? "1" : "0"
        environment["RUNBAR_PROXY_CONTROL"] = directory.appendingPathComponent("control").path
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.condition.lock()
            if self.port == nil { self.startupError = "代理启动失败（退出码 \(process.terminationStatus)）。" }
            self.condition.broadcast(); self.condition.unlock()
        }
        do { try process.run() }
        catch { ingest.sync { status.message = "代理未启动"; status.warning = error.localizedDescription; writeStatus(force: true) }; throw error }
        read(output.fileHandleForReading, capture: true)
        read(errors.fileHandleForReading, capture: false)
        condition.lock()
        let deadline = Date().addingTimeInterval(15)
        while port == nil, startupError == nil {
            if !condition.wait(until: deadline) { startupError = "代理启动超时，请检查 mitmdump 是否为 10 或更高版本。" }
        }
        let ready = port, error = startupError
        let detail = String(decoding: diagnostic, as: UTF8.self)
        condition.unlock()
        guard let ready, error == nil else {
            stop()
            throw RunbarError.message((error ?? "代理未提供监听端口。") + (detail.isEmpty ? "" : "\n" + detail))
        }
        return ProxySessionInfo(port: ready, decryptTLS: configuration.decryptTLS)
    }
    private func read(_ handle: FileHandle, capture: Bool) {
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                try? handle.close()
                if capture {
                    ingest.sync {
                        try? network?.finalizePending(note: "代理已结束，未收到完整正文")
                        network?.close(); network = nil; sockets?.close(); sockets = nil
                        status.running = false; status.message = "代理已结束"
                        condition.lock(); let stopped = requestedStop, wasReady = port != nil; condition.unlock()
                        if !stopped, wasReady {
                            status.issue = "process"
                            status.warning = "代理进程意外退出；若任务仍在运行，其代理网络可能不可用，请停止并重新运行。"
                        }
                        writeStatus(force: true)
                    }
                }
                readers.leave()
            }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; break }
                let data = Data(buffer.prefix(count))
                if capture {
                    ingest.sync {
                        guard !decodingFailed else { return }
                        do { try decoder.consume(data) { consume($0) } }
                        catch {
                            decodingFailed = true; status.warning = "抓包事件无法读取：\(error.localizedDescription)；代理仍在转发。"
                            status.issue = "capture"
                            writeStatus(force: true)
                            condition.lock(); if port == nil { startupError = status.warning }; condition.broadcast(); condition.unlock()
                        }
                    }
                } else {
                    condition.lock(); diagnostic.append(data)
                    if diagnostic.count > 4096 { diagnostic = Data(diagnostic.suffix(4096)) }
                    condition.unlock()
                }
            }
        }
    }
    private func consume(_ event: ProxyWireEvent) {
        if event.type == "ready", let ready = event.port, ready > 0 {
            condition.lock(); port = ready; condition.broadcast(); condition.unlock()
            status.running = true
            status.message = "127.0.0.1:\(ready) · " + (configuration.decryptTLS ? "HTTPS / WSS 解密已开启" : "TLS 透传")
            writeStatus(force: true); return
        }
        if event.type == "warning" {
            status.warning = event.message.map { String($0.prefix(2048)) }
            status.issue = event.issue
            status.dropped += max(0, event.dropped ?? 0); writeStatus(force: true); return
        }
        guard Date() >= retryAt else { status.dropped += 1; writeStatus(); return }
        do {
            if event.type == "http", let record = event.record {
                try save(record)
                if status.issue == "tlsHandshake", record.url.hasPrefix("https://"), record.complete, record.status != nil, record.failure == nil {
                    status.issue = nil; status.warning = nil
                }
            }
            else if event.type == "websocket", let socket = event.socket {
                if sockets == nil { sockets = try ProxyWebSocketStore(directory: directory) }
                try sockets?.append(socket)
            } else { return }
            status.events += 1
            if retryAt != .distantPast { retryAt = .distantPast; status.issue = nil; status.warning = "缓存写入已恢复；中断期间有 \(status.dropped) 个事件未记录。" }
        } catch {
            status.dropped += 1; retryAt = Date().addingTimeInterval(5)
            status.issue = "storage"
            status.warning = "缓存暂不可写，5 秒后自动重试；代理继续转发，期间事件未缓存。\(error.localizedDescription)"
        }
        writeStatus()
    }
    private func save(_ value: ProxyHTTPRecord) throws {
        guard value.flowID.utf8.count <= 1024, value.url.utf8.count <= 16_384, value.method.utf8.count <= 64,
              value.requestHeaders.utf8.count <= 32_768, value.responseHeaders.utf8.count <= 32_768,
              (value.requestBody?.count ?? 0) <= 1024 * 1024, (value.responseBody?.count ?? 0) <= 1024 * 1024 else {
            throw RunbarError.message("代理 HTTP 事件超过缓存限制。")
        }
        if network == nil { network = try NetworkStore(directory: directory) }
        guard let network else { return }
        let id = NetworkRecord.identity(epoch: epoch, isolate: "proxy", request: value.flowID)
        let record = NetworkRecord(id: id, epoch: epoch, isolateID: "proxy", requestID: value.flowID,
            method: value.method, url: value.url, startMicros: value.startMicros,
            endMicros: value.endMicros, status: value.status, contentType: value.contentType,
            requestBytes: value.requestBytes, responseBytes: value.responseBytes,
            requestHeaders: value.requestHeaders, responseHeaders: value.responseHeaders,
            failure: value.failure, timingVersion: 2, bodyNote: value.note)
        try network.upsert([record])
        if value.complete {
            if let request = value.requestBody, let response = value.responseBody {
                try network.saveBodies(id, request: request, response: response)
                if !value.note.isEmpty { try network.markBody(id, state: .saved, note: value.note) }
            } else { try network.markBody(id, state: .unavailable, note: value.note.isEmpty ? "该请求仅保存连接摘要" : value.note) }
        }
    }
    private func writeStatus(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastStatusWrite) >= 1 else { return }
        status.updatedAt = Date(); lastStatusWrite = status.updatedAt
        do {
            let data = try JSONEncoder().encode(status)
            try data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
        } catch { /* Network / WS stores surface disk failures; never stop forwarding here. */ }
    }
    /// Called on the runner's utility queue. Never terminates the target App.
    /// Stop the proxy only when its owning command finishes, after final events drain.
    public func stop() {
        condition.lock(); requestedStop = true; condition.unlock()
        if process.isRunning { process.interrupt() }
        if readers.wait(timeout: .now() + 1.5) == .timedOut, process.isRunning { process.terminate() }
        if readers.wait(timeout: .now() + 1) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // Keep ownership of the session until all cache writers close, so the
        // history cannot become deletable while an old importer is still writing.
        readers.wait()
    }
}
