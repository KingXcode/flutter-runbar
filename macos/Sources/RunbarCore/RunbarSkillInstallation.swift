import Foundation
import CryptoKit

public enum RunbarSkillAgent: String, CaseIterable, Codable, Sendable {
    case codex, claude, qoder, qodercn, workbuddy, opencode
    public var title: String {
        switch self { case .codex: return "Codex"; case .claude: return "Claude Code"; case .qoder: return "Qoder"; case .qodercn: return "Qoder CN"; case .workbuddy: return "WorkBuddy"; case .opencode: return "OpenCode" }
    }
    public var configurationFolder: String {
        switch self { case .codex: return ".codex"; case .claude: return ".claude"; case .qoder: return ".qoder"; case .qodercn: return ".qoder-cn"; case .workbuddy: return ".workbuddy"; case .opencode: return ".config/opencode" }
    }
    public func defaultDirectory(home: URL, xdgConfigHome: String? = nil) -> URL {
        if self == .codex { return home.appendingPathComponent(".agents/skills", isDirectory: true) }
        if self == .opencode, let path = xdgConfigHome, path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("opencode/skills", isDirectory: true) }
        return home.appendingPathComponent(configurationFolder + "/skills", isDirectory: true)
    }
}

public struct RunbarSkillManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let name: String
    public let version: String
    public let revision: String
    public let files: [String: String]
    public init(version: String, files: [String: String]) {
        schemaVersion = 1; name = RunbarSkillPayload.name; self.version = version; self.files = files
        revision = Self.revision(for: files)
    }
    public static func revision(for files: [String: String]) -> String {
        RunbarSkillPayload.hash(Data(files.keys.sorted().map { $0 + "\u{0}" + files[$0]! + "\n" }.joined().utf8))
    }
    public var isValid: Bool {
        schemaVersion == 1 && name == RunbarSkillPayload.name && version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil &&
        Set(files.keys) == Set(RunbarSkillPayload.fileNames) && files.values.allSatisfy { value in value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } } && revision == Self.revision(for: files)
    }
}

public struct RunbarSkillPayload: Sendable {
    public static let name = "runbar-diagnostics"
    public static let fileNames = ["SKILL.md", "agents/openai.yaml", "references/setup.md"]
    public let manifest: RunbarSkillManifest
    public let content: [String: Data]
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let data = try Self.smallFile(self.directory.appendingPathComponent("manifest.json"), maximum: 16_384)
        let manifest = try JSONDecoder().decode(RunbarSkillManifest.self, from: data)
        guard manifest.isValid else { throw RunbarError.message("内置 Skill 清单无效，请重新安装 Runbar。") }
        var content: [String: Data] = [:]
        for name in Self.fileNames {
            let file = self.directory.appendingPathComponent(name)
            guard file.resolvingSymlinksInPath().path == file.standardizedFileURL.path else { throw RunbarError.message("Skill 文件存在路径重定向。") }
            let bytes = try Self.smallFile(file)
            guard Self.hash(bytes) == manifest.files[name] else { throw RunbarError.message("内置 Skill 文件校验失败，请重新安装 Runbar。") }
            content[name] = bytes
        }
        self.manifest = manifest; self.content = content
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func smallFile(_ url: URL, maximum: Int = 65_536) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= maximum else { throw RunbarError.message("Skill 文件类型或大小不受支持。") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw RunbarError.message("Skill 文件过大，未读取。") }
        return data
    }
}

public enum RunbarSkillState: String, Sendable {
    case missing, current, updateAvailable, modified, unmanaged, unavailable
}
public struct RunbarSkillInspection: Sendable {
    public let state: RunbarSkillState
    public let installedVersion: String?
    public let hasUpdate: Bool
    public let message: String
    public let destination: URL
    public var requiresReplacementApproval: Bool { state == .modified || state == .unmanaged }
    public var canInstall: Bool { state != .unavailable }
}
public struct RunbarSkillInstallResult: Sendable {
    public let destination: URL
    public let backup: URL?
    public let changed: Bool
}
private struct RunbarSkillReceipt: Codable {
    let managedBy: String
    let manifest: RunbarSkillManifest
    let installedAt: Date
    init(manifest: RunbarSkillManifest) { managedBy = "dev.kingxcode.flutter-runbar"; self.manifest = manifest; installedAt = Date() }
    var isValid: Bool { managedBy == "dev.kingxcode.flutter-runbar" && manifest.isValid }
}

