import Foundation

public struct CurlProject: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var text: String
    public let createdAt: Date

    public init(name: String, text: String = "") {
        id = UUID(); self.name = name; self.text = text; createdAt = Date()
    }
}

public struct CurlRun: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let request: CurlRequest
    public let response: CurlResponseHead?
    public let error: String?

    public init(date: Date, request: CurlRequest, response: CurlResponseHead?, error: String? = nil) {
        id = UUID(); self.date = date; self.request = request; self.response = response; self.error = error
    }
}

/// Private files under Runbar's Application Support directory. Each response
/// is a separate file loaded only when the user views that history entry.
public struct CurlWorkspaceStore: Sendable {
    public static let historyLimit = 50
    public static let historyBytes = 64 * 1024 * 1024
    public let root: URL

    public init(root: URL) { self.root = root }

    public func projects() throws -> [CurlProject] {
        try children(root).filter { UUID(uuidString: $0.lastPathComponent) != nil }.map {
            try read(CurlProject.self, from: $0.appendingPathComponent("project.json"))
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ project: CurlProject) throws {
        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              project.name.count <= 80, project.text.utf8.count <= CurlDocument.maximumBytes else {
            throw RunbarError.message("项目名称须为 1 到 80 个字符，编辑区最多 256 KiB。")
        }
        try write(project, to: projectDirectory(project.id).appendingPathComponent("project.json"))
    }

    public func history(_ id: UUID) throws -> [CurlRun] {
        try children(historyDirectory(id)).filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }.map {
            try read(CurlRun.self, from: $0)
        }.sorted { $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date }
    }

    public func record(_ run: CurlRun, body: Data?, project id: UUID) throws {
        guard (body?.count ?? 0) == (run.response?.bytes ?? 0), (body?.count ?? 0) <= CurlClient.maximumBodyBytes else {
            throw RunbarError.message("响应正文大小不符，无法保存历史。")
        }
        let directory = historyDirectory(id)
        try ensureDirectory(directory)
        let bodyPath = file(for: run, project: id, extension: "body")
        if let body, !body.isEmpty {
            try body.write(to: bodyPath, options: .atomic)
        }
        do {
            try write(run, to: file(for: run, project: id, extension: "json"))
        } catch {
            try? FileManager.default.removeItem(at: bodyPath); throw error
        }
        var bytes = 0
        for (index, item) in try history(id).enumerated() {
            let size = max(0, min(item.response?.bytes ?? 0, CurlClient.maximumBodyBytes))
            if index >= Self.historyLimit || bytes + size > Self.historyBytes {
                try removeRun(item, project: id)
            } else {
                bytes += size
            }
        }
    }

    public func response(_ run: CurlRun, project id: UUID) throws -> CurlResponse? {
        guard let head = run.response else { return nil }
        let path = file(for: run, project: id, extension: "body")
        if head.bytes == 0 { return CurlResponse(head: head, body: Data()) }
        guard head.bytes > 0, head.bytes <= CurlClient.maximumBodyBytes,
              try path.resourceValues(forKeys: [.fileSizeKey]).fileSize == head.bytes else {
            throw RunbarError.message("这条记录的响应正文不完整。")
        }
        return CurlResponse(head: head, body: try Data(contentsOf: path))
    }

    public func clearHistory(_ id: UUID) throws {
        let directory = historyDirectory(id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        }
    }

    public func removeProject(_ id: UUID) throws {
        try FileManager.default.trashItem(at: projectDirectory(id), resultingItemURL: nil)
    }

    private func removeRun(_ run: CurlRun, project: UUID) throws {
        try FileManager.default.removeItem(at: file(for: run, project: project, extension: "json"))
        let path = file(for: run, project: project, extension: "body")
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    private func projectDirectory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func historyDirectory(_ id: UUID) -> URL { projectDirectory(id).appendingPathComponent("history", isDirectory: true) }
    private func file(for run: CurlRun, project id: UUID, extension ext: String) -> URL {
        historyDirectory(id).appendingPathComponent(run.id.uuidString).appendingPathExtension(ext)
    }

    private func children(_ folder: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }
    private func ensureDirectory(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
