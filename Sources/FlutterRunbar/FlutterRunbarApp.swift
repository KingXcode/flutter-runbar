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
            RunbarStatusLabel(model: model)
        }
        .menuBarExtraStyle(.window)
        Window("Runbar", id: "manager") {
            ManagerView(model: model)
                .frame(minWidth: 880, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 760)
    }
}

private struct RunbarStatusLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Label(model.busy ? "Runbar · 命令运行中" : model.attachmentCount > 0 ? "Runbar · 应用监听中" : "Runbar", systemImage: model.busy || model.attachmentCount > 0 ? "terminal.fill" : "terminal")
            .symbolRenderingMode(.monochrome)
            .help("Runbar · \(model.activeCount) 个项目运行 · \(model.attachmentCount) 个应用监听")
            .onAppear {
                model.installManagerOpener {
                    openWindow(id: "manager")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if SCREENSHOT_PREVIEW || LIVE_LOG_VALIDATION
    private var previewWindow: NSWindow?
    private var previewMenuWindow: NSWindow?
    #if LIVE_LOG_VALIDATION
    private var responsivenessProbe: LogResponsivenessProbe?
    #endif
    #endif
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Let SwiftUI finish its initial application/window setup first.
        DispatchQueue.main.async { AppModel.shared.restoreDockVisibility(); AppModel.shared.installGlobalShortcut() }
        #if SCREENSHOT_PREVIEW || LIVE_LOG_VALIDATION
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
        #if LIVE_LOG_VALIDATION
        // Isolated QA host with the real runner; fixture HOME and commands are
        // supplied by the test launcher. Never enabled in production builds.
        responsivenessProbe = LogResponsivenessProbe()
        return
        #endif
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
        #endif
    }
    #if SCREENSHOT_PREVIEW || LIVE_LOG_VALIDATION
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
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showManagerWindow()
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if SCREENSHOT_PREVIEW
        return .terminateNow
        #else
        let model = AppModel.shared
        guard model.nativeActionProjectID == nil else { return .terminateCancel }
        guard model.busy else { model.finishLogQueriesForQuit(); return .terminateLater }
        let alert = NSAlert()
        alert.messageText = "命令仍在运行"
        alert.informativeText = "退出将停止所有正在运行的项目，并等待每份日志保存完成。"
        alert.addButton(withTitle: "停止并退出"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        guard model.busy else { model.finishLogQueriesForQuit(); return .terminateLater }
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
    @Published var selectedApplication: UUID?
    @Published var applicationConnections: [UUID: ApplicationConnectionState] = [:]
    private var applicationLoggers: [UUID: ApplicationLogSession] = [:]
    private var applicationWatchers: [UUID: Task<Void, Never>] = [:]
    private var applicationFlutterControllers: [UUID: ApplicationFlutterControls] = [:]
    private var applicationFlutterTasks: [UUID: Task<Void, Never>] = [:]
    private let devToolsServer = LocalDevToolsServer()
    @Published var historySelection = HistorySelection()
    var selectedSession: UUID? {
        get { historySelection.focusedID }
        set { historySelection.setSingle(newValue) }
    }
    @Published private(set) var logPage: LogFilePage?
    private var logReading = false
    @Published private(set) var logNavigating = false
    @Published private(set) var logShowsLoading = false
    @Published private(set) var logFollowing = true
    @Published private(set) var logHasNewOutput = false
    @Published private(set) var logScrollRevision = 0
    private(set) var logScrollPlacement = LogScrollPlacement.end
    @Published private(set) var logTotalBytes: UInt64 = 0
    @Published private(set) var logSourceBytes: UInt64 = 0
    @Published private(set) var logPositionPercent = 0
    @Published var logSearchText = "" { didSet { if logSearchText != oldValue { scheduleLogQuery() } } }
    @Published private(set) var logMatchCount: UInt64 = 0
    @Published private(set) var logMatchOrdinal: UInt64 = 0
    @Published private(set) var logQueryBusy = false
    @Published private(set) var logQueryProgress: Double = 0
    @Published private(set) var logSearchContext = false
    @Published private(set) var logSearchHighlight: NSRange?
    @Published private(set) var logTimeMarks: [LogTimeMark] = []
    @Published var logShowsTimestamps = UserDefaults.standard.object(forKey: "logShowsTimestamps") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(logShowsTimestamps, forKey: "logShowsTimestamps")
            if logShowsTimestamps { refreshTimestampMarks() }
        }
    }
    var logPreferences: LogPreferences { config.logPreferences ?? LogPreferences() }
    var logFilter: LogFilter { logPreferences.filter }
    private var logQueryTask: Task<Void, Never>?
    var logText: String { logPage?.text ?? "" }
    private let logLoader = LogPageLoader()
    private var logReadTask: Task<Void, Never>?
    private var logLoadingIndicatorTask: Task<Void, Never>?
    private var logRefreshTask: Task<Void, Never>?
    private var logReadToken = UUID()
    private var displayedLogSession: UUID?
    private var logRefreshNeeded = false
    @Published var error: String?
    @Published var nativeActionProjectID: UUID?
    @Published private(set) var showInDock = UserDefaults.standard.bool(forKey: "showInDock")
    @Published private(set) var globalShortcut = UserDefaults.standard.data(forKey: "globalShortcutPreferences")
        .flatMap { try? JSONDecoder().decode(GlobalShortcutPreferences.self, from: $0) } ?? GlobalShortcutPreferences()
    @Published private(set) var globalShortcutError: String?
    private let hotkeyController = GlobalHotKeyController()
    private var shortcutRecording = false
    private var raisingManagedWindows = false
    #if LIVE_LOG_VALIDATION
    private(set) var shortcutInvocationCount = 0
    #endif
    private var managerOpener: (() -> Void)?
    private var pendingManagerOpen = false
    private var installedInitialManagerOpener = false
    var quitWhenFinished = false
    private var quitReplySent = false
    private var logShutdownStarted = false
    private var store: SessionStore?
    let network = NetworkMonitor()
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
            network.configure(root: store.root)
            network.onFinished = { [weak self] in self?.objectWillChange.send() }
            selectedProject = config.projects.first?.id
            let coordinator = ProjectRunCoordinator(store: store)
            coordinator.onEvent = { [weak self] event in self?.handle(event) }
            self.coordinator = coordinator
            if selectedProject == nil, let first = config.applications?.first { selectApplication(first) }
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
    var applications: [ApplicationTarget] { config.applications ?? [] }
    var application: ApplicationTarget? { applications.first { $0.id == selectedApplication } }
    var knownApplicationEndpoints: [VMServiceEndpoint] { network.knownEndpoints + applicationConnections.values.compactMap(\.endpoint) }
    var attachmentCount: Int { applicationConnections.values.filter(\.active).count }
    var project: Project? { config.projects.first { $0.id == selectedProject } }
    var preset: CommandPreset? { project?.selectedPreset }
    var session: RunSession? { history.first { $0.id == selectedSession } }
    func state(for id: UUID) -> ProjectRunState { projectRuns[id] ?? ProjectRunState() }
    func restoreDockVisibility() {
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() == policy || NSApp.setActivationPolicy(policy) else {
            error = "无法恢复 Dock 显示设置，请在设置中重试。"
            return
        }
    }
    func setDockVisibility(_ visible: Bool) {
        guard visible != showInDock else { return }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() == policy || NSApp.setActivationPolicy(policy) else {
            error = "无法切换 Dock 显示状态，设置未更改。"
            return
        }
        showInDock = visible
        UserDefaults.standard.set(visible, forKey: "showInDock")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }
    func installManagerOpener(_ opener: @escaping () -> Void) {
        managerOpener = opener
        let initialPresentation = !installedInitialManagerOpener && showInDock
        installedInitialManagerOpener = true
        if pendingManagerOpen || initialPresentation {
            pendingManagerOpen = false
            DispatchQueue.main.async { opener() }
        }
    }
    func showManagerWindow() {
        if let managerOpener { managerOpener() }
        else { pendingManagerOpen = true }
        DispatchQueue.main.async {
            for window in NSApp.windows where window.title == "Runbar" && window.canBecomeMain {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func installGlobalShortcut() {
        hotkeyController.action = { [weak self] in self?.raiseManagedWindows() }
        do {
            try hotkeyController.register(globalShortcut.enabled && !shortcutRecording ? globalShortcut.shortcut : nil)
            globalShortcutError = nil
        } catch { globalShortcutError = error.localizedDescription }
    }
    func setGlobalShortcut(_ value: GlobalShortcut) {
        do {
            let value = try value.validated()
            try hotkeyController.register(value)
            globalShortcut = GlobalShortcutPreferences(enabled: true, shortcut: value)
            saveGlobalShortcut(); globalShortcutError = nil
        } catch { globalShortcutError = error.localizedDescription }
    }
    func setGlobalShortcutEnabled(_ enabled: Bool) {
        do {
            try hotkeyController.register(enabled ? globalShortcut.shortcut : nil)
            globalShortcut.enabled = enabled; saveGlobalShortcut(); globalShortcutError = nil
        } catch { globalShortcutError = error.localizedDescription }
    }
    func setShortcutRecording(_ recording: Bool) {
        shortcutRecording = recording
        installGlobalShortcut()
    }
    private func saveGlobalShortcut() {
        if let data = try? JSONEncoder().encode(globalShortcut) { UserDefaults.standard.set(data, forKey: "globalShortcutPreferences") }
    }
    private func raiseManagedWindows() {
        #if LIVE_LOG_VALIDATION
        shortcutInvocationCount += 1
        #endif
        showManagerWindow()
        guard !raisingManagedWindows, !quitWhenFinished else { return }
        raisingManagedWindows = true
        Task {
            let processes = await coordinator?.activeProcesses() ?? []
            let current = processes.filter { state(for: $0.projectID).session?.id == $0.sessionID && state(for: $0.projectID).isBusy }
            await ManagedApplicationActivator.raise(current)
            showManagerWindow(); raisingManagedWindows = false
        }
    }
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
        selectedApplication = nil; selectedProject = project.id
        let records = history.filter { $0.attachment == nil && $0.projectPath == project.path }
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
        selectedApplication = session.attachment?.application.id
        selectedProject = session.attachment == nil ? config.projects.first(where: { $0.path == session.projectPath })?.id : nil
        historySelection.select(session.id, visible: visibleHistory.map(\.id), mode: mode)
        loadLog()
    }
    var visibleHistory: [RunSession] {
        if let application { return history.filter { $0.belongs(to: application) }.sorted { $0.startedAt > $1.startedAt } }
        guard let path = project?.path else { return [] }
        return history.filter { $0.attachment == nil && $0.projectPath == path }.sorted { $0.startedAt > $1.startedAt }
    }
    private var activeSessionIDs: Set<UUID> {
        Set(projectRuns.values.filter(\.isBusy).compactMap { $0.session?.id })
            .union(applicationConnections.values.filter(\.active).compactMap(\.sessionID))
    }
    func canDeleteSessions(_ ids: Set<UUID>) -> Bool {
        let finishedIDs = Set(history.filter { $0.status != .running }.map(\.id))
        return !ids.isEmpty && ids.isDisjoint(with: activeSessionIDs.union(network.writingSessionIDs)) && ids.isSubset(of: finishedIDs)
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
                else { selectedProject = nil; selectedSession = nil; loadLog() }
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
        var permissionContainer: String?
        func append(_ text: String) throws {
            try log?.append(Data((text + "\n").utf8))
            if selectedSession == session.id { refreshLogAfterOutput() }
        }
        do {
            try store.save(session)
            log = try RunLog(directory: store.directory(session.id))
            state.session = session; projectRuns[project.id] = state
            replace(session)
            if selectedProject == project.id { selectedSession = session.id; loadLog() }
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
            if !didTrash, let resetError = error as? SandboxResetError,
               case .permissionDenied(let path) = resetError {
                permissionContainer = path
            } else { self.error = session.error }
        }
        session.endedAt = Date()
        session.duration = session.endedAt!.timeIntervalSince(session.startedAt)
        // Native actions have no shell exit code; status and text express the result.
        do { try log?.close(); try store.save(session) }
        catch { self.error = "\(didTrash ? "容器已移到废纸篓；" : "")保存操作记录失败：\(error.localizedDescription)" }
        replace(session)
        if selectedSession == session.id { loadLog() }
        if let permissionContainer { SandboxResetPermissionAlert.present(containerPath: permissionContainer) }
    }
    func run() { if let id = selectedProject { run(projectID: id) } }
    func selectApplication(_ target: ApplicationTarget) {
        selectedProject = nil; selectedApplication = target.id
        let current = applicationConnections[target.id]?.sessionID
        selectedSession = history.first { $0.id == current }?.id ?? history.first { $0.belongs(to: target) }?.id
        loadLog()
    }
    func connectedApplication(for candidate: RunningApplicationCandidate) -> ApplicationTarget? {
        applications.first { $0.matches(candidate.application) && applicationConnections[$0.id]?.candidate?.processID == candidate.processID && applicationConnections[$0.id]?.active == true }
    }
    func connectApplication(_ candidate: RunningApplicationCandidate, endpoint: VMServiceEndpoint, enteredAddress: String) async throws {
        guard !quitWhenFinished, !logShutdownStarted, let store else { throw RunbarError.message("应用正在退出或本地存储不可用。") }
        guard ApplicationDiscovery.isCurrent(candidate) else { throw RunbarError.message("所选 App 已退出，请刷新列表。") }
        let resolvedEndpoint = try await ApplicationServiceProbe().connectionEndpoint(endpoint, processID: candidate.processID, flutterDetected: candidate.flutterDetected)
        try Task.checkCancellation()
        guard !logShutdownStarted, !quitWhenFinished else { throw CancellationError() }
        guard ApplicationDiscovery.isCurrent(candidate) else { throw RunbarError.message("所选 App 已退出，请刷新列表。") }
        let target = applications.first { $0.matches(candidate.application) }
            ?? history.compactMap { $0.attachment?.application }.first { $0.matches(candidate.application) }
            ?? candidate.application
        guard applicationConnections[target.id]?.active != true else { throw RunbarError.message("该应用已有连接，请先断开原连接或查看当前记录。") }
        let old = config.applications
        if !applications.contains(where: { $0.id == target.id }) {
            config.applications = applications + [target]
            guard persist() else { config.applications = old; throw RunbarError.message("无法保存应用，请检查本地存储权限。") }
        }
        var state = ApplicationConnectionState(); state.phase = .connecting; state.candidate = candidate
        state.endpoint = resolvedEndpoint; state.message = "正在连接"
        if URLComponents(string: enteredAddress)?.queryItems?.contains(where: { $0.name == "uri" }) == true {
            state.devToolsURL = DevToolsLink.validatedURL(enteredAddress)
        }
        applicationConnections[target.id] = state
        let id = target.id
        let generation = state.generation
        let logger = ApplicationLogSession(root: store.root, endpoint: resolvedEndpoint,
            attachment: ApplicationAttachment(application: target, processID: candidate.processID)) { [weak self] event in
                await self?.handleAttachment(event, applicationID: id, generation: generation)
            }
        applicationLoggers[id] = logger; selectApplication(target)
        await logger.start()
        if Task.isCancelled { await logger.disconnect(); throw CancellationError() }
        guard applicationConnections[id]?.generation == generation, applicationConnections[id]?.active == true else { return }
        applicationWatchers[id] = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                guard self.applicationConnections[id]?.generation == generation, self.applicationConnections[id]?.active == true else { return }
                if !ApplicationDiscovery.isCurrent(candidate) {
                    self.applicationConnections[id]?.message = "App 已退出"
                    await logger.disconnect(); return
                }
            }
        }
    }
    private func handleAttachment(_ event: ApplicationLogSession.Event, applicationID id: UUID, generation: UUID) {
        guard applicationConnections[id]?.generation == generation else { return }
        switch event {
        case .started(let value):
            applicationConnections[id]?.sessionID = value.id; replace(value)
            network.started(projectID: id, sessionID: value.id, enabled: applications.first { $0.id == id }?.networkCaptureEnabled == true)
            if let endpoint = applicationConnections[id]?.endpoint { network.discovered(endpoint, sessionID: value.id) }
            if selectedApplication == id { selectedSession = value.id; loadLog() }
        case .connected(let streams):
            guard applicationConnections[id]?.phase == .connecting else { return }
            applicationConnections[id]?.phase = .listening
            applicationConnections[id]?.message = streams.isEmpty ? "已连接 · 当前 VM 不提供日志事件" : "已连接"
            startApplicationFlutterControls(id, generation: generation)
        case .output(let sessionID):
            if selectedSession == sessionID { refreshLogAfterOutput() }
        case .finished(let value):
            network.finished(value.id); replace(value)
            let exited = applicationConnections[id]?.message == "App 已退出" || applicationConnections[id]?.candidate.map { !ApplicationDiscovery.isCurrent($0) } == true
            applicationConnections[id]?.phase = .idle; applicationConnections[id]?.endpoint = nil; applicationConnections[id]?.devToolsURL = nil
            applicationConnections[id]?.message = exited ? "App 已退出" : value.error == nil ? "已断开" : "连接已中断"
            stopApplicationFlutterControls(id)
            applicationLoggers[id] = nil; applicationWatchers[id]?.cancel(); applicationWatchers[id] = nil
            if selectedSession == value.id { loadLog() }
        }
    }
    func disconnectApplication(_ id: UUID) {
        guard let logger = applicationLoggers[id] else { return }
        applicationConnections[id]?.phase = .disconnecting; applicationConnections[id]?.message = "正在断开"
        stopApplicationFlutterControls(id)
        Task { await logger.disconnect() }
    }
    private func startApplicationFlutterControls(_ id: UUID, generation: UUID) {
        guard !quitWhenFinished, !logShutdownStarted, applicationFlutterControllers[id] == nil,
              let state = applicationConnections[id], state.generation == generation, state.phase == .listening,
              let endpoint = state.endpoint, let candidate = state.candidate, ApplicationDiscovery.isCurrent(candidate) else { return }
        let controls = ApplicationFlutterControls(endpoint: endpoint, processID: candidate.processID) { [weak self] availability in
            await self?.updateApplicationFlutterControls(availability, applicationID: id, generation: generation)
        }
        applicationFlutterControllers[id] = controls
        Task { await controls.start() }
    }
    private func updateApplicationFlutterControls(_ availability: ApplicationFlutterControls.Availability, applicationID id: UUID, generation: UUID) {
        guard !quitWhenFinished, !logShutdownStarted, applicationConnections[id]?.generation == generation,
              applicationConnections[id]?.phase == .listening else { return }
        applicationConnections[id]?.flutterControls.actions = availability.actions
        applicationConnections[id]?.flutterControlHint = availability.message
    }
    private func stopApplicationFlutterControls(_ id: UUID) {
        applicationFlutterTasks.removeValue(forKey: id)?.cancel()
        if let controls = applicationFlutterControllers.removeValue(forKey: id) { Task { await controls.disconnect() } }
        applicationConnections[id]?.flutterControls = FlutterRunControls()
        applicationConnections[id]?.flutterControlHint = "连接 App 后检测热更新能力"
        applicationConnections[id]?.flutterControlResult = nil
    }
    func sendApplicationFlutterAction(_ action: FlutterRunAction, applicationID id: UUID) {
        guard !quitWhenFinished, !logShutdownStarted, action == .hotReload || action == .hotRestart,
              let state = applicationConnections[id], state.phase == .listening,
              let candidate = state.candidate, ApplicationDiscovery.isCurrent(candidate),
              state.flutterControls.canSend(action), let controls = applicationFlutterControllers[id] else { return }
        let generation = state.generation
        applicationConnections[id]?.flutterControls.workingAction = action
        applicationConnections[id]?.flutterControlResult = nil
        applicationFlutterTasks[id] = Task { [weak self] in
            var problem: String?
            do { try await controls.perform(action) }
            catch is CancellationError { return }
            catch { problem = error.localizedDescription }
            guard let self, !Task.isCancelled, !self.quitWhenFinished, !self.logShutdownStarted,
                  self.applicationConnections[id]?.generation == generation,
                  self.applicationConnections[id]?.phase == .listening, ApplicationDiscovery.isCurrent(candidate) else { return }
            self.applicationConnections[id]?.flutterControls.workingAction = nil
            self.applicationConnections[id]?.flutterControlResult = action.title + (problem == nil ? "完成" : "失败")
            self.applicationFlutterTasks[id] = nil
            if let problem { self.error = problem }
        }
    }
    func removeApplication(_ id: UUID) {
        guard applicationConnections[id]?.active != true else { error = "请先断开该应用，再从列表移除。"; return }
        let old = config.applications
        config.applications = applications.filter { $0.id != id }
        guard persist() else { config.applications = old; return }
        applicationConnections[id] = nil
        if selectedApplication == id {
            selectedApplication = nil; selectedSession = nil
            if let next = applications.first { selectApplication(next) }
            else if let next = config.projects.first { select(next) }
            else { loadLog() }
        }
    }
    func applicationIsLive(_ sessionID: UUID) -> Bool {
        applicationConnections.values.contains { $0.active && $0.sessionID == sessionID }
    }
    func networkCaptureEnabled(for session: RunSession) -> Bool {
        if let attachment = session.attachment { return applications.first { $0.id == attachment.application.id }?.networkCaptureEnabled == true }
        return config.projects.first { $0.path == session.projectPath }?.networkCaptureEnabled == true
    }
    func setNetworkCaptureEnabled(_ enabled: Bool, session: RunSession) {
        if let id = session.attachment?.application.id, let index = config.applications?.firstIndex(where: { $0.id == id }) {
            let old = config.applications; config.applications?[index].networkCaptureEnabled = enabled
            guard persist() else { config.applications = old; return }; network.setEnabled(enabled, projectID: id)
        } else if let id = config.projects.first(where: { $0.path == session.projectPath })?.id { setNetworkCaptureEnabled(enabled, projectID: id) }
    }
    func openApplicationDevTools(_ id: UUID) {
        guard let state = applicationConnections[id], state.active, let endpoint = state.endpoint else { return }
        if let url = state.devToolsURL { NSWorkspace.shared.open(url); return }
        Task {
            do {
                let url = try await devToolsServer.url(for: endpoint, extraPath: config.extraPath)
                guard applicationConnections[id]?.endpoint == endpoint, applicationConnections[id]?.active == true else { return }
                applicationConnections[id]?.devToolsURL = url; NSWorkspace.shared.open(url)
            } catch { self.error = error.localizedDescription }
        }
    }
    func setNetworkCaptureEnabled(_ enabled: Bool, projectID: UUID) {
        guard let index = config.projects.firstIndex(where: { $0.id == projectID }) else { return }
        let old = config.projects[index].networkCaptureEnabled
        config.projects[index].networkCaptureEnabled = enabled
        guard persist() else { config.projects[index].networkCaptureEnabled = old; return }
        network.setEnabled(enabled, projectID: projectID)
    }
    func stop(projectID: UUID) {
        #if SCREENSHOT_PREVIEW
        projectRuns[projectID] = ProjectRunState()
        #else
        guard nativeActionProjectID != projectID else { return }
        coordinator?.stop(projectID: projectID)
        #endif
    }
    func stop() { if let id = selectedProject { stop(projectID: id) } }
    func sendFlutterAction(_ action: FlutterRunAction, projectID: UUID, sessionID: UUID) {
        guard !quitWhenFinished, nativeActionProjectID == nil,
              config.projects.first(where: { $0.id == projectID })?.kind == .flutter else { return }
        if coordinator?.sendFlutterAction(action, projectID: projectID, sessionID: sessionID) != true {
            report("当前 Flutter 运行不支持此操作，或正在处理其他操作。", projectID: projectID)
        }
    }
    func vsCodeTarget(projectID: UUID, sessionID: UUID) throws -> VSCodeDebugTarget {
        let state = state(for: projectID)
        guard !quitWhenFinished, let project = config.projects.first(where: { $0.id == projectID }), project.kind == .flutter,
              state.phase == .running, state.session?.id == sessionID,
              state.flutterControls?.actions.contains(.hotReload) == true, state.flutterControls?.isDetaching != true,
              let endpoint = state.vmServiceEndpoint else {
            throw RunbarError.message("请先运行此 Flutter 项目的 Debug 命令，等待调试服务就绪后再连接。Profile / Release 不支持断点调试。")
        }
        return VSCodeDebugTarget(projectPath: project.path, projectName: project.name, sessionID: sessionID, endpoint: endpoint)
    }
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
        DispatchQueue.main.async { self.finishLogQueriesForQuit() }
    }
    func finishLogQueriesForQuit() {
        guard !logShutdownStarted else { return }
        logShutdownStarted = true
        logQueryTask?.cancel(); logReadTask?.cancel(); logRefreshTask?.cancel(); logLoadingIndicatorTask?.cancel()
        logReadToken = UUID()
        Task {
            // Wait for the cancelled scan to leave its chunk, then close handles
            // and remove the current disk index before completing normal quit.
            for watcher in self.applicationWatchers.values { watcher.cancel() }
            for task in self.applicationFlutterTasks.values { task.cancel() }
            self.applicationFlutterTasks.removeAll()
            let controls = Array(self.applicationFlutterControllers.values)
            self.applicationFlutterControllers.removeAll()
            for control in controls { await control.disconnect() }
            for logger in Array(self.applicationLoggers.values) { await logger.disconnect() }
            await self.devToolsServer.stop()
            await logLoader.clear()
            await network.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
    func handle(_ event: ProjectRunCoordinator.Event) {
        switch event {
        case .stateChanged(let id, let state): projectRuns[id] = state
        case .started(let id, let value):
            network.started(projectID: id, sessionID: value.id, enabled: config.projects.first { $0.id == id }?.networkCaptureEnabled == true)
            replace(value)
            // Another project's start or finish must not steal the viewed log.
            if selectedProject == id { selectedSession = value.id; loadLog() }
        case .output(_, let sessionID, _):
            if selectedSession == sessionID { refreshLogAfterOutput() }
        case .updated(_, let value): replace(value)
        case .service(_, let sessionID, let endpoint): network.discovered(endpoint, sessionID: sessionID)
        case .finished(let id, let value):
            network.finished(value.id)
            let hadStarted = history.contains { $0.id == value.id }
            replace(value)
            if selectedSession == value.id { loadLog() }
            else if !hadStarted && selectedProject == id { selectedSession = value.id; loadLog() }
            if let failure = value.flutterSandboxAccessFailure {
                if !quitWhenFinished && !logShutdownStarted {
                    SandboxResetPermissionAlert.presentFlutterHotReload(failure: failure)
                }
            } else if let problem = value.error { report(problem, projectID: id) }
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
        if displayedLogSession != selectedSession || selectedSession == nil {
            logQueryTask?.cancel(); logQueryTask = nil
            logReadTask?.cancel(); logRefreshTask?.cancel(); logRefreshTask = nil
            logReadToken = UUID(); finishLogLoading(); logRefreshNeeded = false
            displayedLogSession = selectedSession; logPage = nil; logTotalBytes = 0; logSourceBytes = 0; logTimeMarks = []; logPositionPercent = 0
            logFollowing = true; logHasNewOutput = false
            logMatchCount = 0; logMatchOrdinal = 0; logSearchContext = false; logSearchHighlight = nil
            logQueryBusy = false
            if selectedSession != nil {
                if !logSearchText.isEmpty { logFollowing = false }
                readLog(.latest, placement: .end, matchOrdinal: logSearchText.isEmpty ? nil : 1)
            }
        } else { refreshLogAfterOutput() }
    }
    @discardableResult
    func applyLogFilter(_ filter: LogFilter) -> Bool {
        do {
            let old = config.logPreferences
            var preferences = logPreferences; try preferences.apply(filter)
            config.logPreferences = preferences
            guard persist() else { config.logPreferences = old; return false }
            scheduleLogQuery(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    /// Expected combination errors stay in the preset popover, so a rejected
    /// selection leaves both the active conditions and the popover in place.
    func toggleLogFilterPreset(_ id: UUID) -> String? {
        do {
            let old = config.logPreferences
            var preferences = logPreferences; try preferences.togglePreset(id)
            config.logPreferences = preferences
            guard persist() else { config.logPreferences = old; return error ?? "无法保存筛选方案选择。" }
            if old?.filter != preferences.filter { scheduleLogQuery() }
            return nil
        } catch { return error.localizedDescription }
    }
    @discardableResult
    func saveLogFilterPreset(_ name: String) -> Bool {
        do {
            let old = config.logPreferences
            var preferences = logPreferences; try preferences.savePreset(name: name)
            config.logPreferences = preferences
            guard persist() else { config.logPreferences = old; return false }
            if old?.filter != preferences.filter { scheduleLogQuery() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func deleteLogKeyword(_ keyword: String) {
        let old = config.logPreferences
        var preferences = logPreferences; preferences.keywords.removeAll { $0 == keyword }
        config.logPreferences = preferences
        if !persist() { config.logPreferences = old }
    }
    func deleteLogFilterPreset(_ id: UUID) {
        do {
            let old = config.logPreferences
            var preferences = logPreferences; try preferences.removePreset(id)
            config.logPreferences = preferences
            guard persist() else { config.logPreferences = old; return }
            if old?.filter != preferences.filter { scheduleLogQuery() }
        } catch { self.error = error.localizedDescription }
    }
    private func scheduleLogQuery() {
        logQueryTask?.cancel(); logReadTask?.cancel(); logRefreshTask?.cancel(); logRefreshTask = nil
        logReadToken = UUID(); finishLogLoading(); logRefreshNeeded = false
        logMatchCount = 0; logMatchOrdinal = 0; logSearchHighlight = nil; logSearchContext = false
        logQueryBusy = selectedSession != nil && (!logFilter.isEmpty || !logSearchText.isEmpty)
        logQueryProgress = 0
        guard selectedSession != nil else { return }
        if !logSearchText.isEmpty { pauseLogFollowing() }
        logQueryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            self.logQueryTask = nil
            self.readLog(.latest, placement: .end, matchOrdinal: self.logSearchText.isEmpty ? nil : 1)
        }
    }
    func moveLogSearch(_ delta: Int) {
        guard !logQueryBusy, logMatchCount > 0 else { return }
        let ordinal: UInt64
        if delta < 0 { ordinal = logMatchOrdinal > 1 ? logMatchOrdinal - 1 : logMatchCount }
        else { ordinal = logMatchOrdinal < logMatchCount ? logMatchOrdinal + 1 : 1 }
        pauseLogFollowing()
        readLog(.first, placement: .anchor, matchOrdinal: ordinal)
    }
    func returnToFilteredLog() { showLog(.latest) }
    func reportLogPosition(_ value: Double, sessionID: UUID) {
        guard selectedSession == sessionID else { return }
        let fraction = LogScrollMetrics.clamp(value)
        let percent = fraction == 1 ? 100 : min(99, Int(fraction * 100))
        if logPositionPercent != percent { logPositionPercent = percent }
    }
    private func refreshTimestampMarks() {
        guard !logReading, let page = logPage, let url = selectedOutputFile else { return }
        let token = logReadToken
        Task {
            if let marks = try? await logLoader.timestamps(url, page: page), token == logReadToken,
               logPage?.startOffset == page.startOffset, logPage?.endOffset == page.endOffset, logPage?.text == page.text {
                logTimeMarks = marks
            }
        }
    }
    func pauseLogFollowing() {
        guard logFollowing else { return }
        logFollowing = false
        logRefreshTask?.cancel(); logRefreshTask = nil
    }
    func showLog(_ location: LogPageLocation) {
        guard logQueryTask == nil else { return }
        logSearchContext = false; logSearchHighlight = nil
        logRefreshTask?.cancel(); logRefreshTask = nil
        logFollowing = { if case .latest = location { return true }; return false }()
        let placement: LogScrollPlacement
        switch location {
        case .latest, .before: placement = .end
        case .around, .fraction: placement = .anchor
        default: placement = .start
        }
        readLog(location, placement: placement)
    }
    func shiftLogWindow(_ offset: UInt64) {
        guard !logNavigating, logQueryTask == nil else { return }
        pauseLogFollowing()
        readLog(.around(offset), placement: .preserveAnchor)
    }
    func seekLog(_ progress: Double) {
        logRefreshTask?.cancel()
        logReadTask?.cancel(); logReadToken = UUID(); finishLogLoading(); logRefreshNeeded = false
        let value = LogScrollMetrics.clamp(progress)
        pauseLogFollowing()
        // Dragging updates the knob immediately; only the last requested disk
        // position is read after a short debounce, keeping queued work bounded.
        logRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard let self else { return }
            self.logRefreshTask = nil
            if value == 0 { self.showLog(.first) }
            else if value == 1 { self.showLog(.latest) }
            else { self.showLog(.fraction(value)) }
        }
    }
    private func refreshLogAfterOutput() {
        guard selectedSession != nil else { return }
        if logQueryTask != nil { return }
        if !logFollowing && !logHasNewOutput { logHasNewOutput = true }
        if logReading { logRefreshNeeded = true; return }
        guard logRefreshTask == nil else { return }
        // Coalesce bursts; never re-read or re-layout a megabyte per pipe chunk.
        logRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            self.logRefreshTask = nil
            if self.logFollowing { self.readLog(.latest, placement: nil) }
            else { await self.refreshLogSize() }
        }
    }
    private func refreshLogSize() async {
        if !logFilter.isEmpty || !logSearchText.isEmpty {
            readLog(.latest, placement: nil, refreshOnly: true)
            return
        }
        guard let id = selectedSession, let store else { return }
        let token = logReadToken
        let url = store.directory(id).appendingPathComponent("output.raw")
        if let size = try? await logLoader.size(url), !Task.isCancelled, selectedSession == id, logReadToken == token {
            logTotalBytes = size
            if logSourceBytes != size { logSourceBytes = size }
        }
    }
    private func readLog(_ location: LogPageLocation, placement: LogScrollPlacement?, matchOrdinal: UInt64? = nil, refreshOnly: Bool = false) {
        guard let id = selectedSession, let store else { return }
        logReadTask?.cancel()
        let token = UUID(); logReadToken = token
        logLoadingIndicatorTask?.cancel()
        logReading = true
        if logNavigating != (placement != nil) { logNavigating = placement != nil }
        if logShowsLoading { logShowsLoading = false }
        logRefreshNeeded = false
        if logHasNewOutput { logHasNewOutput = false }
        // Ordinary live refresh is silent. Only a slower explicit navigation
        // needs a spinner; short reads must not flash the toolbar.
        if placement != nil {
            logLoadingIndicatorTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, !Task.isCancelled, self.logReadToken == token, self.logReading else { return }
                self.logShowsLoading = true
            }
        }
        let url = store.directory(id).appendingPathComponent("output.raw")
        let live = history.first(where: { $0.id == id })?.status == .running
        let loader = logLoader
        let progressModel = self
        let filter = logFilter, query = logSearchText
        let searchContext = matchOrdinal != nil || logSearchContext
        if placement != nil && (!filter.isEmpty || !query.isEmpty) { logQueryBusy = true }
        logReadTask = Task { [weak self] in
            do {
                let result = try await loader.read(url, at: location, isLive: live, filter: filter, query: query,
                                                   searchContext: searchContext, matchOrdinal: matchOrdinal, refreshOnly: refreshOnly,
                                                   showTimestamps: progressModel.logShowsTimestamps) { done, total in
                    Task { @MainActor in
                        let model = progressModel
                        guard model.logReadToken == token, model.logQueryBusy else { return }
                        model.logQueryProgress = total > 0 ? Double(done) / Double(total) : 1
                    }
                }
                guard let self, !Task.isCancelled, self.logReadToken == token, self.selectedSession == id else { return }
                self.finishLogLoading()
                if self.logQueryBusy { self.logQueryBusy = false }
                if self.logMatchCount != result.matchCount { self.logMatchCount = result.matchCount }
                if let ordinal = result.ordinal { self.logMatchOrdinal = ordinal }
                else if result.matchCount == 0 { self.logMatchOrdinal = 0 }
                // Scrolling away pauses live updates, including an in-flight read.
                self.logTotalBytes = result.totalBytes
                if self.logSourceBytes != result.sourceBytes { self.logSourceBytes = result.sourceBytes }
                if let page = result.page, placement != nil || self.logFollowing {
                    self.logPage = page
                    if self.logTimeMarks != result.timeMarks { self.logTimeMarks = result.timeMarks }
                    if self.logShowsTimestamps && result.timeMarks.isEmpty && !page.text.isEmpty { self.refreshTimestampMarks() }
                    if self.logSearchHighlight != result.highlight { self.logSearchHighlight = result.highlight }
                    let context = result.ordinal != nil ? result.ordinal! > 0 : searchContext
                    if self.logSearchContext != context { self.logSearchContext = context }
                    if let placement = result.highlight != nil ? LogScrollPlacement.anchor : placement {
                        self.logScrollPlacement = placement; self.logScrollRevision += 1
                    }
                } else if !self.logHasNewOutput { self.logHasNewOutput = true }
                if self.logRefreshNeeded { self.refreshLogAfterOutput() }
            } catch {
                guard let self, !Task.isCancelled, self.logReadToken == token, self.selectedSession == id else { return }
                self.finishLogLoading()
                self.logQueryBusy = false
                self.error = "读取日志失败：\(error.localizedDescription)"
            }
        }
    }
    private func finishLogLoading() {
        logLoadingIndicatorTask?.cancel(); logLoadingIndicatorTask = nil
        logReading = false
        if logNavigating { logNavigating = false }
        if logShowsLoading { logShowsLoading = false }
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
        CGFloat(model.config.projects.count) * 48 + CGFloat(model.applications.count) * 48 + CGFloat(model.projectRuns.values.reduce(0) { $0 + $1.liveDevToolsURLs.count }) * 18
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Runbar", systemImage: "terminal").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("打开主界面") { openWindow(id: "manager"); NSApp.activate(ignoringOtherApps: true) }
                    .accessibilityHint("打开项目、应用监听和日志管理窗口")
            }.padding(.horizontal, 10).padding(.vertical, 7)
            Divider()
            if model.config.projects.isEmpty && model.applications.isEmpty {
                Text("在主界面添加项目，或连接正在运行的 App。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.config.projects) { project in
                            ProjectMenuRow(model: model, project: project)
                            Divider().padding(.horizontal, 10)
                        }
                        ForEach(model.applications) { application in
                            HStack(spacing: 8) {
                                Button {
                                    model.selectApplication(application); model.showManagerWindow()
                                } label: {
                                    Label(application.name, systemImage: "app.connected.to.app.below.fill").lineLimit(1)
                                }.buttonStyle(.plain)
                                Spacer(minLength: 0)
                                Text(model.applicationConnections[application.id]?.message ?? "未连接").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if model.applicationConnections[application.id]?.active == true {
                                    Button("断开") { model.disconnectApplication(application.id) }
                                        .disabled(model.applicationConnections[application.id]?.phase == .disconnecting)
                                }
                            }.padding(.horizontal, 10).padding(.vertical, 8)
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
                Text(model.busy || model.attachmentCount > 0 ? "\(model.activeCount) 个项目运行 · \(model.attachmentCount) 个应用监听" : "就绪")
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

/// Serial, off-main disk parsing; cancelled selections never queue full-file work.
private actor LogPageLoader {
    private var tail = LogTailReader()
    private let processor = LogQueryProcessor()
    private var filterRevision: UInt64 = 0
    private let receiveTimes = LogReceiveTimeIndex()
    private let timestampReader = LogTimestampReader()
    private var targetTimes: URL?
    func clear() { processor.reset(); tail.reset(); receiveTimes.reset(); timestampReader.reset(); targetTimes = nil }
    func timestamps(_ rawURL: URL, page: LogFilePage) throws -> [LogTimeMark] {
        try receiveTimes.update(rawURL.deletingLastPathComponent().appendingPathComponent("events.jsonl"))
        if let targetTimes { return try timestampReader.projected(targetTimes, page: page) }
        return try timestampReader.raw(rawURL, page: page, times: receiveTimes)
    }
    func size(_ url: URL) throws -> UInt64 {
        try Task.checkCancellation()
        return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }
    func read(_ url: URL, at location: LogPageLocation, isLive: Bool, filter: LogFilter, query: String,
              searchContext: Bool, matchOrdinal: UInt64?, refreshOnly: Bool, showTimestamps: Bool,
              progress: @Sendable (UInt64, UInt64) -> Void) throws -> LogReadResult {
        try Task.checkCancellation()
        var target = url, location = location, count: UInt64 = 0, ordinal: UInt64?
        if showTimestamps || !filter.isEmpty || !query.isEmpty {
            try receiveTimes.update(url.deletingLastPathComponent().appendingPathComponent("events.jsonl"))
        }
        targetTimes = nil
        if !filter.isEmpty || !query.isEmpty {
            let snapshot = try processor.update(url, filter: filter, query: query, isLive: isLive, times: receiveTimes, progress: progress)
            count = snapshot.matchCount
            if snapshot.filterRevision != filterRevision { tail.reset(); filterRevision = snapshot.filterRevision }
            if let requested = matchOrdinal {
                ordinal = min(requested, count)
                if count > 0 { location = .around(try processor.matchOffset(at: ordinal!)) }
            }
            let fullContext = searchContext && (matchOrdinal == nil || count > 0)
            target = fullContext ? snapshot.fullURL : snapshot.filteredURL
            targetTimes = fullContext ? snapshot.fullTimesURL : snapshot.filteredTimesURL
        } else { processor.reset(); filterRevision = 0 }
        let total = try size(target)
        let sourceBytes = try size(url)
        if refreshOnly { return LogReadResult(page: nil, totalBytes: total, sourceBytes: sourceBytes, matchCount: count, ordinal: nil, highlight: nil, timeMarks: []) }
        let page: LogFilePage
        if case .latest = location { page = try tail.read(target, isLive: isLive) }
        else { tail.reset(); page = try LogFileReader.read(target, at: location, isLive: isLive) }
        try Task.checkCancellation()
        let highlight = (ordinal ?? 0) > 0 ? page.anchorUTF16Offset.map { NSRange(location: $0, length: query.utf16.count) } : nil
        let marks: [LogTimeMark]
        if !showTimestamps { marks = [] }
        else if let targetTimes { marks = try timestampReader.projected(targetTimes, page: page) }
        else { marks = try timestampReader.raw(url, page: page, times: receiveTimes) }
        return LogReadResult(page: page, totalBytes: total, sourceBytes: sourceBytes, matchCount: count, ordinal: ordinal, highlight: highlight, timeMarks: marks)
    }
}

private struct LogReadResult: Sendable {
    let page: LogFilePage?
    let totalBytes: UInt64
    let sourceBytes: UInt64
    let matchCount: UInt64
    let ordinal: UInt64?
    let highlight: NSRange?
    let timeMarks: [LogTimeMark]
}

enum LogScrollPlacement { case start, end, anchor, preserveAnchor }

private func phaseLabel(_ phase: ProjectRunPhase) -> String {
    switch phase { case .idle: return "未运行"; case .starting: return "正在启动…"; case .running: return "运行中"; case .stopping: return "正在停止…" }
}