/// Only writes this skill's folder. Every replacement preserves the old folder
/// outside agent discovery, and a failed final move restores the previous copy.
public actor RunbarSkillInstaller {
    public static let receiptName = ".runbar-install.json"
    private let payload: RunbarSkillPayload
    private let backupRoot: URL
    private let files = FileManager.default
    public init(payload: RunbarSkillPayload, backupRoot: URL) { self.payload = payload; self.backupRoot = backupRoot.standardizedFileURL.resolvingSymlinksInPath() }
    public func inspect(root: URL) -> RunbarSkillInspection { Self.inspect(root: root, payload: payload) }
    public static func inspect(root: URL, payload: RunbarSkillPayload) -> RunbarSkillInspection {
        let files = FileManager.default, base = root.standardizedFileURL.resolvingSymlinksInPath()
        let destination = base.appendingPathComponent(RunbarSkillPayload.name, isDirectory: true)
        func info(_ state: RunbarSkillState, _ message: String, version: String? = nil, update: Bool = false) -> RunbarSkillInspection {
            RunbarSkillInspection(state: state, installedVersion: version, hasUpdate: update, message: message, destination: destination)
        }
        do {
            if let resource = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]), resource.isSymbolicLink == true { return info(.unavailable, "当前 Skill 为符号链接；请选择其实际 Skill 根目录。") }
            var directory: ObjCBool = false
            guard files.fileExists(atPath: destination.path, isDirectory: &directory) else { return info(.missing, "未安装") }
            guard directory.boolValue else { return info(.unavailable, "目标位置有同名文件，请更改目录。") }
            let receiptURL = destination.appendingPathComponent(receiptName)
            let receipt = (try? RunbarSkillPayload.smallFile(receiptURL, maximum: 16_384)).flatMap { try? JSONDecoder().decode(RunbarSkillReceipt.self, from: $0) }
            let previous = receipt?.isValid == true ? receipt : nil
            let update = previous.map { $0.manifest.revision != payload.manifest.revision } ?? false
            var hashes: [String: String] = [:]
            for name in RunbarSkillPayload.fileNames {
                let file = destination.appendingPathComponent(name)
                if file.resolvingSymlinksInPath().path == file.standardizedFileURL.path, let data = try? RunbarSkillPayload.smallFile(file) { hashes[name] = RunbarSkillPayload.hash(data) }
            }
            if hashes == payload.manifest.files { return info(.current, "已是内置最新版本", version: payload.manifest.version) }
            guard let previous else {
                let installed = (try? RunbarSkillPayload.smallFile(destination.appendingPathComponent("SKILL.md"))).flatMap(Self.skillVersion)
                let differs = installed.map { !Self.version($0, isAfter: payload.manifest.version) } ?? false
                return info(.unmanaged, "已有其他来源或手动安装的 Skill，默认保留。", version: installed, update: differs)
            }
            if Self.version(previous.manifest.version, isAfter: payload.manifest.version) {
                return info(.unmanaged, "已安装版本比当前 Runbar 内置版本更新，默认保留。", version: previous.manifest.version)
            }
            var modified = hashes != previous.manifest.files
            // Do not silently drop custom scripts/assets when replacing a folder.
            let known = Set(RunbarSkillPayload.fileNames + ["agents", "references", receiptName])
            guard let enumerator = files.enumerator(at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return info(.unavailable, "无法检查 Skill 目录权限。", version: previous.manifest.version) }
            for case let file as URL in enumerator {
                let relative = String(file.path.dropFirst(destination.path.count + 1))
                if file.lastPathComponent == ".DS_Store" { enumerator.skipDescendants(); continue }
                if !known.contains(relative) { modified = true; break }
                if (try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { modified = true; break }
            }
            if modified { return info(.modified, update ? "有新版本，本地内容有修改，默认保留。" : "本地内容有修改，默认保留。", version: previous.manifest.version, update: update) }
            return info(.updateAvailable, "有内置更新", version: previous.manifest.version, update: true)
        } catch { return info(.unavailable, "无法检查：\(error.localizedDescription)") }
    }
    public func install(root: URL, allowReplacingCustom: Bool = false) throws -> RunbarSkillInstallResult {
        try Task.checkCancellation()
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var inspection = Self.inspect(root: root, payload: payload)
        let destination = inspection.destination
        guard !destination.path.hasPrefix(payload.directory.path + "/"), !payload.directory.path.hasPrefix(destination.path + "/"), destination != payload.directory,
              !backupRoot.path.hasPrefix(destination.path + "/"), !destination.path.hasPrefix(backupRoot.path + "/"), destination != backupRoot,
              destination.path != "/" else { throw RunbarError.message("安装目录与内置资源或备份目录冲突。") }
        guard inspection.canInstall else { throw RunbarError.message(inspection.message) }
        guard !inspection.requiresReplacementApproval || allowReplacingCustom else { throw RunbarError.message("已有自定义内容，未覆盖。勾选先备份再替换后重试。") }
        if inspection.state == .current {
            // Adopt an identical manual installation only after the user clicks install.
            let receipt = destination.appendingPathComponent(Self.receiptName)
            if !files.fileExists(atPath: receipt.path) { try receiptData().write(to: receipt, options: .atomic) }
            return RunbarSkillInstallResult(destination: destination, backup: nil, changed: false)
        }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.deletingLastPathComponent().appendingPathComponent(".runbar-skill-stage-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(RunbarSkillPayload.name, isDirectory: true)
        try files.createDirectory(at: staged, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        for name in RunbarSkillPayload.fileNames {
            let url = staged.appendingPathComponent(name)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try payload.content[name]!.write(to: url, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            guard RunbarSkillPayload.hash(try RunbarSkillPayload.smallFile(url)) == payload.manifest.files[name] else { throw RunbarError.message("Skill 写入校验失败，未替换现有安装。") }
        }
        try receiptData().write(to: staged.appendingPathComponent(Self.receiptName), options: .atomic)
        try Task.checkCancellation()
        inspection = Self.inspect(root: root, payload: payload)
        guard inspection.canInstall, !inspection.requiresReplacementApproval || allowReplacingCustom else { throw RunbarError.message("安装目录发生变化，未替换。请刷新后重试。") }
        if inspection.state == .current { return RunbarSkillInstallResult(destination: destination, backup: nil, changed: false) }
        var backup: URL?
        if files.fileExists(atPath: destination.path) {
            let folder = backupRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let saved = folder.appendingPathComponent(RunbarSkillPayload.name, isDirectory: true)
            try files.moveItem(at: destination, to: saved); backup = saved
        }
        do { try files.moveItem(at: staged, to: destination) }
        catch {
            if let backup, !files.fileExists(atPath: destination.path) {
                do { try files.moveItem(at: backup, to: destination) }
                catch { throw RunbarError.message("安装未完成，旧 Skill 保留于 \(backup.path)，恢复失败：\(error.localizedDescription)") }
            }
            throw error
        }
        return RunbarSkillInstallResult(destination: destination, backup: backup, changed: true)
    }
    private func receiptData() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .deferredToDate; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(RunbarSkillReceipt(manifest: payload.manifest))
    }
    private static func version(_ value: String, isAfter other: String) -> Bool {
        value.compare(other, options: .numeric) == .orderedDescending
    }
    private static func skillVersion(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else { return nil }
        let header = String(text[..<end.lowerBound])
        guard let expression = try? NSRegularExpression(pattern: "(?m)^  version: \"([0-9]+\\.[0-9]+\\.[0-9]+)\"$"),
              let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else { return nil }
        return String(header[range])
    }
}
