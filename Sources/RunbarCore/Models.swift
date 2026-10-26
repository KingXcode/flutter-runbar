import Foundation

public enum BuiltInAction: String, Codable { case resetMacOSSandbox }

public struct CommandPreset: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var command: String
    public var builtInAction: BuiltInAction?
    public var displayCommand: String { builtInAction == .resetMacOSSandbox ? "内置操作 · 确认后将整个 App 沙盒移到废纸篓" : command }
    public static var sandboxReset: CommandPreset {
        var value = CommandPreset(name: "清空 macOS App 沙盒", command: "")
        value.id = UUID(uuidString: "9D02E5AA-A305-4AC1-A817-0271E8F88AC0")!
        value.builtInAction = .resetMacOSSandbox
        return value
    }
    public init(name: String = "新命令", command: String = "") { self.name = name; self.command = command }
}
public struct Project: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var path: String
    public var presets: [CommandPreset] = []
    public var kind: ProjectKind
    // Optional preserves decoding of configurations written before per-project selection.
    public var selectedPresetID: UUID?
    // Virtual built-in keeps legacy JSON and saved custom commands untouched.
    public var availablePresets: [CommandPreset] { presets + (kind == .flutter ? [CommandPreset.sandboxReset] : []) }
    public var selectedPreset: CommandPreset? { availablePresets.first { $0.id == selectedPresetID } ?? presets.first }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public init(path: String, presets: [CommandPreset] = [], kind: ProjectKind? = nil) {
        self.path = path; self.presets = presets
        self.kind = kind ?? ProjectDetector.detect(at: path)
    }
    private enum CodingKeys: String, CodingKey { case id, path, presets, kind, selectedPresetID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        path = try values.decode(String.self, forKey: .path)
        presets = try values.decode([CommandPreset].self, forKey: .presets)
        selectedPresetID = try values.decodeIfPresent(UUID.self, forKey: .selectedPresetID)
        kind = try values.decodeIfPresent(ProjectKind.self, forKey: .kind) ?? ProjectDetector.detect(at: path)
    }
}
public struct Configuration: Codable {
    public var projects: [Project] = []
    public var extraPath: String = CommandEnvironment.extraPath("")
    public var logPreferences: LogPreferences?
    public init() {}
    @discardableResult
    public mutating func removeProject(_ id: UUID, activeProjectIDs: Set<UUID>) throws -> Project? {
        guard !activeProjectIDs.contains(id) else { throw RunbarError.message("请先停止该项目的任务，再移除项目。") }
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return nil }
        return projects.remove(at: index)
    }
}
public enum RunStatus: String, Codable { case running, succeeded, failed, stopped, interrupted, cancelled }
public struct RunSession: Codable, Identifiable {
    public var id: UUID
    public var projectPath: String
    public var command: String
    public var startedAt: Date
    public var endedAt: Date?
    public var duration: TimeInterval?
    public var exitCode: Int32?
    public var status: RunStatus
    public var devToolsURLs: [String] = []
    public var error: String?
    public init(projectPath: String, command: String) {
        id = UUID(); self.projectPath = projectPath; self.command = command
        startedAt = Date(); status = .running
    }
}
public struct OutputEvent: Codable {
    public let sequence: Int
    public let receivedAt: Date
    public let offset: UInt64
    public let byteCount: Int
}
public enum RunbarError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
