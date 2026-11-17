import Foundation

public struct CurlResponseHead: Codable, Equatable, Sendable {
    public let status: Int
    public let statusLine: String
    public let headers: String
    public let contentType: String
    public let disposition: String?
    public let duration: TimeInterval
    public let bytes: Int
}

public struct CurlResponse: Sendable {
    public let head: CurlResponseHead
    public let body: Data

    public func export(url: URL) -> NetworkResponseExport {
        .init(filename: NetworkResponseExport.filename(url: url.absoluteString, disposition: head.disposition,
                                                       contentType: head.contentType), source: .body(body))
    }
}

public enum CurlClient {
    public static let maximumBodyBytes = 16 * 1024 * 1024

    public static func send(_ request: CurlRequest) async throws -> CurlResponse {
        let execution = Execution()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try execution.send(request) })
                }
            }
        } onCancel: { execution.cancel() }
    }

    /// All child process state is guarded by the lock. The worker owns its
    /// pipes/files; cancellation only signals the running curl process.
    private final class Execution: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var running: Process?

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if let running, running.isRunning { running.terminate() }
        }

        private func checkCancellation() throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
        }

        private func start(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try process.run()
            running = process
        }

        func send(_ request: CurlRequest) throws -> CurlResponse {
            try checkCancellation()
            let request = try request.validatedForSending()
            let files = FileManager.default
            let root = files.temporaryDirectory.appendingPathComponent("runbar-http-\(UUID().uuidString)", isDirectory: true)
            try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: root) }
            let headers = root.appendingPathComponent("headers")
            let config = root.appendingPathComponent("request")
            let errors = root.appendingPathComponent("errors")
            let opts = request.options + [.init("url", request.url.absoluteString)]
            let configText = opts.map { opt in
                opt.name + (opt.value.map { " = \"" + Self.escapeConfig($0) + "\"" } ?? "")
            }.joined(separator: "\n") + "\n"
            try Data(configText.utf8).write(to: config)
            try Data().write(to: errors)
            let errorFile = try FileHandle(forWritingTo: errors)
            defer { try? errorFile.close() }

            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.currentDirectoryURL = root
            process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "LC_ALL": "C"]
            process.arguments = ["-q", "--silent", "--show-error", "--globoff",
                                 "--proto", "=http,https", "--proto-redir", "=http,https",
                                 "--max-redirs", "10", "--connect-timeout", "15", "--max-time", "60",
                                 "--max-filesize", String(CurlClient.maximumBodyBytes),
                                 "--dump-header", headers.path, "--config", config.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = errorFile
            let startTime = ProcessInfo.processInfo.systemUptime
            try start(process)
            try? output.fileHandleForWriting.close()
            defer {
                try? output.fileHandleForReading.close()
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                lock.lock()
                running = nil
                lock.unlock()
            }
            var body = Data()
            // Also enforce the limit on decoded bytes, including gzip
            // expansion on curl versions that only count wire bytes.
            while let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try checkCancellation()
                if request.method == "HEAD" { continue }
                guard body.count + chunk.count <= CurlClient.maximumBodyBytes else { throw Self.tooLarge }
                body.append(chunk)
            }
            process.waitUntilExit()
            try checkCancellation()
            let duration = ProcessInfo.processInfo.systemUptime - startTime
            if process.terminationStatus == 63 { throw Self.tooLarge }
            guard process.terminationStatus == 0 else {
                let input = try FileHandle(forReadingFrom: errors)
                defer { try? input.close() }
                let text = String(decoding: (try input.read(upToCount: 2048)) ?? Data(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw RunbarError.message(text.isEmpty ? "请求失败（curl \(process.terminationStatus)）。" : text)
            }

            let raw = try String(decoding: Data(contentsOf: headers), as: UTF8.self)
            let final = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
                .last { $0.hasPrefix("HTTP/") } ?? ""
            let lines = final.components(separatedBy: "\n")
            let statusLine = lines[0]
            guard let status = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
                throw RunbarError.message("没有收到有效的 HTTP 响应。")
            }
            func field(_ name: String) -> String? {
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == name else { continue }
                    return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                return nil
            }
            return CurlResponse(head: CurlResponseHead(status: status, statusLine: String(statusLine.prefix(512)),
                            headers: String(decoding: final.utf8.prefix(64 * 1024), as: UTF8.self),
                            contentType: String((field("content-type") ?? "").prefix(512)),
                            disposition: field("content-disposition").map { String($0.prefix(1024)) },
                            duration: duration, bytes: body.count), body: body)
        }

        private static var tooLarge: RunbarError { .message("响应超过 16 MiB，已停止接收。") }

        private static func escapeConfig(_ value: String) -> String {
            var result = ""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\\": result += "\\\\"
                case "\"": result += "\\\""
                case "\n": result += "\\n"
                case "\r": result += "\\r"
                case "\t": result += "\\t"
                case "\u{B}": result += "\\v"
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result
        }
    }
}
