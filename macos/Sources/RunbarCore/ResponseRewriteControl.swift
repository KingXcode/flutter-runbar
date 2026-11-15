import Foundation

/// The control directory is owned by one proxy session, independently of UI selection.
public enum ResponseRewriteControl {
    private struct Acknowledgement: Decodable { let revision: Int; let error: String? }
    public static func write(_ settings: ResponseRewriteSettings, directory: URL) throws {
        let control = directory.appendingPathComponent("control", isDirectory: true)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bytes = try JSONEncoder().encode(settings)
        guard bytes.count <= 1024 * 1024 else { throw RunbarError.message("规则配置超过 1 MB。") }
        let file = control.appendingPathComponent("rewrite-rules.json")
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public static func publish(_ settings: ResponseRewriteSettings, directory: URL) async throws {
        try await Task.detached(priority: .utility) { try write(settings, directory: directory) }.value
        let file = directory.appendingPathComponent("control/rewrite-ack.json")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let acknowledgement = await Task.detached(priority: .utility) { () -> Acknowledgement? in
                guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
                defer { try? handle.close() }
                guard let bytes = try? handle.read(upToCount: 16_385), bytes.count <= 16_384 else { return nil }
                return try? JSONDecoder().decode(Acknowledgement.self, from: bytes)
            }.value
            if let acknowledgement, acknowledgement.revision == settings.revision {
                if let error = acknowledgement.error, !error.isEmpty { throw RunbarError.message(error) }
                return
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        throw RunbarError.message("等待代理确认超时，当前生效版本未知；请根据新请求的改写记录核对，或重新运行项目加载已保存规则。")
    }
}
