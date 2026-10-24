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
            Label(model.running == nil ? "Flutter Runbar" : "Flutter 运行中", systemImage: model.running == nil ? "terminal" : "play.circle.fill")
        }
        Window("Flutter Runbar", id: "manager") {
            ManagerView(model: model)
                .frame(minWidth: 880, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 760)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "命令仍在运行"
        alert.informativeText = "退出将先停止本次命令，并等待日志保存完成。"
        alert.addButton(withTitle: "停止并退出"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        guard model.busy else { return .terminateNow }
        model.quitWhenFinished = true; model.stop()
        return .terminateLater
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var config = Configuration()
    @Published var history: [RunSession] = []
    @Published var running: RunSession?
    @Published var selectedProject: UUID?
    @Published var selectedPreset: UUID?
    @Published var selectedSession: UUID?
    @Published var logText = ""
    @Published var error: String?
    @Published var busy = false
    @Published var stopping = false
    var quitWhenFinished = false
    private var store: SessionStore?
    private var runner: ProcessRunner?
    init() {
        do {
            let store = try SessionStore()
            config = try store.loadConfiguration(); try store.recoverInterrupted(); history = try store.sessions()
            self.store = store
            selectedProject = config.projects.first?.id; selectedPreset = config.projects.first?.presets.first?.id
            runner = ProcessRunner(store: store) { [weak self] event in self?.handle(event) }
            if !store.warnings.isEmpty { error = store.warnings.joined(separator: "\n") }
            #if SCREENSHOT_PREVIEW
            // Only the explicit screenshot build selects fixture history automatically.
            // No command is launched by this path.
            selectedSession = history.first?.id
            loadLog()
            #endif
        } catch { self.error = "初始化失败，请检查本地数据权限：\(error.localizedDescription)" }
    }
    var project: Project? { config.projects.first { $0.id == selectedProject } }
    var preset: CommandPreset? { project?.presets.first { $0.id == selectedPreset } }
    var session: RunSession? { history.first { $0.id == selectedSession } }
    @discardableResult
    func persist() -> Bool {
        do { guard let store else { throw RunbarError.message("本地存储不可用") }; try store.saveConfiguration(config); return true }
        catch { self.error = "设置保存失败：\(error.localizedDescription)"; return false }
    }
    func chooseProject() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "选择 Flutter 项目目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let existing = config.projects.first(where: { $0.path == url.path }) { select(existing); return }
        let project = Project(path: url.path); config.projects.append(project); select(project); persist()
    }
    func select(_ project: Project) { selectedProject = project.id; selectedPreset = project.presets.first?.id }
    func savePreset(name: String, command: String, id: UUID?) {
        guard let index = config.projects.firstIndex(where: { $0.id == selectedProject }) else { return }
        if let id, let p = config.projects[index].presets.firstIndex(where: { $0.id == id }) {
            config.projects[index].presets[p].name = name; config.projects[index].presets[p].command = command
        } else {
            let preset = CommandPreset(name: name, command: command); config.projects[index].presets.append(preset); selectedPreset = preset.id
        }
        persist()
    }
    func run() {
        guard !busy, let project, let preset, let runner else { return }
        guard persist() else { return }; busy = true; stopping = false; logText = ""; runner.run(project: project, preset: preset, extraPath: config.extraPath)
    }
    func stop() { guard busy else { return }; stopping = true; runner?.stop() }
    func handle(_ event: ProcessRunner.Event) {
        switch event {
        case .started(let value): running = value; history.insert(value, at: 0); selectedSession = value.id
        case .output(let text):
            if selectedSession == running?.id {
                logText += text
                if logText.utf8.count > 200_000 { logText = "[实时视图已截断；完整输出仍保存在本地]\n" + String(decoding: logText.utf8.suffix(100_000), as: UTF8.self) }
            }
        case .updated(let value): running = value; replace(value)
        case .finished(let value):
            replace(value); selectedSession = value.id; running = nil; busy = false; stopping = false
            if let problem = value.error { error = problem }
            loadLog()
            if quitWhenFinished { NSApp.reply(toApplicationShouldTerminate: true) }
        case .failure(let message): error = message
        case .rejected(let message):
            error = message; if running == nil { busy = false; stopping = false; if quitWhenFinished { NSApp.reply(toApplicationShouldTerminate: true) } }
        }
    }
    private func replace(_ value: RunSession) {
        if let i = history.firstIndex(where: { $0.id == value.id }) { history[i] = value } else { history.insert(value, at: 0) }
    }
    func loadLog() {
        guard let id = selectedSession, let store else { logText = ""; return }
        do { logText = try store.tail(id) } catch { self.error = "读取日志失败：\(error.localizedDescription)" }
    }
    func showFiles() { guard let id = selectedSession, let store else { return }; NSWorkspace.shared.open(store.directory(id)) }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func open(_ value: String) {
        guard let url = URL(string: value), let host = url.host, ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host), ["http", "https"].contains(url.scheme ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.busy ? "Flutter 正在运行" : "Flutter Runbar")
        if let project = model.project { Text(project.name) }
        Button("打开管理窗口") { openWindow(id: "manager"); NSApp.activate(ignoringOtherApps: true) }
        if model.busy { Button(model.stopping ? "正在停止…" : "停止运行") { model.stop() }.disabled(model.stopping) }
        else { Button("运行所选命令") { model.run() }.disabled(model.preset == nil) }
        Divider()
        Button("退出") { NSApp.terminate(nil) }
    }
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
                        Button { model.selectedSession = session.id; model.loadLog() } label: {
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
                        }
                        Button("添加") { editingID = nil; presetName = "新命令"; command = "fvm flutter run -d macos"; editing = true }
                        Button("编辑") { guard let preset = model.preset else { return }; editingID = preset.id; presetName = preset.name; command = preset.command; editing = true }.disabled(model.preset == nil)
                        Button(model.busy ? (model.stopping ? "正在停止…" : "停止") : "运行", systemImage: model.busy ? "stop.fill" : "play.fill") { model.busy ? model.stop() : model.run() }
                            .buttonStyle(.borderedProminent).disabled(model.stopping || (!model.busy && model.preset == nil))
                    }
                    Text(model.preset?.command ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                Divider()
                if let session = model.session {
                    HStack {
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
                            Button("打开") { model.open(url) }.disabled(session.status != .running)
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
                    for window in NSApp.windows where window.frame.width > 600 {
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
