import SwiftUI
import AppKit
import RunbarCore

@main
@MainActor
struct FlutterRunbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Label(!model.busy ? "Runbar" : "命令运行中", systemImage: !model.busy ? "terminal" : "play.circle.fill")
        }
        .menuBarExtraStyle(.window)
        Window("Runbar", id: "manager") {
            ManagerView(model: model)
                .frame(minWidth: 880, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 760)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if SCREENSHOT_PREVIEW
    private var previewWindow: NSWindow?
    private var previewMenuWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        if let theme = arguments.firstIndex(of: "--screenshot-appearance"), arguments.indices.contains(theme + 1) {
            NSApp.appearance = NSAppearance(named: arguments[theme + 1] == "dark" ? .darkAqua : .aqua)
        }
        if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "--capture-real-menu"),
           ProcessInfo.processInfo.arguments.indices.contains(flag + 1) {
            let folder = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[flag + 1], isDirectory: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.captureActualMenu(in: folder) }
            return
        }
        // A menu-bar agent may not instantiate its Window scene automatically.
        // Host the exact production ManagerView explicitly for screenshot builds.
        let smallPreview = arguments.contains("--screenshot-small-window")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: smallPreview ? 880 : 1100, height: smallPreview ? 620 : 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Runbar · 演示数据（非真实运行）"
        // Match the production Window scene's content minimums, including after
        // NavigationSplitView installs its taller unified toolbar.
        window.contentView = NSHostingView(rootView: ManagerView(model: AppModel.shared).frame(minWidth: 880, minHeight: 620))
        window.center()
        previewWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let flag = arguments.firstIndex(of: "--screenshot-metrics"), arguments.indices.contains(flag + 1) {
            let destination = URL(fileURLWithPath: arguments[flag + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let content = window.contentLayoutRect
                let metrics: [String: Double] = [
                    "frameWidth": Double(window.frame.width), "frameHeight": Double(window.frame.height),
                    "contentWidth": Double(content.width), "contentHeight": Double(content.height)
                ]
                if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: destination, options: .atomic)
                }
            }
        }
        if arguments.contains("--screenshot-main-only") { return }
        let menuWindow = NSWindow(contentRect: NSRect(x: 40, y: 60, width: MenuLayout.width, height: MenuLayout.maximumListHeight + 100),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
        menuWindow.title = "菜单栏项目列表 · 演示数据（非真实运行）"
        // Same MenuContent used by MenuBarExtra; screenshot host only, not a claim
        // that this titlebar or window chrome belongs to the actual popup.
        let menuView = NSHostingView(rootView: MenuContent(model: AppModel.shared).fixedSize(horizontal: false, vertical: true))
        menuWindow.contentView = menuView
        previewMenuWindow = menuWindow
        menuWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            menuView.layoutSubtreeIfNeeded()
            menuWindow.setContentSize(NSSize(width: MenuLayout.width, height: max(100, menuView.fittingSize.height)))
        }
    }
    private func captureActualMenu(in folder: URL) {
        func statusButtons(in view: NSView) -> [NSStatusBarButton] {
            var found = (view as? NSStatusBarButton).map { [$0] } ?? []
            for child in view.subviews { found += statusButtons(in: child) }
            return found
        }
        func report(_ text: String, success: Bool) {
            let name = success ? "actual-menu-ready.txt" : "actual-menu-blocked.txt"
            try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // Public app-owned view hierarchy only: no private selectors/KVC,
        // Accessibility APIs, global input injection, or TCC changes.
        let buttons = NSApp.windows.flatMap { window in
            window.contentView.map { statusButtons(in: $0) } ?? []
        }
        guard buttons.count == 1, let button = buttons.first, button.isEnabled else {
            report("Could not uniquely locate this app's public NSStatusBarButton (found \(buttons.count)). No permission or security changes attempted.", success: false)
            return
        }
        for window in NSApp.windows where window.frame.width > 400 { window.orderOut(nil) }
        button.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            // In this mode no preview host is created. A visible app-owned panel
            // of the menu's width therefore verifies the actual MenuBarExtra opened.
            let panels = NSApp.windows.filter { $0.isVisible && $0.frame.width >= MenuLayout.width - 10 && $0.frame.width < MenuLayout.width + 80 && $0.frame.height > 100 }
            guard panels.count == 1 else {
                report("Status-item action invoked, but actual MenuBarExtra panel was not uniquely visible (found \(panels.count)). No substitute window was created.", success: false)
                return
            }
            report("Opened the app's actual MenuBarExtra through its own NSStatusBarButton.performClick. Fictional data; no command executed. No preview host or permission changes.", success: true)
        }
    }
    #endif
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if SCREENSHOT_PREVIEW
        return .terminateNow
        #else
        let model = AppModel.shared
        guard model.nativeActionProjectID == nil else { return .terminateCancel }
        guard model.busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "命令仍在运行"
        alert.informativeText = "退出将停止所有正在运行的项目，并等待每份日志保存完成。"
        alert.addButton(withTitle: "停止并退出"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        guard model.busy else { return .terminateNow }
        model.stopAllForQuit()
        return .terminateLater
        #endif
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var config = Configuration()
    @Published var history: [RunSession] = []
    @Published var projectRuns: [UUID: ProjectRunState] = [:]
    @Published var selectedProject: UUID?
    @Published var historySelection = HistorySelection()
    var selectedSession: UUID? {
        get { historySelection.focusedID }
        set { historySelection.setSingle(newValue) }
    }
    @Published var logText = ""
    @Published var error: String?
    @Published var nativeActionProjectID: UUID?
    var quitWhenFinished = false
    private var quitReplySent = false
    private var store: SessionStore?
    private var coordinator: ProjectRunCoordinator?
    var busy: Bool { projectRuns.values.contains(where: \.isBusy) }
    var activeCount: Int { projectRuns.values.filter(\.isBusy).count }
    var selectedState: ProjectRunState { selectedProject.map { state(for: $0) } ?? ProjectRunState() }
    var selectedPreset: UUID? {
        get { project?.selectedPreset?.id }
        set { if let id = selectedProject { choosePreset(newValue, for: id) } }
    }
    init() {
        do {
            let store = try SessionStore()
            config = try store.loadConfiguration(); try store.recoverInterrupted(); history = try store.sessions()
            self.store = store
            selectedProject = config.projects.first?.id
            let coordinator = ProjectRunCoordinator(store: store)
            coordinator.onEvent = { [weak self] event in self?.handle(event) }
            self.coordinator = coordinator
            if !store.warnings.isEmpty { error = store.warnings.joined(separator: "\n") }
            #if SCREENSHOT_PREVIEW
            selectedSession = history.first?.id
            loadLog()
            if let first = config.projects.first, var example = history.first {
                // This synthetic live run is distinct from the completed history
                // selected for log preview; no fake live output file is created.
                example.id = UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!
                example.status = .running; example.endedAt = nil; example.exitCode = nil
                var preview = ProjectRunState(); preview.phase = .running
                preview.session = example; preview.command = example.command
                projectRuns[first.id] = preview
            }
            #endif
        } catch { self.error = "初始化失败，请检查本地数据权限：\(error.localizedDescription)" }
    }
    var project: Project? { config.projects.first { $0.id == selectedProject } }
    var preset: CommandPreset? { project?.selectedPreset }
    var session: RunSession? { history.first { $0.id == selectedSession } }
    func state(for id: UUID) -> ProjectRunState { projectRuns[id] ?? ProjectRunState() }
    @discardableResult
    func persist() -> Bool {
        do { guard let store else { throw RunbarError.message("本地存储不可用") }; try store.saveConfiguration(config); return true }
        catch { self.error = "设置保存失败：\(error.localizedDescription)"; return false }
    }
    func chooseProject() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "选择项目目录（支持任意类型或空目录）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let existing = config.projects.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path == path }) { select(existing); return }
        let project = Project(path: path); config.projects.append(project); select(project); persist()
    }
    func select(_ project: Project) {
        selectedProject = project.id
        let records = history.filter { $0.projectPath == project.path }
        selectedSession = records.first(where: { $0.id == state(for: project.id).session?.id })?.id ?? records.first?.id
        loadLog()
    }
    func setProjectKind(_ kind: ProjectKind, for id: UUID) {
        guard !state(for: id).isBusy, let index = config.projects.firstIndex(where: { $0.id == id }) else { return }
        let original = config.projects[index]
        config.projects[index].kind = kind
        if let selected = config.projects[index].selectedPresetID,
           !config.projects[index].availablePresets.contains(where: { $0.id == selected }) {
            config.projects[index].selectedPresetID = config.projects[index].presets.first?.id
        }
        if !persist() { config.projects[index] = original }
    }
    func toggleSession(_ session: RunSession, mode: HistorySelection.Mode = .single) {
        selectedProject = config.projects.first(where: { $0.path == session.projectPath })?.id
        historySelection.select(session.id, visible: visibleHistory.map(\.id), mode: mode)
        loadLog()
    }
    var visibleHistory: [RunSession] {
        guard let path = project?.path else { return [] }
        return history.filter { $0.projectPath == path }.sorted { $0.startedAt > $1.startedAt }
    }
    private var activeSessionIDs: Set<UUID> {
        Set(projectRuns.values.filter(\.isBusy).compactMap { $0.session?.id })
    }
    func canDeleteSessions(_ ids: Set<UUID>) -> Bool {
        let finishedIDs = Set(history.filter { $0.status != .running }.map(\.id))
        return !ids.isEmpty && ids.isDisjoint(with: activeSessionIDs) && ids.isSubset(of: finishedIDs)
    }
    func deletionIDs(for session: RunSession) -> Set<UUID> {
        historySelection.ids.contains(session.id) ? historySelection.ids : [session.id]
    }
    func selectAllDeletableHistory() {
        let active = activeSessionIDs
        historySelection.selectAll(visibleHistory.filter { $0.status != .running && !active.contains($0.id) }.map(\.id))
        loadLog()
    }
    func deleteSessions(_ ids: Set<UUID>) {
        guard let store, canDeleteSessions(ids) else { error = "不能删除正在运行或已不存在的记录。"; return }
        do {
            try store.trashSessions(ids, activeSessionIDs: activeSessionIDs)
            history.removeAll { ids.contains($0.id) }
            historySelection.remove(ids, visible: visibleHistory.map(\.id))
            loadLog()
        } catch { self.error = "删除记录失败：\(error.localizedDescription)" }
    }
    func removeProject(_ id: UUID) {
        let original = config
        do {
            let active = Set(projectRuns.filter { $0.value.isBusy }.map(\.key))
            guard try config.removeProject(id, activeProjectIDs: active) != nil else { return }
            guard persist() else { config = original; return }
            projectRuns[id] = nil
            if selectedProject == id {
                if let next = config.projects.first { select(next) }
                else { selectedProject = nil; selectedSession = nil; logText = "" }
            }
        } catch { self.error = error.localizedDescription }
    }
    func choosePreset(_ presetID: UUID?, for projectID: UUID) {
        guard !state(for: projectID).isBusy,
              let index = config.projects.firstIndex(where: { $0.id == projectID }),
              config.projects[index].availablePresets.contains(where: { $0.id == presetID }) else { return }
        config.projects[index].selectedPresetID = presetID; persist()
    }
    func savePreset(name: String, command: String, id: UUID?, projectID: UUID?) -> Bool {
        guard let index = config.projects.firstIndex(where: { $0.id == projectID }),
              !state(for: config.projects[index].id).isBusy else { return false }
        let original = config.projects[index]
        do {
            try config.projects[index].savePreset(name: name, command: command, id: id)
            guard persist() else { config.projects[index] = original; return false }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func run(projectID: UUID) {
        #if SCREENSHOT_PREVIEW
        error = "演示模式不会执行命令。"
        return
        #else
        guard !quitWhenFinished, nativeActionProjectID == nil, !state(for: projectID).isBusy,
              let project = config.projects.first(where: { $0.id == projectID }),
              let preset = project.selectedPreset, let coordinator else { return }
        guard persist() else { return }
        if preset.builtInAction == .resetMacOSSandbox {
            resetSandbox(project: project)
        } else {
            coordinator.start(project: project, preset: preset, extraPath: config.extraPath)
        }
        #endif
    }
    private func resetSandbox(project: Project) {
        guard let store else { error = "本地存储不可用，未执行清理。"; return }
        // A single native flow blocks reentrant run buttons while AppKit runs modal loops.
        nativeActionProjectID = project.id
        var state = ProjectRunState(); state.phase = .starting
        state.command = "[内置] 清空 macOS App 沙盒"
        projectRuns[project.id] = state
        defer { projectRuns[project.id] = ProjectRunState(); nativeActionProjectID = nil }
        var session = RunSession(projectPath: project.path, command: state.command!)
        var log: RunLog?
        var didTrash = false
        func append(_ text: String) throws {
            try log?.append(Data((text + "\n").utf8))
            if selectedSession == session.id { logText = (try? store.tail(session.id)) ?? logText }
        }
        do {
            try store.save(session)
            log = try RunLog(directory: store.directory(session.id))
            state.session = session; projectRuns[project.id] = state
            replace(session)
            if selectedProject == project.id { selectedSession = session.id; logText = "" }
            try append("内置操作，不执行 shell。仅在核实 App、容器和明确确认后移到废纸篓。")
            let service = SandboxResetService()
            let candidates = try service.discoverApplications(projectPath: project.path)
            guard !candidates.isEmpty else { throw RunbarError.message("未找到 macOS 构建产物，请先构建或运行该项目。") }
            let application: URL
            if candidates.count == 1 {
                application = candidates[0]
            } else {
                NSApp.activate(ignoringOtherApps: true)
                let chooser = NSAlert()
                chooser.messageText = "选择此项目的 macOS App"
                chooser.informativeText = "发现多个构建配置，请明确选择；不会自动猜测 Debug / Release 或 flavor。"
                chooser.addButton(withTitle: "取消")
                chooser.addButton(withTitle: "检查所选 App")
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 460, height: 26))
                picker.addItems(withTitles: candidates.map { $0.deletingLastPathComponent().lastPathComponent + "/" + $0.lastPathComponent })
                chooser.accessoryView = picker
                guard chooser.runModal() == .alertSecondButtonReturn else { throw SandboxResetError.cancelled }
                guard candidates.indices.contains(picker.indexOfSelectedItem) else { throw SandboxResetError.cancelled }
                application = candidates[picker.indexOfSelectedItem]
            }
            let plan = try service.inspect(projectPath: project.path, applicationURL: application)
            try append("App：\(plan.applicationURL.path)\nBundle ID：\(plan.bundleIdentifier)\n整个容器：\(plan.containerURL.path)")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "清空整个 macOS App 沙盒？"
            alert.informativeText = "App：\(plan.applicationURL.path)\nBundle ID：\(plan.bundleIdentifier)\n完整容器：\(plan.containerURL.path)\n\n将整个容器移到废纸篓，包括 Documents、Library、tmp 和容器元数据。相同 Bundle ID 的其他安装副本也会受影响。\n不清理外部链接目标、App Group、钥匙串或云端数据。请停止 IDE/Runbar 运行任务并退出 App。系统拒绝访问时将停止，不强制删除。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "移到废纸篓")
            // First/default button is deliberately non-destructive.
            guard alert.runModal() == .alertSecondButtonReturn else { throw SandboxResetError.cancelled }
            try append("用户已确认；重新检查 App、运行状态及容器身份。")
            let destination = try service.reset(plan, approved: true)
            didTrash = true
            session.status = .succeeded
            try append("已将整个容器移到废纸篓。" + (destination.map { " 位置：\($0.path)" } ?? ""))
            try append("未删除外部共享数据。下次启动通常重新创建容器；若需恢复，先退出应用再从废纸篓放回。")
        } catch SandboxResetError.cancelled {
            session.status = .cancelled
            try? append("已取消；没有清理任何沙盒数据。")
        } catch {
            session.status = .failed
            session.error = didTrash ? "容器已移到废纸篓，但记录结果失败：\(error.localizedDescription)" : error.localizedDescription
            try? append("未完成：\(session.error!)")
            self.error = session.error
        }
        session.endedAt = Date()
        session.duration = session.endedAt!.timeIntervalSince(session.startedAt)
        // Native actions have no shell exit code; status and text express the result.
        do { try log?.close(); try store.save(session) }
        catch { self.error = "\(didTrash ? "容器已移到废纸篓；" : "")保存操作记录失败：\(error.localizedDescription)" }
        replace(session)
        if selectedSession == session.id { loadLog() }
    }
    func run() { if let id = selectedProject { run(projectID: id) } }
    func stop(projectID: UUID) {
        #if SCREENSHOT_PREVIEW
        projectRuns[projectID] = ProjectRunState()
        #else
        guard nativeActionProjectID != projectID else { return }
        coordinator?.stop(projectID: projectID)
        #endif
    }
    func stop() { if let id = selectedProject { stop(projectID: id) } }
    func stopAllForQuit() {
        quitWhenFinished = true
        coordinator?.stopAll()
        finishQuitIfReady()
    }
    private func finishQuitIfReady() {
        guard quitWhenFinished, !busy, !quitReplySent else { return }
        quitReplySent = true
        // Defer one main-queue turn so applicationShouldTerminate has returned
        // .terminateLater, and the final session event has updated the UI/history.
        DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
    }
    func handle(_ event: ProjectRunCoordinator.Event) {
        switch event {
        case .stateChanged(let id, let state): projectRuns[id] = state
        case .started(let id, let value):
            replace(value)
            // Another project's start or finish must not steal the viewed log.
            if selectedProject == id { selectedSession = value.id; logText = "" }
        case .output(_, let sessionID, _):
            if selectedSession == sessionID { logText = coordinator?.liveLog(for: sessionID) ?? "" }
        case .updated(_, let value): replace(value)
        case .finished(let id, let value):
            let hadStarted = history.contains { $0.id == value.id }
            replace(value)
            if selectedSession == value.id { loadLog() }
            else if !hadStarted && selectedProject == id { selectedSession = value.id; loadLog() }
            if let problem = value.error { report(problem, projectID: id) }
            finishQuitIfReady()
        case .failure(let id, let message): report(message, projectID: id); finishQuitIfReady()
        }
    }
    private func report(_ message: String, projectID: UUID) {
        let name = config.projects.first { $0.id == projectID }?.name ?? "项目"
        error = "\(name)：\(message)"
    }
    private func replace(_ value: RunSession) {
        if let i = history.firstIndex(where: { $0.id == value.id }) { history[i] = value } else { history.insert(value, at: 0) }
    }
    func loadLog() {
        guard let id = selectedSession, let store else { logText = ""; return }
        // Live snapshots share the coordinator's delivery boundary; reading disk
        // could include bytes whose queued UI event has not arrived yet.
        if let live = coordinator?.liveLog(for: id) { logText = live; return }
        do { logText = try store.tail(id) }
        catch { logText = ""; self.error = "读取日志失败：\(error.localizedDescription)" }
    }
    var selectedOutputFile: URL? {
        guard let id = selectedSession, let store else { return nil }
        return try? store.outputFile(for: id)
    }
    var selectedOutputPath: String? {
        guard let id = selectedSession, let store else { return nil }
        return store.directory(id).appendingPathComponent("output.raw").path
    }
    func revealSelectedOutput() {
        guard let id = selectedSession, let store else { return }
        do { NSWorkspace.shared.activateFileViewerSelecting([try store.outputFile(for: id)]) }
        catch { self.error = error.localizedDescription }
    }
    func showFiles() { guard let id = selectedSession, let store else { return }; NSWorkspace.shared.open(store.directory(id)) }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func openLiveURL(_ value: String, projectID: UUID) {
        guard state(for: projectID).liveDevToolsURLs.contains(value), let url = DevToolsLink.validatedURL(value) else { return }
        NSWorkspace.shared.open(url)
    }
    func liveProjectID(for sessionID: UUID) -> UUID? {
        projectRuns.first { $0.value.phase == .running && $0.value.session?.id == sessionID }?.key
    }
}

