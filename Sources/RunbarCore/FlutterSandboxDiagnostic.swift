import Foundation

public struct FlutterSandboxAccessFailure: Codable, Equatable, Sendable {
    public let filePath: String
    public let containerPath: String
    public var message: String {
        "Flutter 无法写入 App 沙盒中的热更新文件：\(filePath)。请检查 Runbar 的 App 数据访问权限及目录权限；授权后退出并重开 Runbar，再重新运行项目。"
    }

    public init?(filePath: String, homeDirectory: String = NSHomeDirectory()) {
        guard filePath.hasPrefix("/"), filePath.utf8.count <= 4096,
              !filePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !filePath.split(separator: "/").contains("..") else { return nil }
        let root = URL(fileURLWithPath: homeDirectory).standardizedFileURL
            .appendingPathComponent("Library/Containers", isDirectory: true)
        let file = URL(fileURLWithPath: filePath).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        let parts = file.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        guard parts.count >= 6, SandboxResetService.validIdentifier(parts[0]),
              parts[1] == "Data", parts[2] == "tmp", parts[3].hasPrefix("flutter-"),
              parts.last == "main.dart.incremental.dill" else { return nil }
        self.filePath = file.path
        self.containerPath = root.appendingPathComponent(parts[0]).path
    }
}

/// Inspect output only during an explicit Flutter reload/restart. Require both
/// the exact file-error line and the CLI's EACCES/EPERM explanation, so a disk
/// full, compilation error, arbitrary file failure or successful run does not
/// request broad privacy access. No file reads, probes or permission changes.
struct FlutterSandboxDiagnostic {
    private var line = ""
    private var lineBytes = 0
    private var droppingLine = false
    private var candidate: FlutterSandboxAccessFailure?
    private var remainingLines = 0
    private let homeDirectory: String
    private(set) var failure: FlutterSandboxAccessFailure?

    init(homeDirectory: String = NSHomeDirectory()) { self.homeDirectory = homeDirectory }
    mutating func consume(_ text: String, final: Bool = false) {
        guard failure == nil else { return }
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                if !droppingLine { inspect(line) }
                line = ""; lineBytes = 0; droppingLine = false
                if failure != nil { return }
            } else if !droppingLine {
                let value = scalar.value
                lineBytes += value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x10000 ? 3 : 4
                if lineBytes > 8192 { line = ""; droppingLine = true }
                else { line.unicodeScalars.append(scalar) }
            }
        }
        if final {
            if !droppingLine { inspect(line) }
            line = ""; lineBytes = 0; droppingLine = false
        }
    }
    private mutating func inspect(_ raw: String) {
        let line: String
        if raw.hasPrefix("["), let end = raw.firstIndex(of: "]"), raw.distance(from: raw.startIndex, to: end) <= 25,
           raw[raw.index(after: raw.startIndex)..<end].allSatisfy({ " +0123456789.ms".contains($0) }) {
            line = String(raw[raw.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        } else { line = raw }
        let prefix = "Flutter failed to create file at \""
        if line.hasPrefix(prefix), line.hasSuffix("\".") {
            candidate = FlutterSandboxAccessFailure(filePath: String(line.dropFirst(prefix.count).dropLast(2)), homeDirectory: homeDirectory)
            remainingLines = candidate == nil ? 0 : 3
            return
        }
        guard let candidate else { return }
        if line.hasPrefix("Please ensure that the SDK and/or project is installed in a location "),
           line.contains("read/write permissions for the current user.") {
            failure = candidate; return
        }
        if !line.isEmpty { remainingLines -= 1 }
        if remainingLines <= 0 { self.candidate = nil }
    }
}
