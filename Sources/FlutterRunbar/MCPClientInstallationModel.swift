import AppKit
import Foundation
import RunbarCore

struct MCPClientTarget: Identifiable {
    let agent: RunbarMCPAgent
    let file: URL
    var id: String { agent.rawValue }
}

@MainActor
final class MCPClientInstallationModel: ObservableObject {
    @Published private(set) var targets: [MCPClientTarget] = []
    @Published private(set) var states: [String: RunbarMCPInspection] = [:]
    @Published var selection = Set<String>()
    @Published private(set) var checking = false
    @Published private(set) var installing = false
    @Published private(set) var message: String?
    @Published private(set) var outcomes: [String: String] = [:]
    @Published private(set) var backups: [String: URL] = [:]
    private var overrides = UserDefaults.standard.dictionary(forKey: "mcpAgentConfigurationFiles") as? [String: String] ?? [:]
    private var engine: RunbarMCPInstaller
    private var connection: RunbarMCPConnection?
    private var refreshPending = false
    var busy: Bool { checking || installing }
    private var selected: [MCPClientTarget] { targets.filter { selection.contains($0.id) } }
    var canInstall: Bool {
        !busy && connection != nil && !selected.isEmpty && selected.allSatisfy { states[$0.id]?.canInstall == true }
    }
    var canUninstall: Bool {
        !busy && selected.contains { states[$0.id]?.canUninstall == true } && selected.allSatisfy {
            states[$0.id]?.canUninstall == true || states[$0.id]?.state == .missing
        }
    }
    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlutterRunbar/mcp-config-backups", isDirectory: true)
        engine = RunbarMCPInstaller(backupRoot: root)
        rebuildTargets()
    }
    func configure(root: URL) {
        engine = RunbarMCPInstaller(backupRoot: root.appendingPathComponent("mcp-config-backups", isDirectory: true))
    }
    private func rebuildTargets() {
        targets = RunbarMCPAgent.allCases.map { agent in
            let file = overrides[agent.rawValue].map { URL(fileURLWithPath: $0) } ?? agent.configurationFile()
            return MCPClientTarget(agent: agent, file: file)
        }
    }
    func refresh(connection: RunbarMCPConnection?) async {
        self.connection = connection
        guard !busy else { refreshPending = true; return }
        checking = true
        defer { checking = false }
        repeat {
            refreshPending = false
            let currentConnection = self.connection
            rebuildTargets()
            var values: [String: RunbarMCPInspection] = [:]
            for target in targets {
                values[target.id] = await engine.inspect(agent: target.agent, file: target.file, connection: currentConnection)
            }
            states = values
        } while refreshPending
    }
    func chooseFile(_ target: MCPClientTarget) {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 \(target.agent.title) 的 MCP 配置文件"
        panel.message = "选择此 Agent 已有的配置文件。此步只记住位置；点击安装后才写入 Runbar 配置。"
        panel.directoryURL = target.file.deletingLastPathComponent()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let file = panel.url else { return }
        overrides[target.id] = file.path
        UserDefaults.standard.set(overrides, forKey: "mcpAgentConfigurationFiles")
        outcomes[target.id] = nil; backups[target.id] = nil
        Task { await refresh(connection: connection) }
    }
    func restoreDefaultFile(_ target: MCPClientTarget) {
        guard !busy else { return }
        overrides[target.id] = nil
        UserDefaults.standard.set(overrides, forKey: "mcpAgentConfigurationFiles")
        outcomes[target.id] = nil; backups[target.id] = nil
        Task { await refresh(connection: connection) }
    }
    func hasCustomFile(_ target: MCPClientTarget) -> Bool { overrides[target.id] != nil }
    func installSelected() async {
        guard canInstall, let connection else { return }
        await perform(uninstall: false, connection: connection)
    }
    func uninstallSelected() async {
        guard canUninstall else { return }
        await perform(uninstall: true, connection: nil)
    }
    private func perform(uninstall: Bool, connection: RunbarMCPConnection?) async {
        installing = true; outcomes = [:]; backups = [:]
        var completed = 0, failed = 0
        // Capture the chosen targets so a refresh cannot change this operation.
        let chosen = selected
        for target in chosen {
            message = "正在\(uninstall ? "卸载" : "安装") \(target.agent.title)…"
            do {
                let result: RunbarMCPInstallResult
                if uninstall {
                    result = try await engine.uninstall(agent: target.agent, file: target.file)
                } else if let connection {
                    result = try await engine.install(agent: target.agent, file: target.file, connection: connection)
                } else { continue }
                outcomes[target.id] = uninstall ? (result.changed ? "已卸载 Runbar MCP" : "未安装，无需卸载") : (result.changed ? "已安装 / 更新" : "配置已是最新")
                backups[target.id] = result.backup
                completed += 1
            } catch {
                outcomes[target.id] = "未完成：\(error.localizedDescription)"
                failed += 1
            }
        }
        installing = false
        await refresh(connection: self.connection)
        message = "完成 \(completed) 个 Agent" + (failed > 0 ? "，\(failed) 个未完成，请查看原因。" : "。请重连 MCP 或重启对应 Agent；Qoder CLI 可执行 /mcp reload。")
    }
    func showBackup(_ target: MCPClientTarget) {
        if let file = backups[target.id] { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }
}
