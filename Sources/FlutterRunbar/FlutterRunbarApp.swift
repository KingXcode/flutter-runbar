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
            Label(!model.busy ? "Flutter Runbar" : "Flutter 运行中", systemImage: !model.busy ? "terminal" : "play.circle.fill")
        }
        .menuBarExtraStyle(.window)
        Window("Flutter Runbar", id: "manager") {
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
        // A menu-bar agent may not instantiate its Window scene automatically.
        // Host the exact production ManagerView explicitly for screenshot builds.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Flutter Runbar · 演示数据（非真实运行）"
        window.contentView = NSHostingView(rootView: ManagerView(model: AppModel.shared))
        window.center()
        previewWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let menuWindow = NSWindow(contentRect: NSRect(x: 40, y: 60, width: 640, height: 450),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
        menuWindow.title = "菜单栏项目列表 · 演示数据（非真实运行）"
        // Same MenuContent used by MenuBarExtra; screenshot host only, not a claim
        // that this titlebar or window chrome belongs to the actual popup.
        menuWindow.contentView = NSHostingView(rootView: MenuContent(model: AppModel.shared))
        previewMenuWindow = menuWindow
        menuWindow.makeKeyAndOrderFront(nil)
    }
    #endif
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if SCREENSHOT_PREVIEW
        return .terminateNow
        #else
        let model = AppModel.shared
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
    @Published var selectedSession: UUID?
    @Published var logText = ""
    @Published var error: String?
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
        panel.message = "选择 Flutter 项目目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let existing = config.projects.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path == path }) { select(existing); return }
        let project = Project(path: path); config.projects.append(project); select(project); persist()
    }
    func select(_ project: Project) {
        selectedProject = project.id
        selectedSession = state(for: project.id).session?.id ?? history.first(where: { $0.projectPath == project.path })?.id
        loadLog()
    }
    func choosePreset(_ presetID: UUID?, for projectID: UUID) {
        guard !state(for: projectID).isBusy,
              let index = config.projects.firstIndex(where: { $0.id == projectID }),
              config.projects[index].presets.contains(where: { $0.id == presetID }) else { return }
        config.projects[index].selectedPresetID = presetID; persist()
    }
    func savePreset(name: String, command: String, id: UUID?) {
        guard let index = config.projects.firstIndex(where: { $0.id == selectedProject }),
              !state(for: config.projects[index].id).isBusy else { return }
        if let id, let p = config.projects[index].presets.firstIndex(where: { $0.id == id }) {
            config.projects[index].presets[p].name = name; config.projects[index].presets[p].command = command
        } else {
            let preset = CommandPreset(name: name, command: command)
            config.projects[index].presets.append(preset); config.projects[index].selectedPresetID = preset.id
        }
        persist()
    }
    func run(projectID: UUID) {
        #if SCREENSHOT_PREVIEW
        error = "演示模式不会执行命令。"
        return
        #else
        guard !quitWhenFinished, !state(for: projectID).isBusy,
              let project = config.projects.first(where: { $0.id == projectID }),
              let preset = project.selectedPreset, let coordinator else { return }
        guard persist() else { return }
        coordinator.start(project: project, preset: preset, extraPath: config.extraPath)
        #endif
    }
    func run() { if let id = selectedProject { run(projectID: id) } }
    func stop(projectID: UUID) {
        #if SCREENSHOT_PREVIEW
        projectRuns[projectID] = ProjectRunState()
        #else
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
            replace(value)
            if selectedSession == value.id { loadLog() }
            else if selectedProject == id && selectedSession == nil { selectedSession = value.id; loadLog() }
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

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Flutter Runbar", systemImage: "terminal").font(.headline)
                Spacer()
                Button("打开主界面") { openWindow(id: "manager"); NSApp.activate(ignoringOtherApps: true) }
                    .accessibilityHint("打开项目、命令和运行日志管理窗口")
            }.padding(14)
            Divider()
            if model.config.projects.isEmpty {
                VStack(spacing: 8) {
                    Text("还没有项目").font(.headline)
                    Text("在主界面添加 Flutter 项目后，会在这里显示。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.config.projects) { project in
                            ProjectMenuRow(model: model, project: project)
                            Divider().padding(.horizontal, 14)
                        }
                    }
                }.frame(height: min(440, CGFloat(model.config.projects.count) * 118))
            }
            if let error = model.error {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                    Spacer()
                    Button("关闭提示") { model.error = nil }.font(.caption)
                }.padding(12)
                Divider()
            }
            HStack {
                Text(model.busy ? "\(model.activeCount) 个项目运行中" : "就绪")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }.padding(12)
        }.frame(width: 640)
    }
}

