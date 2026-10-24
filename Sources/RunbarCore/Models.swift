import Foundation

public struct CommandPreset: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var command: String
    public init(name: String = "运行 macOS", command: String = "fvm flutter run -d macos") { self.name = name; self.command = command }
}
public struct Project: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var path: String
    public var presets: [CommandPreset] = [CommandPreset()]
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public init(path: String) { self.path = path }
}
public struct Configuration: Codable {
    public var projects: [Project] = []
    public var extraPath: String = CommandEnvironment.extraPath("")
    public init() {}
}
public enum RunStatus: String, Codable { case running, succeeded, failed, stopped, interrupted }
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