private enum MenuLayout {
    static let width: CGFloat = 480
    static let maximumListHeight: CGFloat = 320
}

private struct MenuListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var listHeight: CGFloat = 0
    private var initialListHeight: CGFloat {
        CGFloat(model.config.projects.count) * 48 + CGFloat(model.projectRuns.values.reduce(0) { $0 + $1.liveDevToolsURLs.count }) * 18
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Runbar", systemImage: "terminal").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("打开主界面") { openWindow(id: "manager"); NSApp.activate(ignoringOtherApps: true) }
                    .accessibilityHint("打开项目、命令和运行日志管理窗口")
            }.padding(.horizontal, 10).padding(.vertical, 7)
            Divider()
            if model.config.projects.isEmpty {
                Text("还没有项目，请先在主界面添加。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.config.projects) { project in
                            ProjectMenuRow(model: model, project: project)
                            Divider().padding(.horizontal, 10)
                        }
                    }.background(GeometryReader { geometry in
                        Color.clear.preference(key: MenuListHeightKey.self, value: geometry.size.height)
                    })
                }.frame(height: min(MenuLayout.maximumListHeight, listHeight > 0 ? listHeight : initialListHeight))
                    .onPreferenceChange(MenuListHeightKey.self) { listHeight = $0 }
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 6) {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error)
                    Spacer()
                    Button { model.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("关闭提示")
                }.padding(.horizontal, 10).padding(.vertical, 5)
                Divider()
            }
            HStack {
                Text(model.busy ? "\(model.activeCount) 个项目运行中" : "就绪")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }.padding(.horizontal, 10).padding(.vertical, 5)
        }.controlSize(.small).frame(width: MenuLayout.width)
    }
}

