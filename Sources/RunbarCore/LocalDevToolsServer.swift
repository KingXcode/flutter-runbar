import Foundation

/// Starts only a local DevTools frontend on demand. No target process is owned.
public actor LocalDevToolsServer {
    private var process: Process?
    private var startup: Task<URL, Error>?
    private var continuation: CheckedContinuation<URL, Error>?
    private var generation = UUID()
    public init() {}
    public func url(for endpoint: VMServiceEndpoint, extraPath: String) async throws -> URL {
        if startup == nil { startup = Task { try await self.launch(extraPath: extraPath) } }
        let base: URL
        do { base = try await startup!.value }
        catch { startup = nil; throw error }
        guard process?.isRunning == true, var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            startup = nil; throw RunbarError.message("本机 DevTools 服务已结束，请重试。")
        }
        parts.queryItems = [URLQueryItem(name: "uri", value: endpoint.url.absoluteString)]
        guard let result = parts.url else { throw VMServiceError.invalidResponse }; return result
    }
    private func launch(extraPath: String) async throws -> URL {
        let home = NSHomeDirectory()
        let path = CommandEnvironment.extraPath(extraPath) + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":\(home)/fvm/default/bin:\(home)/dev_sdk/flutter/bin"
        guard let executable = path.split(separator: ":").map({ URL(fileURLWithPath: String($0)).appendingPathComponent("dart") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw RunbarError.message("未找到 Dart SDK。请在设置的 PATH 中添加 Flutter / Dart 的 bin 目录，再打开 DevTools。")
        }
        let process = Process(), pipe = Pipe()
        let generation = UUID(); self.generation = generation
        process.executableURL = executable
        process.arguments = ["devtools", "--no-launch-browser", "--port=0"]
        var environment = ProcessInfo.processInfo.environment; environment["PATH"] = path; process.environment = environment
        process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
        self.process = process
        process.terminationHandler = { [weak self] _ in Task { await self?.failed(generation) } }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            do { try process.run() } catch { failed(generation); return }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var line = Data()
                defer { try? pipe.fileHandleForReading.close() }
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    guard !chunk.isEmpty else { break }
                    for byte in chunk {
                        if byte == 10 || byte == 13 {
                            let text = String(decoding: line, as: UTF8.self); line = Data()
                            if let url = Self.startupURL(from: text) {
                                Task { await self?.ready(url, generation: generation) }
                            }
                        } else if line.count < 16_384 { line.append(byte) }
                    }
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                await self?.timeout(generation)
            }
        }
    }
    nonisolated static func startupURL(from line: String) -> URL? {
        var parser = OutputParser()
        let text = parser.consume(Data(line.utf8), final: true).text
        guard let range = text.range(of: "Serving DevTools at ") else { return nil }
        let value = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return DevToolsLink.validatedURL(value)
    }
    private func ready(_ url: URL, generation: UUID) {
        guard generation == self.generation else { return }
        continuation?.resume(returning: url); continuation = nil
    }
    private func failed(_ generation: UUID) {
        guard generation == self.generation else { return }
        continuation?.resume(throwing: RunbarError.message("本机 DevTools 未能启动，请检查设置中的 Flutter / Dart PATH。")); continuation = nil
    }
    private func timeout(_ generation: UUID) {
        if generation == self.generation, continuation != nil { failed(generation); if process?.isRunning == true { process?.terminate() } }
    }
    public func stop() {
        failed(generation); generation = UUID(); if process?.isRunning == true { process?.terminate() }
        process = nil; startup?.cancel(); startup = nil
    }
}