private struct ProjectMenuRow: View {
    @ObservedObject var model: AppModel
    let project: Project
    private var state: ProjectRunState { model.state(for: project.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name).font(.headline).lineLimit(1).truncationMode(.middle)
                        .help(project.path).accessibilityLabel("项目 \(project.name)")
                    Text(phaseLabel(state.phase)).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Picker("命令", selection: Binding(
                    get: { project.selectedPreset?.id },
                    set: { model.choosePreset($0, for: project.id) }
                )) {
                    if project.presets.isEmpty { Text("未配置命令").tag(Optional<UUID>.none) }
                    ForEach(project.presets) { preset in Text(preset.name).tag(Optional(preset.id)) }
                }.labelsHidden().frame(width: 200).disabled(state.isBusy || model.quitWhenFinished)
                    .accessibilityLabel("\(project.name)的命令")
                    .help(state.command ?? project.selectedPreset?.command ?? "请在主界面添加命令")
                Button("运行") { model.run(projectID: project.id) }
                    .disabled(state.isBusy || project.selectedPreset == nil || model.quitWhenFinished)
                    .accessibilityLabel("运行\(project.name)")
                Button("停止") { model.stop(projectID: project.id) }
                    .disabled(!state.isBusy || state.phase == .stopping)
                    .accessibilityLabel("停止\(project.name)")
            }.controlSize(.small)
            ForEach(state.liveDevToolsURLs, id: \.self) { value in
                Button { model.openLiveURL(value, projectID: project.id) } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "link")
                        Text(value).font(.system(.caption, design: .monospaced))
                            .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.leading)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).foregroundStyle(.blue).help(value)
                    .accessibilityLabel("打开\(project.name)的 DevTools")
                    .accessibilityValue(value)
            }
            if state.phase == .running && state.liveDevToolsURLs.isEmpty {
                Text("等待 DevTools 地址…").font(.caption).foregroundStyle(.secondary)
            }
            if let message = state.error {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).help(message)
            }
        }.padding(14)
    }
}

private func phaseLabel(_ phase: ProjectRunPhase) -> String {
    switch phase { case .idle: return "未运行"; case .starting: return "正在启动…"; case .running: return "运行中"; case .stopping: return "正在停止…" }
}

