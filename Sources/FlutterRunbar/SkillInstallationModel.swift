import AppKit
import Foundation
import RunbarCore

struct SkillAgentTarget: Identifiable, Sendable {
    let id: String
    let name: String
    let root: URL
    let detected: Bool
    let custom: Bool
}
private struct SavedSkillTarget: Codable { let id: String; let name: String; let path: String }

@MainActor
final class SkillInstallationModel: ObservableObject {
    @Published private(set) var targets: [SkillAgentTarget] = []
    @Published private(set) var states: [String: RunbarSkillInspection] = [:]
    @Published var selection = Set<String>()
    @Published var replaceCustom = Set<String>()
    @Published private(set) var checking = false
    @Published private(set) var installing = false
    @Published private(set) var version = ""
    @Published private(set) var revision = ""
    @Published private(set) var error: String?
    @Published private(set) var message: String?
    @Published private(set) var outcomes: [String: String] = [:]
    @Published private(set) var backups: [String: URL] = [:]
    private var overrides: [String: String]
    private var custom: [SavedSkillTarget]
    private var payload: RunbarSkillPayload?
    private var engine: RunbarSkillInstaller?
    private var backupRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FlutterRunbar/skill-backups", isDirectory: true)
    private var selectedDefaults = false
    var updateCount: Int { states.values.filter(\.hasUpdate).count }
    var busy: Bool { checking || installing }
    var canInstall: Bool {
        !busy && engine != nil && selection.contains(where: { states[$0]?.state != .current }) && !selection.isEmpty && selection.allSatisfy {
            guard let state = states[$0] else { return false }
            return state.canInstall && (!state.requiresReplacementApproval || replaceCustom.contains($0))
        }
    }
    init() {
        overrides = UserDefaults.standard.dictionary(forKey: "skillAgentDirectories") as? [String: String] ?? [:]
        custom = UserDefaults.standard.data(forKey: "skillCustomTargets").flatMap { try? JSONDecoder().decode([SavedSkillTarget].self, from: $0) } ?? []
        rebuildTargets()
    }
    func configure(root: URL) { backupRoot = root.appendingPathComponent("skill-backups", isDirectory: true) }
    private func rebuildTargets() {
        let home = FileManager.default.homeDirectoryForCurrentUser, files = FileManager.default
        targets = RunbarSkillAgent.allCases.map { agent in
            let normal = agent.defaultDirectory(home: home, xdgConfigHome: ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"])
            let root = overrides[agent.rawValue].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? normal
            let detected = files.fileExists(atPath: home.appendingPathComponent(agent.configurationFolder).path) || files.fileExists(atPath: root.path)
            return SkillAgentTarget(id: agent.rawValue, name: agent.title, root: root, detected: detected, custom: false)
        }
        // Keep an existing legacy Codex copy visible so it can be updated too.
        // Do not create a second installation there for new users.
        let legacy = overrides["codex-legacy"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".codex/skills", isDirectory: true)
        if (overrides["codex-legacy"] != nil || files.fileExists(atPath: legacy.appendingPathComponent("runbar-diagnostics/SKILL.md").path)),
           !targets.contains(where: { $0.root.resolvingSymlinksInPath() == legacy.resolvingSymlinksInPath() }) {
            targets.append(SkillAgentTarget(id: "codex-legacy", name: "Codex（兼容目录）", root: legacy, detected: true, custom: false))
        }
        targets += custom.prefix(24).filter { $0.path.hasPrefix("/") }.map {
            SkillAgentTarget(id: $0.id, name: $0.name, root: URL(fileURLWithPath: $0.path, isDirectory: true), detected: true, custom: true)
        }
    }
    func refresh() async {
        guard !busy else { return }
        checking = true; error = nil; engine = nil; payload = nil
        defer { checking = false }
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Skills/runbar-diagnostics", isDirectory: true) else { error = "此构建未包含可安装的 Skill。"; return }
        do {
            let payload = try await Task.detached(priority: .utility) { try RunbarSkillPayload(directory: directory) }.value
            self.payload = payload; version = payload.manifest.version; revision = payload.manifest.revision
            let engine = RunbarSkillInstaller(payload: payload, backupRoot: backupRoot)
            self.engine = engine; rebuildTargets()
            var values: [String: RunbarSkillInspection] = [:]
            for target in targets { values[target.id] = await engine.inspect(root: target.root) }
            states = values
            if !selectedDefaults {
                selection = Set(targets.filter { $0.detected && values[$0.id]?.canInstall == true && values[$0.id]?.state != .current }.map(\.id))
                selectedDefaults = true
            }
            message = updateCount > 0 ? "检测到 \(updateCount) 个位置有 Skill 更新。" : "检查完成，内置 Skill \(version)。"
        } catch { self.error = "无法读取内置 Skill：\(error.localizedDescription)" }
    }
    func shouldOfferAtLaunch() async -> Bool {
        #if SCREENSHOT_PREVIEW || LIVE_LOG_VALIDATION
        return false
        #else
        await refresh()
        guard payload != nil, error == nil else { return false }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "skillLastPromptRevision") != revision else { return false }
        let first = !defaults.bool(forKey: "skillInitialPromptSeen")
        guard first || updateCount > 0 else { return false }
        // Persist before presentation; repeated status-label appearances or
        // choosing Later must not reopen the same prompt every launch.
        defaults.set(revision, forKey: "skillLastPromptRevision")
        defaults.set(true, forKey: "skillInitialPromptSeen")
        return true
        #endif
    }
    func chooseDirectory(_ target: SkillAgentTarget) {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.title = "选择 \(target.name) 的 Skill 根目录"
        panel.message = "选择存放各个 Skill 文件夹的位置，不是 runbar-diagnostics 文件夹本身。"
        panel.directoryURL = FileManager.default.fileExists(atPath: target.root.path) ? target.root : target.root.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.lastPathComponent != RunbarSkillPayload.name else { error = "请选择 runbar-diagnostics 的上一级 Skill 目录。"; return }
        if target.custom {
            custom = custom.map { $0.id == target.id ? SavedSkillTarget(id: $0.id, name: $0.name, path: url.path) : $0 }
            persistCustom()
        } else { overrides[target.id] = url.path; UserDefaults.standard.set(overrides, forKey: "skillAgentDirectories") }
        replaceCustom.remove(target.id); outcomes[target.id] = nil; backups[target.id] = nil
        rebuildTargets(); Task { await refresh() }
    }
    func addTarget() {
        guard !busy else { return }
        guard custom.count < 24 else { error = "自定义目录过多，请先移除不再使用的条目。"; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.title = "选择其他 AI 工具的 Skill 根目录"
        panel.message = "安装到所选目录下的 runbar-diagnostics 文件夹。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.lastPathComponent != RunbarSkillPayload.name else { error = "请选择 Skill 的上一级目录。"; return }
        guard !targets.contains(where: { $0.root.standardizedFileURL == url.standardizedFileURL }) else { error = "这个目录已经在列表中。"; return }
        let id = "custom-" + UUID().uuidString
        custom.append(SavedSkillTarget(id: id, name: "其他 Agent · " + url.deletingLastPathComponent().lastPathComponent, path: url.path))
        persistCustom(); selection.insert(id); rebuildTargets(); Task { await refresh() }
    }
    func removeTarget(_ target: SkillAgentTarget) {
        guard !busy, target.custom else { return }
        custom.removeAll { $0.id == target.id }; selection.remove(target.id); replaceCustom.remove(target.id)
        states[target.id] = nil; outcomes[target.id] = nil; backups[target.id] = nil; persistCustom(); rebuildTargets()
        // Removing a saved destination never uninstalls its Skill files.
    }
    private func persistCustom() { if let data = try? JSONEncoder().encode(custom) { UserDefaults.standard.set(data, forKey: "skillCustomTargets") } }
    func installSelected() async {
        guard canInstall, let engine else { return }
        installing = true; error = nil; outcomes = [:]; backups = [:]
        let targets = targets.filter { selection.contains($0.id) }, approved = replaceCustom
        var completed = 0, failures = 0, visited = Set<String>()
        for target in targets {
            let path = target.root.standardizedFileURL.resolvingSymlinksInPath().path
            if visited.contains(path) { outcomes[target.id] = "与其他已选工具共用目录，已同步。"; continue }
            do {
                message = "正在安装 \(target.name)…请完成后再退出 Runbar。"
                let result = try await engine.install(root: target.root, allowReplacingCustom: approved.contains(target.id))
                outcomes[target.id] = result.changed ? "安装 / 更新完成" : "已是最新版本"
                backups[target.id] = result.backup; completed += 1; visited.insert(path)
            } catch { outcomes[target.id] = "未完成：\(error.localizedDescription)"; failures += 1 }
        }
        replaceCustom = []
        installing = false
        await refresh()
        message = "完成 \(completed) 个位置" + (failures > 0 ? "，\(failures) 个未完成，请查看各项原因。" : "。请在 AI 工具中刷新 Skill 或重开会话。")
    }
    func showBackup(_ target: SkillAgentTarget) { if let url = backups[target.id] { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
}
