import Foundation
import AppKit
import Security
import UniformTypeIdentifiers
import RunbarCore

/// The token lives in its own 0700 directory and a 0600 file, so it survives
/// ad-hoc app replacements without Keychain ACL/signature prompts.
private enum MCPAccessToken {
    static func load(root: URL, replace: Bool = false) throws -> String {
        let directory = root.appendingPathComponent("mcp", isDirectory: true), file = directory.appendingPathComponent("access-token")
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path,
              file.standardizedFileURL.path == file.resolvingSymlinksInPath().path else { throw RunbarError.message("MCP 凭据路径不能包含符号链接。") }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if files.fileExists(atPath: file.path), !replace {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, values.fileSize == 64 else { throw RunbarError.message("MCP 访问令牌损坏，请点击重置访问令牌。") }
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let data = try Data(contentsOf: file)
            guard let text = String(data: data, encoding: .utf8), text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RunbarError.message("MCP 访问令牌损坏，请点击重置访问令牌。") }
            return text
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RunbarError.message("无法生成 MCP 安全访问令牌。") }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try Data(token.utf8).write(to: file, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return token
    }
}

@MainActor
final class MCPServiceController: ObservableObject {
    static let defaultPort = 47821
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "mcpEnabled")
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var port: Int
    @Published var portText: String
    @Published private(set) var message = "服务未开启"
    @Published private(set) var error: String?
    @Published private(set) var callCount = 0
    @Published private(set) var lastCall: String?
    @Published private(set) var lastCallAt: Date?
    @Published private(set) var copied: String?
    @Published private(set) var configurationRevision = UUID()
    let clientInstaller = MCPClientInstallationModel()
    private let server = MCPLocalServer()
    private var root: URL?
    private var snapshot: (@Sendable () async -> RunbarMCPSnapshot)?
    private var source: RunbarMCPDataSource?
    private var startup: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var generation = UUID()
    private var token: String?
    var address: String { "http://127.0.0.1:\(port)/mcp" }
    var installationConnection: RunbarMCPConnection? {
        guard running, let token else { return nil }
        return RunbarMCPConnection(address: address, token: token)
    }
    private var skillPackage: URL? { Bundle.main.url(forResource: "runbar-diagnostics", withExtension: "zip", subdirectory: "Skills") }
    var skillPackageAvailable: Bool { skillPackage != nil }
    init() {
        let saved = UserDefaults.standard.integer(forKey: "mcpPort")
        let port = (1024...65535).contains(saved) ? saved : Self.defaultPort
        self.port = port; portText = String(port)
    }
    func configure(root: URL, snapshot: @escaping @Sendable () async -> RunbarMCPSnapshot) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath(); self.snapshot = snapshot
        clientInstaller.configure(root: root)
    }
    func setEnabled(_ value: Bool) {
        enabled = value; UserDefaults.standard.set(value, forKey: "mcpEnabled")
        if value { restart() } else { stop(); message = "服务未开启" }
    }
    func startIfEnabled() { if enabled { restart() } }
    func applyPort() {
        guard let value = Int(portText), (1024...65535).contains(value) else { error = "端口必须是 1024 到 65535 的整数。"; return }
        guard value != port else { if enabled && !running { restart() }; return }
        port = value; portText = String(value); UserDefaults.standard.set(value, forKey: "mcpPort")
        copied = nil; error = nil
        if enabled { restart() }
    }
    func restart() {
        stop(); error = nil; copied = nil
        guard enabled else { return }
        #if SCREENSHOT_PREVIEW || LIVE_LOG_VALIDATION
        error = "演示构建不能开启 MCP 服务。"; return
        #endif
        guard let root, let snapshot else { error = "本地数据尚不可用，无法启动 MCP。"; return }
        let token: String
        do { token = try MCPAccessToken.load(root: root); self.token = token }
        catch { self.error = error.localizedDescription; return }
        let dataSource = RunbarMCPDataSource(root: root, snapshot: snapshot)
        source = dataSource; starting = true; message = "正在启动…"
        let generation = generation, port = UInt16(port)
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.server.start(port: port, token: token, handler: { name, arguments in
                    try await dataSource.call(name, arguments: arguments)
                }, onTool: { [weak self] name in
                    self?.callCount += 1; self?.lastCall = name; self?.lastCallAt = Date()
                }, onFailure: { [weak self] message in
                    self?.stop(); self?.error = message
                })
                guard !Task.isCancelled, self.generation == generation else { return }
                self.running = true; self.starting = false; self.message = "已开启 · 仅本机 · 只读"
                self.configurationRevision = UUID()
            } catch is CancellationError {} catch {
                guard self.generation == generation else { return }
                self.starting = false; self.running = false; self.message = "服务未启动"; self.error = error.localizedDescription
            }
        }
    }
    func stop() {
        generation = UUID(); startup?.cancel(); startup = nil; server.stop()
        running = false; starting = false; token = nil; copied = nil; message = "服务未开启"
        configurationRevision = UUID()
        let old = source, previous = cleanup; source = nil
        cleanup = Task { await previous?.value; await old?.shutdown() }
    }
    func shutdown() async { stop(); await cleanup?.value }
    func resetToken() {
        guard let root else { error = "本地存储不可用。"; return }
        do {
            _ = try MCPAccessToken.load(root: root, replace: true)
            copied = nil; error = nil
            if enabled { restart() }
        } catch { self.error = error.localizedDescription }
    }
    func copyConfiguration(codex: Bool) {
        guard running, let token else { return }
        let text: String
        if codex {
            text = """
            [mcp_servers.runbar]
            url = "\(address)"
            http_headers = { Authorization = "Bearer \(token)" }
            tool_timeout_sec = 45
            """
        } else {
            let object: [String: Any] = ["mcpServers": ["runbar": ["type": "http", "url": address, "headers": ["Authorization": "Bearer \(token)"]]]]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), let value = String(data: data, encoding: .utf8) else { return }
            text = value
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        copied = codex ? "已复制 Codex 配置（包含访问令牌）" : "已复制 HTTP MCP 配置（包含访问令牌）"
    }
    func copyExample() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("使用 Runbar MCP 找到当前正在运行的会话，查看最近的错误日志和失败的网络请求；如有失败请求，读取其请求头、请求参数和响应正文，分析原因。只分析，不执行命令或修改业务程序。", forType: .string)
        copied = "已复制示例提问"
    }
    func saveSkillPackage() {
        guard let package = skillPackage else { error = "此构建未包含诊断 Skill 安装包。"; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "runbar-diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        panel.title = "保存 Runbar 诊断 Skill"
        panel.message = "导出供其他环境安装；本机可直接使用「安装 / 更新 AI Skill」向导，并在 MCP 窗口选择 Agent 安装连接。"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try Data(contentsOf: package).write(to: destination, options: .atomic)
            error = nil; copied = "Skill ZIP 已保存。解压后将 runbar-diagnostics 放入目标客户端的 Skill 目录。"
        } catch { self.error = "保存 Skill 失败：\(error.localizedDescription)" }
    }
}