private struct ProjectMenuRow: View {
    @ObservedObject var model: AppModel
    let project: Project
    private var state: ProjectRunState { model.state(for: project.id) }
    private var stateIcon: String {
        switch state.phase {
        case .idle: return "circle"
        case .starting: return "ellipsis"
        case .running: return "play.fill"
        case .stopping: return "stop.fill"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: stateIcon).font(.system(size: 8))
                            .foregroundStyle(state.phase == .running ? .green : .secondary)
                            .frame(width: 8).accessibilityHidden(true)
                        Text(project.name).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                    }.accessibilityElement(children: .ignore)
                        .accessibilityLabel("项目 \(project.name)")
                        .accessibilityValue(phaseLabel(state.phase))
                    Text(project.path).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(project.path)
                        .accessibilityLabel("项目目录 \(project.path)")
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .help("\(project.path)\n\(phaseLabel(state.phase))")
                Picker("命令", selection: Binding(
                    get: { project.selectedPreset?.id },
                    set: { model.choosePreset($0, for: project.id) }
                )) {
                    if project.presets.isEmpty { Text("未配置命令").tag(Optional<UUID>.none) }
                    ForEach(project.availablePresets) { preset in Text(preset.name).tag(Optional(preset.id)) }
                }.labelsHidden().frame(width: 128).disabled(state.isBusy || model.quitWhenFinished)
                    .accessibilityLabel("\(project.name)的命令")
                    .help(state.command ?? project.selectedPreset?.displayCommand ?? "请在主界面添加命令")
                Button("运行") { model.run(projectID: project.id) }
                    .disabled(state.isBusy || project.selectedPreset == nil || model.quitWhenFinished || model.nativeActionProjectID != nil)
                    .accessibilityLabel("运行\(project.name)")
                Button("停止") { model.stop(projectID: project.id) }
                    .disabled(!state.isBusy || state.phase == .stopping || model.nativeActionProjectID == project.id)
                    .accessibilityLabel("停止\(project.name)")
            }.controlSize(.small)
            ForEach(state.liveDevToolsURLs, id: \.self) { value in
                Button { model.openLiveURL(value, projectID: project.id) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link").font(.system(size: 10))
                        Text(value).font(.system(size: 10, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).foregroundStyle(.blue).help(value)
                    .accessibilityLabel("打开\(project.name)的 DevTools")
                    .accessibilityValue(value)
            }
            if let message = state.error {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(1).help(message)
            }
        }.padding(.horizontal, 10).padding(.vertical, 6)
    }
}

private func phaseLabel(_ phase: ProjectRunPhase) -> String {
    switch phase { case .idle: return "未运行"; case .starting: return "正在启动…"; case .running: return "运行中"; case .stopping: return "正在停止…" }
}
