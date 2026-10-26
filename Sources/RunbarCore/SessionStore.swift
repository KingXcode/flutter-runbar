import Foundation

public final class SessionStore {
    public let root: URL
    public private(set) var warnings: [String] = []
    private let trashDirectory: (URL) throws -> Void
    private var encoder: JSONEncoder {
        let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value
    }
    public init(root: URL? = nil, trashDirectory: ((URL) throws -> Void)? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FlutterRunbar", isDirectory: true)
        self.trashDirectory = trashDirectory ?? { url in
            #if os(macOS)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            #else
            throw RunbarError.message("当前平台不支持系统废纸篓。")
            #endif
        }
        try FileManager.default.createDirectory(at: self.root.appendingPathComponent("sessions"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func directory(_ id: UUID) -> URL { root.appendingPathComponent("sessions/\(id.uuidString)", isDirectory: true) }
    public func loadConfiguration() throws -> Configuration {
        let url = root.appendingPathComponent("configuration.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    }
    public func saveConfiguration(_ value: Configuration) throws { try encoder.encode(value).write(to: root.appendingPathComponent("configuration.json"), options: .atomic) }
    public func save(_ session: RunSession) throws {
        try FileManager.default.createDirectory(at: directory(session.id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(session).write(to: directory(session.id).appendingPathComponent("session.json"), options: .atomic)
    }
    /// Preflight the whole batch and stage together. A trash failure restores all records.
    public func trashSessions(_ ids: Set<UUID>, activeSessionIDs: Set<UUID> = []) throws {
        guard !ids.isEmpty else { return }
        guard ids.isDisjoint(with: activeSessionIDs) else { throw RunbarError.message("不能删除正在运行的记录，请先停止任务。") }
        let files = FileManager.default
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for id in ids {
            let folder = directory(id)
            let values = try folder.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw RunbarError.message("记录目录无效，未删除。") }
            let session = try decoder.decode(RunSession.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
            guard session.id == id else { throw RunbarError.message("记录身份不匹配，未删除。") }
            guard session.status != .running else { throw RunbarError.message("不能删除正在运行的记录，请先停止任务。") }
        }
        let staging = root.appendingPathComponent("Runbar Deleted Records \(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var moved: [UUID] = []
        do {
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                try files.moveItem(at: directory(id), to: staging.appendingPathComponent(id.uuidString))
                moved.append(id)
            }
            try trashDirectory(staging)
        } catch {
            var restoreErrors: [String] = []
            for id in moved {
                do { try files.moveItem(at: staging.appendingPathComponent(id.uuidString), to: directory(id)) }
                catch { restoreErrors.append(id.uuidString) }
            }
            if restoreErrors.isEmpty { try? files.removeItem(at: staging) }
            else { throw RunbarError.message("删除失败，部分记录恢复失败。原文件保留于 \(staging.path)：\(restoreErrors.joined(separator: ", "))") }
            throw error
        }
    }
    public func sessions() throws -> [RunSession] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let urls = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)
        warnings = []
        return urls.compactMap { url -> RunSession? in
            do { return try decoder.decode(RunSession.self, from: Data(contentsOf: url.appendingPathComponent("session.json"))) }
            catch { warnings.append("已跳过损坏的历史记录：\(url.lastPathComponent)。原文件保留供恢复。"); return nil }
        }.sorted { $0.startedAt > $1.startedAt }
    }
    // Never act on historical PIDs. A previous process might still be alive after a crash.
    public func recoverInterrupted() throws {
        for var session in try sessions() where session.status == .running {
            session.status = .interrupted
            session.error = "上次应用异常结束；真实结束时间未知。请自行检查终端进程，应用不会终止历史 PID。"
            try save(session)
        }
    }
    /// Resolve the exact selected session's persisted output, never a global latest run.
    public func outputFile(for sessionID: UUID) throws -> URL {
        let url = directory(sessionID).appendingPathComponent("output.raw")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw RunbarError.message("这次运行的日志文件不存在或尚未创建。")
        }
        return url
    }
    public func tail(_ id: UUID, limit: Int = 200_000) throws -> String {
        guard limit > 0 else { return "" }
        let handle = try FileHandle(forReadingFrom: directory(id).appendingPathComponent("output.raw")); defer { try? handle.close() }
        let length = try handle.seekToEnd(); try handle.seek(toOffset: length > UInt64(limit) ? length - UInt64(limit) : 0)
        let bytes = try handle.read(upToCount: max(0, limit)) ?? Data()
        return (length > UInt64(limit) ? "[仅展示末尾 \(limit) 字节；完整内容保存在本地日志]\n" : "") + { var parser = OutputParser(); return parser.consume(bytes, final: true).text }()
    }
}

/// Two append-only files: exact merged stream bytes and their receive-time index.
/// Disk errors propagate to stop the run; no false claim of complete logging.
public final class RunLog {
    private let raw: FileHandle
    private let index: FileHandle
    private var offset: UInt64 = 0
    private var sequence = 0
    private let encoder = JSONEncoder()
    public init(directory: URL) throws {
        let rawURL = directory.appendingPathComponent("output.raw"), indexURL = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.createFile(atPath: rawURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: indexURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw RunbarError.message("无法创建运行日志") }
        raw = try FileHandle(forWritingTo: rawURL)
        index = try FileHandle(forWritingTo: indexURL)
        encoder.dateEncodingStrategy = .iso8601
    }
    public func append(_ data: Data, at date: Date = Date()) throws {
        let event = OutputEvent(sequence: sequence, receivedAt: date, offset: offset, byteCount: data.count)
        try raw.write(contentsOf: data)
        try index.write(contentsOf: encoder.encode(event) + Data([10]))
        // Synchronous flush makes persistence failures visible during a run.
        try raw.synchronize(); try index.synchronize()
        offset += UInt64(data.count); sequence += 1
    }
    public func close() throws { try raw.synchronize(); try index.synchronize(); try raw.close(); try index.close() }
    deinit { try? raw.close(); try? index.close() }
}