struct ManagerView: View {
    @ObservedObject var model: AppModel
    @State private var editing = false
    @State private var editingID: UUID?
    @State private var presetName = ""
    @State private var command = ""
    @State private var pathSettings = false
    var body: some View {
        NavigationSplitView {
            List {
                Section("项目") {
                    ForEach(model.config.projects) { project in
                        Button { model.select(project) } label: {
                            Label(project.name, systemImage: model.selectedProject == project.id ? "folder.fill" : "folder")
                        }.buttonStyle(.plain)
                    }
                    Button("添加项目…", systemImage: "folder.badge.plus") { model.chooseProject() }
                }
                Section("运行记录") {
                    ForEach(model.history) { session in
                        Button { model.selectedSession = session.id; model.selectedProject = model.config.projects.first(where: { $0.path == session.projectPath })?.id; model.loadLog() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: session.projectPath).lastPathComponent).font(.headline)
                                Text(session.startedAt, format: .dateTime.month().day().hour().minute().second()).font(.caption)
                                Text(statusLabel(session.status)).font(.caption).foregroundStyle(session.status == .failed ? .red : .secondary)
                            }.padding(.vertical, 3)
                        }.buttonStyle(.plain)
                    }
                }
            }.navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(model.project?.name ?? "先添加 Flutter 项目").font(.title2.bold())
                        Text(model.project?.path ?? "命令与日志仅保存在本机").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("PATH 设置", systemImage: "gearshape") { pathSettings = true }
                }
                if let project = model.project {
                    HStack {
                        Picker("命令", selection: $model.selectedPreset) {
                            ForEach(project.presets) { preset in Text(preset.name).tag(Optional(preset.id)) }
                        }.disabled(model.selectedState.isBusy)
                        Button("添加") { editingID = nil; presetName = "新命令"; command = "fvm flutter run -d macos"; editing = true }.disabled(model.selectedState.isBusy)
                        Button("编辑") { guard let preset = model.preset else { return }; editingID = preset.id; presetName = preset.name; command = preset.command; editing = true }.disabled(model.preset == nil || model.selectedState.isBusy)
                        Button(model.selectedState.isBusy ? (model.selectedState.phase == .stopping ? "正在停止…" : "停止") : "运行", systemImage: model.selectedState.isBusy ? "stop.fill" : "play.fill") { model.selectedState.isBusy ? model.stop() : model.run() }
                            .buttonStyle(.borderedProminent).disabled(model.selectedState.phase == .stopping || (!model.selectedState.isBusy && model.preset == nil) || model.quitWhenFinished)
                    }
                    Text(model.preset?.command ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                Divider()
                if let session = model.session {
                    HStack {
                        Text("日志：\(URL(fileURLWithPath: session.projectPath).lastPathComponent)").font(.caption).lineLimit(1)
                        Text(statusLabel(session.status)).font(.headline)
                        Text("开始 \(session.startedAt.formatted(date: .omitted, time: .standard))").font(.caption)
                        if let end = session.endedAt { Text("结束 \(end.formatted(date: .omitted, time: .standard))").font(.caption) }
                        if let code = session.exitCode { Text("退出码 \(code)").font(.caption) }
                        Spacer(); Button("本地日志", systemImage: "folder") { model.showFiles() }
                    }
                    Text(session.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    if let message = session.error { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                    ForEach(session.devToolsURLs, id: \.self) { url in
                        HStack {
                            Text("DevTools").font(.caption.bold())
                            Text(url).font(.caption).lineLimit(1).textSelection(.enabled)
                            Button("打开") { if let id = model.liveProjectID(for: session.id) { model.openLiveURL(url, projectID: id) } }.disabled(model.liveProjectID(for: session.id) == nil)
                            Button("复制") { model.copy(url) }
                        }
                    }
                }
                LogView(text: model.logText).frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("stdout / stderr 按接收顺序合并；完整原始字节与分块时间索引保存在本地。不会上传日志，也不会自动打开链接。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            #if SCREENSHOT_PREVIEW
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.frame.width > 800 {
                        window.title = "Flutter Runbar · 演示数据（非真实运行）"
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }
            #endif
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 16) {
                Text(editingID == nil ? "添加命令" : "编辑命令").font(.title2)
                TextField("名称", text: $presetName)
                TextEditor(text: $command).font(.system(.body, design: .monospaced)).frame(height: 120)
                Text("命令由登录 zsh 执行，支持参数、引号与管道。只保存你信任的命令，它拥有你当前用户的权限。运行输出永远不会作为命令执行。不要使用后台化或守护进程命令。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("取消") { editing = false }; Button("保存") { model.savePreset(name: presetName, command: command, id: editingID); editing = false }.disabled(presetName.isEmpty || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(24).frame(width: 520)
        }
        .sheet(isPresented: $pathSettings) {
            VStack(alignment: .leading, spacing: 16) {
                Text("命令环境").font(.title2)
                Text("额外 PATH（冒号分隔；使用完整路径，不要使用 ~）")
                TextField("PATH", text: $model.config.extraPath)
                Text("这些目录会添加到登录 zsh 的 PATH 前面。默认包含 pub-cache 和 Homebrew；可添加你的 FVM 可执行文件目录。不安装 SDK、不修改 shell 配置。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("保存") { model.persist(); pathSettings = false }
            }.padding(24).frame(width: 560)
        }
        .alert("需要注意", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

private func statusLabel(_ status: RunStatus) -> String {
    switch status { case .running: return "运行中"; case .succeeded: return "已完成"; case .failed: return "失败"; case .stopped: return "已停止"; case .interrupted: return "异常中断" }
}

/// Native selectable log view avoids creating a SwiftUI view per output line.
struct LogView: NSViewRepresentable {
    var text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.backgroundColor = .textBackgroundColor; view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        scroll.documentView = view; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let atBottom = scroll.documentVisibleRect.maxY >= view.bounds.maxY - 40
        view.string = text
        if atBottom { view.scrollToEndOfDocument(nil) }
    }
}
