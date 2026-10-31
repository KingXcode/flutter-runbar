import SwiftUI
import AppKit
import RunbarCore

struct ManagerView: View {
    @ObservedObject var model: AppModel
    @State private var commandEditor: CommandEditorRequest?
    @State private var showingSettings = false
    @State private var showingVSCodeSetup = false
    @State private var vsCodeConnection: VSCodeConnectionRequest?
    @State private var showingApplicationPicker = false
    @State private var metadataHeight: CGFloat = 0
    @State private var showingLogDetails = false
    @State private var collapsedHistoryProjects = Set<String>()
    @State private var selectingHistory = false
    @State private var pendingSessionDeletion = Set<UUID>()
    @State private var showingSessionDeletion = false
    @State private var pendingProjectRemoval: Project?
    @State private var expandedLog = false
    @State private var showingNetwork = false
    @State private var projectGitHeads: [String: ProjectGitHead] = [:]
    @AppStorage("logWrapsLines") private var logWrapsLines = false
    private var gitProjectPaths: [String] { model.config.projects.map(\.path).sorted() }
    private var projectHistory: [RunSession] {
        model.visibleHistory
    }
    private var historyGroups: [ProjectHistoryGroup] {
        Dictionary(grouping: projectHistory, by: \.projectPath)
            .map { path, sessions in
                ProjectHistoryGroup(path: path, sessions: sessions.sorted { $0.startedAt > $1.startedAt })
            }
            .sorted {
                let left = $0.sessions.first?.startedAt ?? .distantPast
                let right = $1.sessions.first?.startedAt ?? .distantPast
                return left == right ? $0.path < $1.path : left > right
            }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List {
                    Section {
                        ForEach(model.config.projects) { project in
                            Button { model.select(project) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: model.selectedProject == project.id ? "folder.fill" : "folder")
                                        .foregroundStyle(model.selectedProject == project.id ? Color.accentColor : .secondary)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 5) {
                                            Text(project.name).font(.system(size: 12, weight: .semibold))
                                                .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                                            if let head = projectGitHeads[project.path] { gitBranchBadge(head, compact: true) }
                                        }
                                        Text(project.path).font(.system(size: 10)).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                            .accessibilityLabel("项目目录 \(project.path)")
                                    }
                                    Spacer(minLength: 0)
                                    if model.state(for: project.id).isBusy {
                                        Image(systemName: "play.circle.fill").foregroundStyle(.green)
                                            .help("该项目正在运行").accessibilityLabel("运行中")
                                    }
                                }.padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(project.path)
                                .listRowBackground(model.selectedProject == project.id ? Color.accentColor.opacity(0.12) : Color.clear)
                                .accessibilityAddTraits(model.selectedProject == project.id ? .isSelected : [])
                                .contextMenu {
                                    Button("移除项目…", role: .destructive) { pendingProjectRemoval = project }
                                        .disabled(model.state(for: project.id).isBusy)
                                }
                        }
                    } header: {
                        HStack { Text("项目"); Spacer(); Text("\(model.config.projects.count)").monospacedDigit() }
                    }
                    Section {
                        ForEach(model.applications) { application in
                            Button { model.selectApplication(application) } label: {
                                HStack(spacing: 8) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: application.bundlePath)).resizable().frame(width: 22, height: 22)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(application.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).help(application.bundlePath)
                                        Text(model.applicationConnections[application.id]?.message ?? "未连接 · 本地记录")
                                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .listRowBackground(model.selectedApplication == application.id ? Color.accentColor.opacity(0.12) : Color.clear)
                                .accessibilityAddTraits(model.selectedApplication == application.id ? .isSelected : [])
                                .contextMenu {
                                    Button("从列表移除") { model.removeApplication(application.id) }
                                        .disabled(model.applicationConnections[application.id]?.active == true)
                                }
                        }
                    } header: {
                        HStack { Text("应用监听"); Spacer(); Text("\(model.applications.count)").monospacedDigit() }
                    }
                }.listStyle(.sidebar)
                Divider()
                HStack {
                    Button("添加项目", systemImage: "folder.badge.plus") { model.chooseProject() }
                    Button("连接 App", systemImage: "link") { showingApplicationPicker = true }
                }.padding(12)
            }.navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if model.application != nil { applicationHeader } else { projectHeader }
                Divider()
                HSplitView {
                    if !expandedLog { historyPane.frame(minWidth: 180, idealWidth: 220, maxWidth: 300) }
                    logPane.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            }.background(Color(nsColor: .windowBackgroundColor))
            #if SCREENSHOT_PREVIEW
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.frame.width > 800 {
                        window.title = "Runbar · 演示数据（非真实运行）"
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }
            #endif
        }
        .task(id: gitProjectPaths) {
            let paths = gitProjectPaths
            let wanted = Set(paths)
            projectGitHeads = projectGitHeads.filter { wanted.contains($0.key) }
            guard !paths.isEmpty else { return }
            while !Task.isCancelled {
                // A hidden/minimized manager needs no disk polling. Check again
                // on the next tick when a normal app window becomes visible.
                if !NSApp.isHidden, NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized && $0.level == .normal }) {
                    let heads = await ProjectGitReader.snapshot(paths: paths)
                    guard !Task.isCancelled else { return }
                    if projectGitHeads != heads { projectGitHeads = heads }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .sheet(isPresented: $showingApplicationPicker) {
            ApplicationPickerView(model: model, preferredApplication: model.application)
        }
        .sheet(item: $commandEditor) { request in
            CommandEditorView(model: model, request: request)
        }
        .sheet(item: $vsCodeConnection) { request in
            VSCodeConnectionView(model: model, request: request)
        }
        .sheet(isPresented: $showingSettings) {
            VStack(alignment: .leading, spacing: 16) {
                Text("设置").font(.title2)
                UpdateSettingsSection(updater: model.updates) { model.showUpdateWindow() }
                Divider()
                Text("应用显示").font(.headline)
                Toggle("在 Dock 中显示", isOn: Binding(get: { model.showInDock }, set: { model.setDockVisibility($0) }))
                Text("切换立即生效并自动保存。关闭后仍可从菜单栏打开 Runbar。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("全局快捷键").font(.headline)
                HStack {
                    Toggle("呼出 Runbar 与运行中的应用", isOn: Binding(get: { model.globalShortcut.enabled }, set: model.setGlobalShortcutEnabled))
                    Spacer()
                    GlobalShortcutRecorder(shortcut: model.globalShortcut.shortcut, onChange: model.setGlobalShortcut, onRecording: model.setShortcutRecording)
                        .frame(width: 190, height: 26)
                }
                Text("默认 F3；点击右侧录制新快捷键，Esc 取消。部分键盘需配合 Fn。仅前置本次运行的 macOS 应用，终端任务没有独立窗口。")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = model.globalShortcutError { Text(message).font(.caption).foregroundStyle(.red) }
                Divider()
                HStack {
                    Text("VS Code").font(.headline)
                    Spacer()
                    Button("安装 / 管理扩展…") { showingVSCodeSetup = true }
                }
                Text("Runbar 附带 Bridge 扩展，用于自动打开项目并附加 Dart 断点调试。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("命令环境").font(.headline)
                Text("额外 PATH（冒号分隔；支持完整路径和 ~/）")
                TextField("PATH", text: $model.config.extraPath)
                Text("自定义目录优先，并自动补充 ~/.pub-cache/bin、~/fvm/bin 和 Homebrew 路径；可添加其他 FVM 安装目录。不安装 SDK、不修改 shell 配置。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("保存") { if model.persist() { showingSettings = false } }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 560)
                .sheet(isPresented: $showingVSCodeSetup) { VSCodeConnectionView(model: model) }
        }
        .alert("需要注意", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("删除 \(pendingSessionDeletion.count) 条记录？", isPresented: $showingSessionDeletion) {
            Button("取消", role: .cancel) { pendingSessionDeletion = [] }
            Button("移到废纸篓", role: .destructive) {
                let ids = pendingSessionDeletion; pendingSessionDeletion = []
                model.deleteSessions(ids)
            }
        } message: { Text("对应日志也会一起移到废纸篓，可从废纸篓恢复。正在进行的记录不能删除。") }
        .confirmationDialog("移除项目“\(pendingProjectRemoval?.name ?? "")”？", isPresented: Binding(
            get: { pendingProjectRemoval != nil }, set: { if !$0 { pendingProjectRemoval = nil } }
        ), titleVisibility: .visible) {
            if let project = pendingProjectRemoval {
                Button("移除项目", role: .destructive) { model.removeProject(project.id); pendingProjectRemoval = nil }
            }
            Button("取消", role: .cancel) { pendingProjectRemoval = nil }
        } message: { Text("仅移除应用内的项目配置和命令，不删除磁盘上的项目文件或运行记录。") }
    }

    private var applicationHeader: some View {
        HStack(spacing: 10) {
            if let application = model.application {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.bundlePath)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(application.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    let state = model.applicationConnections[application.id]
                    Text(state?.active == true ? "应用监听 · macOS · PID \(state?.candidate?.processID ?? 0)" : "应用监听 · 本地历史记录")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                let state = model.applicationConnections[application.id]
                Text(state?.flutterControlResult ?? state?.message ?? "未连接").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(state?.message ?? "未连接")
                if state?.active == true {
                    if let sessionID = state?.sessionID {
                        Button("VS Code", systemImage: "curlybraces") {
                            vsCodeConnection = VSCodeConnectionRequest(applicationID: application.id, sessionID: sessionID)
                        }.disabled(state?.phase != .listening || model.quitWhenFinished)
                            .help("选择此 App 对应的 Flutter 源码目录，在 VS Code 中附加 Dart 断点调试；仅支持 Debug 包")
                    }
                    applicationFlutterButtons(applicationID: application.id, state: state)
                    Button("DevTools", systemImage: "arrow.up.right.square") { model.openApplicationDevTools(application.id) }
                        .disabled(state?.phase != .listening)
                    Button(state?.phase == .disconnecting ? "正在断开…" : "断开连接") { model.disconnectApplication(application.id) }
                        .disabled(state?.phase == .disconnecting).help("只结束监听，目标 App 继续运行")
                } else {
                    Button("连接", systemImage: "link") { showingApplicationPicker = true }.buttonStyle(.borderedProminent)
                }
            }
        }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 12)
    }

    private func applicationFlutterButtons(applicationID: UUID, state: ApplicationConnectionState?) -> some View {
        let controls = state?.flutterControls ?? FlutterRunControls()
        return HStack(spacing: 5) {
            Button(controls.workingAction == .hotReload ? "重载中…" : "热重载", systemImage: "bolt.fill") {
                model.sendApplicationFlutterAction(.hotReload, applicationID: applicationID)
            }.disabled(state?.phase != .listening || !controls.canSend(.hotReload) || model.quitWhenFinished)
                .help(controls.actions.contains(.hotReload) ? "编译并加载 Dart 修改，保留当前状态；编译详情见原调试工具" : state?.flutterControlHint ?? "等待连接")
                .accessibilityLabel("关联 App 热重载")
            Button(controls.workingAction == .hotRestart ? "重启中…" : "热重启", systemImage: "arrow.counterclockwise") {
                model.sendApplicationFlutterAction(.hotRestart, applicationID: applicationID)
            }.disabled(state?.phase != .listening || !controls.canSend(.hotRestart) || model.quitWhenFinished)
                .help(controls.actions.contains(.hotRestart) ? "从 Dart 入口重新运行，会重置当前状态；编译详情见原调试工具" : state?.flutterControlHint ?? "等待连接")
                .accessibilityLabel("关联 App 热重启")
        }.fixedSize()
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(model.project?.name ?? "选择一个项目")
                            .font(.system(size: 16, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            .help(model.project?.name ?? "").layoutPriority(1)
                        if let path = model.project?.path, let head = projectGitHeads[path] { gitBranchBadge(head) }
                    }
                    Text(model.project?.path ?? "从左侧添加项目，管理命令与本地运行日志。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(model.project?.path ?? "")
                        .accessibilityLabel(model.project.map { "项目目录 \($0.path)" } ?? "尚未选择项目")
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let project = model.project {
                    if project.kind == .flutter, let sessionID = model.selectedState.session?.id,
                       model.selectedState.phase == .running {
                        Button("VS Code", systemImage: "curlybraces") {
                            vsCodeConnection = VSCodeConnectionRequest(projectID: project.id, sessionID: sessionID)
                        }.controlSize(.small)
                            .disabled((try? model.vsCodeTarget(projectID: project.id, sessionID: sessionID)) == nil)
                            .help("打开此项目并附加 Dart 断点调试；仅支持就绪的 Debug 运行，首次使用会提示安装扩展")
                    }
                    if model.selectedState.phase == .running, let controls = model.selectedState.flutterControls,
                       let sessionID = model.selectedState.session?.id {
                        flutterRunButtons(projectID: project.id, sessionID: sessionID, controls: controls)
                    }
                    Menu {
                        ForEach(ProjectKind.allCases) { kind in
                            Button(kind.displayName) { model.setProjectKind(kind, for: project.id) }
                        }
                        Divider()
                        Button("重新识别项目类型") {
                            model.setProjectKind(ProjectDetector.detect(at: project.path), for: project.id)
                        }
                    } label: { Text(project.kind.displayName).font(.caption) }
                        .fixedSize().disabled(model.selectedState.isBusy)
                        .help("项目类型只影响可选模板，不改变已保存命令")
                    PhaseBadge(phase: model.selectedState.phase)
                }
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .help("Dock 显示与命令环境设置").accessibilityLabel("设置")
            }
            if let project = model.project {
                HStack(spacing: 6) {
                    Text("命令").font(.caption).foregroundStyle(.secondary).fixedSize()
                    Picker("运行配置", selection: $model.selectedPreset) {
                        if project.presets.isEmpty { Text("选择命令").tag(Optional<UUID>.none) }
                        ForEach(project.availablePresets) { preset in Text(preset.name).tag(Optional(preset.id)) }
                    }.labelsHidden().frame(minWidth: 110, maxWidth: 160).disabled(model.selectedState.isBusy)
                    Button { commandEditor = CommandEditorRequest(project: project) } label: { Image(systemName: "plus") }
                        .disabled(model.selectedState.isBusy).help("添加常用模板或自定义命令").accessibilityLabel("添加命令或常用模板")
                    Button {
                        guard let preset = model.preset else { return }
                        commandEditor = CommandEditorRequest(project: project, preset: preset)
                    } label: { Image(systemName: "pencil") }
                        .disabled(model.preset == nil || model.preset?.builtInAction != nil || model.selectedState.isBusy).help("编辑所选命令").accessibilityLabel("编辑命令")
                    Text(model.preset?.displayCommand ?? "尚未配置命令")
                        .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled).frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
                        .help(model.preset?.displayCommand ?? "")
                        .accessibilityLabel("当前命令 \(model.preset?.displayCommand ?? "尚未配置命令")")
                    Button(model.selectedState.isBusy ? (model.selectedState.phase == .stopping ? "正在停止…" : "停止当前运行") : "运行", systemImage: model.selectedState.isBusy ? "stop.fill" : "play.fill") {
                        model.selectedState.isBusy ? model.stop() : model.run()
                    }.buttonStyle(.borderedProminent).fixedSize()
                        .tint(model.selectedState.isBusy ? .orange : .accentColor)
                        .disabled(model.nativeActionProjectID != nil || model.selectedState.phase == .stopping || (!model.selectedState.isBusy && model.preset == nil) || model.quitWhenFinished)
                }.controlSize(.small)
            }
        }.padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func gitBranchBadge(_ head: ProjectGitHead, compact: Bool = false) -> some View {
        Label(head.title, systemImage: "arrow.triangle.branch")
            .font(.system(size: compact ? 9 : 11))
            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            .help(head.help).accessibilityLabel(head.help)
            .layoutPriority(-1)
    }

    private func flutterRunButtons(projectID: UUID, sessionID: UUID, controls: FlutterRunControls) -> some View {
        HStack(spacing: 5) {
            Button(controls.workingAction == .hotReload ? "重载中…" : "热重载", systemImage: "bolt.fill") {
                model.sendFlutterAction(.hotReload, projectID: projectID, sessionID: sessionID)
            }.disabled(!controls.canSend(.hotReload) || model.quitWhenFinished)
                .help(controls.isReady ? "r · 加载 Dart 修改并保留当前状态；仅支持 Debug，结果见日志" : "等待 Flutter 输出交互命令后启用")
                .accessibilityLabel("Flutter 热重载")
            Button(controls.workingAction == .hotRestart ? "重启中…" : "热重启", systemImage: "arrow.counterclockwise") {
                model.sendFlutterAction(.hotRestart, projectID: projectID, sessionID: sessionID)
            }.disabled(!controls.canSend(.hotRestart) || model.quitWhenFinished)
                .help(controls.isReady ? "R · 从 main 重新运行 Dart 代码，会重置当前状态；仅支持 Debug" : "等待 Flutter 输出交互命令后启用")
                .accessibilityLabel("Flutter 热重启")
            Menu {
                Button(controls.isDetaching ? "正在分离…" : "分离运行，保留 App", systemImage: "arrow.up.right.square") {
                    model.sendFlutterAction(.detach, projectID: projectID, sessionID: sessionID)
                }.disabled(!controls.canSend(.detach))
                    .help("d · 结束 flutter run / attach 命令，App 继续运行；当前运行的日志和网络采集结束")
                Button("显示 Flutter 运行帮助", systemImage: "questionmark.circle") {
                    model.sendFlutterAction(.help, projectID: projectID, sessionID: sessionID)
                }.disabled(!controls.canSend(.help))
                    .help("h · 在输出日志中列出当前 Flutter 版本支持的全部交互命令")
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.quitWhenFinished)
                .help("Flutter 运行操作").accessibilityLabel("更多 Flutter 操作")
        }.controlSize(.small).fixedSize()
    }

    private var historyPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label(model.application == nil ? "运行记录" : "监听记录", systemImage: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text("\(projectHistory.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button(selectingHistory ? "完成" : "多选") {
                    selectingHistory.toggle()
                    if !selectingHistory { model.selectedSession = model.selectedSession }
                }.buttonStyle(.borderless).font(.caption)
            }.padding(.horizontal, 12).padding(.vertical, 8)
            if selectingHistory || model.historySelection.ids.count > 1 {
                HStack {
                    Button("全选") { model.selectAllDeletableHistory() }.help("选择当前列表的所有可删除记录")
                    Spacer(minLength: 4)
                    Button("删除 \(model.historySelection.ids.count) 项", role: .destructive) {
                        pendingSessionDeletion = model.historySelection.ids
                        showingSessionDeletion = true
                    }.disabled(!model.canDeleteSessions(model.historySelection.ids))
                }.font(.caption).buttonStyle(.borderless).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if projectHistory.isEmpty {
                VStack(spacing: 6) {
                    Text(model.application != nil ? "该应用还没有监听记录" : model.project == nil ? "请先选择项目或应用" : "该项目还没有运行记录").font(.caption)
                    Text(model.application == nil ? "运行所选项目的命令后，记录会显示在这里。" : "连接应用后，日志和网络请求将保存在这里。")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(16)
                Spacer()
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if model.application != nil {
                            ForEach(projectHistory) { session in historyRow(session) }
                        } else {
                        ForEach(historyGroups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Button {
                                    if collapsedHistoryProjects.contains(group.path) { collapsedHistoryProjects.remove(group.path) }
                                    else { collapsedHistoryProjects.insert(group.path) }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: collapsedHistoryProjects.contains(group.path) ? "chevron.right" : "chevron.down")
                                            .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                                        Label(URL(fileURLWithPath: group.path).lastPathComponent, systemImage: "folder")
                                            .font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                        Text(group.sessions.count, format: .number).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).help(group.path)
                                .accessibilityValue(collapsedHistoryProjects.contains(group.path) ? "已折叠" : "已展开")
                                if !collapsedHistoryProjects.contains(group.path) {
                                    ForEach(group.sessions) { session in historyRow(session) }
                                }
                            }
                        }
                        }
                    }.padding(8)
                }
            }
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .onChange(of: model.selectedSession) { _, id in
                if let session = model.history.first(where: { $0.id == id }) {
                    collapsedHistoryProjects.remove(session.projectPath)
                }
            }
    }

    private func historyRow(_ session: RunSession) -> some View {
        Button {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            let mode: HistorySelection.Mode = flags.contains(.shift) ? .range : (selectingHistory || flags.contains(.command) ? .toggle : .single)
            model.toggleSession(session, mode: mode)
        } label: {
            HStack(alignment: .top, spacing: 6) {
            if selectingHistory || model.historySelection.ids.count > 1 {
                Image(systemName: model.historySelection.ids.contains(session.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(model.historySelection.ids.contains(session.id) ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.attachment == nil ? session.command : session.status == .running ? "本次连接" : "应用监听") .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                SessionBadge(status: session.status, compact: true, attachment: session.attachment != nil)
            }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .background(model.historySelection.ids.contains(session.id) ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help("\(session.projectPath)\n\(session.command)")
            .accessibilityAddTraits(model.historySelection.ids.contains(session.id) ? .isSelected : [])
            .contextMenu {
                let ids = model.deletionIDs(for: session)
                Button(ids.count > 1 ? "删除所选 \(ids.count) 条记录…" : "删除记录…", role: .destructive) {
                    pendingSessionDeletion = ids
                    showingSessionDeletion = true
                }.disabled(!model.canDeleteSessions(ids))
            }
    }

    private var logPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                logTitle
                Spacer(minLength: 0)
                Button { showingLogDetails.toggle() } label: { Image(systemName: showingLogDetails ? "info.circle.fill" : "info.circle") }
                    .buttonStyle(.borderless).help(showingLogDetails ? "收起运行详情" : "查看运行时间、命令和路径")
                    .accessibilityLabel("运行详情")
                revealButton
            }
            if let session = model.session {
                HStack(spacing: 7) {
                    Text(session.startedAt.formatted(date: .omitted, time: .standard)).monospacedDigit().fixedSize()
                        .help(session.startedAt.formatted(date: .complete, time: .standard))
                    Text(session.command).font(.system(size: 10, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).help(session.command).frame(maxWidth: .infinity, alignment: .leading)
                    if !session.devToolsURLs.isEmpty {
                        Menu("DevTools") {
                            ForEach(session.devToolsURLs, id: \.self) { url in
                                Button("打开 DevTools") {
                                    if let id = model.liveProjectID(for: session.id) { model.openLiveURL(url, projectID: id) }
                                }.disabled(model.liveProjectID(for: session.id) == nil)
                                Button("复制地址") { model.copy(url) }
                            }
                        }.menuStyle(.borderlessButton).fixedSize().help(session.devToolsURLs.joined(separator: "\n"))
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary).controlSize(.mini)
                if showingLogDetails {
                    ScrollView {
                        sessionMetadata(session).background(GeometryReader { geometry in
                            Color.clear.preference(key: LogMetadataHeightKey.self, value: geometry.size.height)
                        })
                    }.frame(height: min(140, metadataHeight > 0 ? metadataHeight : 75))
                        .onPreferenceChange(LogMetadataHeightKey.self) { metadataHeight = $0 }
                } else if let error = session.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).lineLimit(1).help(error)
                }
                if showingNetwork {
                    NetworkPanel(model: model, monitor: model.network, session: session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LogToolsView(model: model) { logNavigation }
                    LogView(page: model.logPage, totalBytes: model.logTotalBytes, wrapsLines: logWrapsLines,
                            scrollRevision: model.logScrollRevision, placement: model.logScrollPlacement,
                            followsOutput: model.logFollowing, loading: model.logNavigating, highlight: model.logSearchHighlight,
                            showsTimestamps: model.logShowsTimestamps, timeMarks: model.logTimeMarks,
                            onScrollAway: model.pauseLogFollowing, onLoadWindow: model.shiftLogWindow, onSeek: model.seekLog,
                            onProgress: { model.reportLogPosition($0, sessionID: session.id) })
                        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor).opacity(0.65)))
                        .overlay {
                            if model.logPage?.text.isEmpty == true, !model.logQueryBusy, !model.logFilter.isEmpty, !model.logSearchContext {
                                Text("没有匹配的日志，请调整筛选条件").font(.caption).foregroundStyle(.secondary).allowsHitTesting(false)
                            }
                        }
                    if let path = model.selectedOutputPath {
                        Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
                            .accessibilityLabel("当前日志文件 \(path)")
                    }
                    if model.selectedOutputFile == nil {
                        Text("这条记录的日志文件不存在或尚未创建。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "terminal").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(model.application == nil ? "选择一次运行查看日志" : "选择一次监听查看日志").font(.headline)
                    Text(model.application == nil ? "运行新命令后，输出会实时显示在这里。" : "连接后开始接收日志；断开不会退出目标 App。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
    }

    private func sessionMetadata(_ session: RunSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(model.applicationIsLive(session.id) ? "实时监听" : model.projectRuns.values.contains(where: { $0.isBusy && $0.session?.id == session.id }) ? "实时输出" : "历史记录")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(session.sourceName)
                        .font(.caption).lineLimit(1).truncationMode(.middle).help(session.projectPath)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { sessionFacts(session) }
                    VStack(alignment: .leading, spacing: 3) { sessionFacts(session) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                Text("\(session.attachment == nil ? "本次命令" : "监听应用")  \(session.command)").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(session.command).textSelection(.enabled)
            }
            if let message = session.error {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(3).help(message).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if !session.devToolsURLs.isEmpty {
                VStack(spacing: 4) {
                    ForEach(session.devToolsURLs, id: \.self) { url in
                        HStack(spacing: 7) {
                            Label("DevTools", systemImage: "link").font(.caption).foregroundStyle(.blue)
                            Text(url).font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled).help(url).frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                if let id = model.liveProjectID(for: session.id) { model.openLiveURL(url, projectID: id) }
                            } label: { Image(systemName: "arrow.up.right.square") }
                                .disabled(model.liveProjectID(for: session.id) == nil).help("打开 DevTools").accessibilityLabel("打开 DevTools")
                            Button { model.copy(url) } label: { Image(systemName: "doc.on.doc") }
                                .help("复制 DevTools 地址").accessibilityLabel("复制 DevTools 地址")
                        }.controlSize(.small)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var logTitle: some View {
        HStack(spacing: 8) {
            Picker("输出内容", selection: $showingNetwork) {
                Label("日志", systemImage: "terminal").tag(false)
                Label("网络", systemImage: "network").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 140).accessibilityLabel("日志与网络切换")
            if let session = model.session { SessionBadge(status: session.status, attachment: session.attachment != nil) }
            Button { expandedLog.toggle() } label: {
                Image(systemName: expandedLog ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }.buttonStyle(.borderless).help(expandedLog ? "恢复运行记录列表" : "展开日志，隐藏运行记录列表")
                .accessibilityLabel(expandedLog ? "收起日志" : "展开日志")
        }.fixedSize()
    }
    private var logNavigation: some View {
        HStack(spacing: 7) {
            logPageButtons.layoutPriority(-1)
            Spacer(minLength: 0)
            logDisplayOptions
        }.controlSize(.mini).font(.system(size: 10))
    }
    private var logPageButtons: some View {
        HStack(spacing: 5) {
            Button("最早") { model.showLog(.first) }
                .disabled(model.logNavigating || model.logPage == nil)
            Button(model.logHasNewOutput ? "最新 · 有新输出" : "最新") { model.showLog(.latest) }
                .disabled(model.logNavigating)
            if model.logShowsLoading { ProgressView().controlSize(.mini) }
            if model.logPage != nil {
                Text("总 \(logSize(model.logSourceBytes)) · \(model.logPositionPercent)%")
                    .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    .help("原始日志总大小；百分比表示当前阅读位置，应用筛选时按筛选结果计算位置。最早为 0%，最新为 100%。")
            }
        }
    }
    private var logDisplayOptions: some View {
        HStack(spacing: 8) {
            Toggle("跟随", isOn: Binding(get: { model.logFollowing }, set: {
                if $0 { model.showLog(.latest) } else { model.pauseLogFollowing() }
            })).help("向上滚动时自动暂停跟随，点击最新可恢复")
            Toggle("时间", isOn: $model.logShowsTimestamps).help("显示或隐藏每行输出的接收时间").accessibilityLabel("显示输出时间")
            Toggle("换行", isOn: $logWrapsLines).accessibilityLabel("自动换行")
        }.toggleStyle(.checkbox).fixedSize()
    }
    private func logSize(_ value: UInt64) -> String {
        value == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
    private var revealButton: some View {
        Button { model.revealSelectedOutput() } label: { Image(systemName: "folder") }
            .accessibilityLabel("在 Finder 中显示日志文件")
            .controlSize(.small).disabled(model.selectedOutputFile == nil).fixedSize()
            .help(model.selectedOutputPath.map { "在 Finder 中显示日志文件\n" + $0 } ?? "请先选择一次运行记录")
            .accessibilityHint("定位当前选中运行的 output.raw 原始输出文件，不是最新一次运行")
    }

    @ViewBuilder
    private func sessionFacts(_ session: RunSession) -> some View {
        Text("开始 \(session.startedAt.formatted(date: .abbreviated, time: .standard))")
        if let end = session.endedAt { Text("结束 \(end.formatted(date: .omitted, time: .standard))") }
        if let code = session.exitCode { Text("退出码 \(code)").monospacedDigit() }
    }
}

private struct ProjectHistoryGroup: Identifiable {
    let path: String
    let sessions: [RunSession]
    var id: String { path }
}

private struct LogMetadataHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PhaseBadge: View {
    let phase: ProjectRunPhase
    var body: some View {
        switch phase {
        case .idle: StatusTag(title: "就绪", icon: "circle", color: .secondary)
        case .starting: StatusTag(title: "正在启动", icon: "hourglass", color: .orange)
        case .running: StatusTag(title: "项目运行中", icon: "play.fill", color: .blue)
        case .stopping: StatusTag(title: "正在停止", icon: "stop.fill", color: .orange)
        }
    }
}

private struct SessionBadge: View {
    let status: RunStatus
    var compact = false
    var attachment = false
    private var details: (String, String, Color) {
        switch status {
        case .running: return (attachment ? "监听中" : "运行中", attachment ? "link" : "play.fill", .blue)
        case .succeeded: return ("已完成", "checkmark.circle.fill", .green)
        case .failed: return ("失败", "exclamationmark.circle.fill", .red)
        case .stopped: return (attachment ? "已断开" : "已停止", "stop.circle", .secondary)
        case .cancelled: return ("已取消", "xmark.circle", .secondary)
        case .interrupted: return ("已中断", "exclamationmark.triangle", .orange)
        case .detached: return ("已分离", "arrow.up.right.square", .secondary)
        }
    }
    var body: some View { StatusTag(title: details.0, icon: details.1, color: details.2, compact: compact) }
}

private struct StatusTag: View {
    let title: String
    let icon: String
    let color: Color
    var compact = false
    var body: some View {
        Label { Text(title).foregroundStyle(.primary) } icon: { Image(systemName: icon).foregroundStyle(color) }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, compact ? 4 : 6).padding(.vertical, compact ? 2 : 3)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize().accessibilityLabel(title)
    }
}
