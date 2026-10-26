import SwiftUI
import AppKit
import RunbarCore

struct ManagerView: View {
    @ObservedObject var model: AppModel
    @State private var editing = false
    @State private var editingID: UUID?
    @State private var editingProjectID: UUID?
    @State private var presetName = ""
    @State private var command = ""
    @State private var templates: [CommandTemplate] = []
    @State private var templateID: String?
    @State private var useFVM = true
    @State private var editorError: String?
    @State private var pathSettings = false
    @State private var metadataHeight: CGFloat = 0
    @State private var collapsedHistoryProjects = Set<String>()
    @State private var selectingHistory = false
    @State private var pendingSessionDeletion = Set<UUID>()
    @State private var showingSessionDeletion = false
    @State private var pendingProjectRemoval: Project?
    @State private var expandedLog = false
    @AppStorage("logWrapsLines") private var logWrapsLines = false
    private var projectHistory: [RunSession] {
        guard let path = model.project?.path else { return [] }
        return model.history.filter { $0.projectPath == path }
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
                                        Text(project.name).font(.system(size: 12, weight: .semibold))
                                            .lineLimit(1).truncationMode(.middle)
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
                }.listStyle(.sidebar)
                Divider()
                HStack {
                    Button("添加项目…", systemImage: "folder.badge.plus") { model.chooseProject() }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { pendingProjectRemoval = model.project } label: { Image(systemName: "minus") }
                        .disabled(model.project == nil || model.selectedState.isBusy)
                        .help("移除所选项目").accessibilityLabel("移除所选项目")
                }.padding(12)
            }.navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            VStack(spacing: 0) {
                projectHeader
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
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                Text(editingID == nil ? "添加命令" : "编辑命令").font(.title2)
                if editingID == nil { templatePicker }
                TextField("名称", text: $presetName)
                TextEditor(text: $command).font(.system(.body, design: .monospaced)).frame(height: 120)
                Text("命令由登录 zsh 执行，支持参数、引号与管道。只保存你信任的命令，它拥有你当前用户的权限。运行输出永远不会作为命令执行。不要使用后台化或守护进程命令。")
                    .font(.caption).foregroundStyle(.secondary)
                if let editorError { Text(editorError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: editingID == nil ? 420 : 280)
                HStack { Spacer(); Button("取消") { editing = false }; Button("保存") { if model.savePreset(name: presetName, command: command, id: editingID, projectID: editingProjectID) { editing = false } else { editorError = model.error ?? "项目正在运行或不可用，暂时无法保存。"; model.error = nil } }.disabled(presetName.isEmpty || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(24).frame(width: 520)
        }
        .sheet(isPresented: $pathSettings) {
            VStack(alignment: .leading, spacing: 16) {
                Text("命令环境").font(.title2)
                Text("额外 PATH（冒号分隔；支持完整路径和 ~/）")
                TextField("PATH", text: $model.config.extraPath)
                Text("自定义目录优先，并自动补充 ~/.pub-cache/bin、~/fvm/bin 和 Homebrew 路径；可添加其他 FVM 安装目录。不安装 SDK、不修改 shell 配置。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("保存") { model.persist(); pathSettings = false }
            }.padding(24).frame(width: 560)
        }
        .alert("需要注意", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("删除 \(pendingSessionDeletion.count) 条运行记录？", isPresented: $showingSessionDeletion) {
            Button("取消", role: .cancel) { pendingSessionDeletion = [] }
            Button("移到废纸篓", role: .destructive) {
                let ids = pendingSessionDeletion; pendingSessionDeletion = []
                model.deleteSessions(ids)
            }
        } message: { Text("对应日志也会一起移到废纸篓，可从废纸篓恢复。正在运行的记录不能删除。") }
        .confirmationDialog("移除项目“\(pendingProjectRemoval?.name ?? "")”？", isPresented: Binding(
            get: { pendingProjectRemoval != nil }, set: { if !$0 { pendingProjectRemoval = nil } }
        ), titleVisibility: .visible) {
            if let project = pendingProjectRemoval {
                Button("移除项目", role: .destructive) { model.removeProject(project.id); pendingProjectRemoval = nil }
            }
            Button("取消", role: .cancel) { pendingProjectRemoval = nil }
        } message: { Text("仅移除应用内的项目配置和命令，不删除磁盘上的项目文件或运行记录。") }
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.project?.name ?? "选择一个项目")
                        .font(.system(size: 16, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .help(model.project?.name ?? "")
                    Text(model.project?.path ?? "从左侧添加项目，管理命令与本地运行日志。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(model.project?.path ?? "")
                        .accessibilityLabel(model.project.map { "项目目录 \($0.path)" } ?? "尚未选择项目")
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let project = model.project {
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
                Button { pathSettings = true } label: { Image(systemName: "gearshape") }
                    .help("命令环境与 PATH 设置").accessibilityLabel("PATH 设置")
            }
            if let project = model.project {
                HStack(spacing: 6) {
                    Text("命令").font(.caption).foregroundStyle(.secondary).fixedSize()
                    Picker("运行配置", selection: $model.selectedPreset) {
                        if project.presets.isEmpty { Text("选择命令").tag(Optional<UUID>.none) }
                        ForEach(project.availablePresets) { preset in Text(preset.name).tag(Optional(preset.id)) }
                    }.labelsHidden().frame(minWidth: 110, maxWidth: 160).disabled(model.selectedState.isBusy)
                    Button { beginAddingCommand(for: project) } label: { Image(systemName: "plus") }
                        .disabled(model.selectedState.isBusy).help("添加常用模板或自定义命令").accessibilityLabel("添加命令或常用模板")
                    Button {
                        guard let preset = model.preset else { return }
                        editorError = nil; editingProjectID = project.id; editingID = preset.id; presetName = preset.name; command = preset.command; editing = true
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

    private func beginAddingCommand(for project: Project) {
        editorError = nil; editingProjectID = project.id; editingID = nil
        presetName = ""; command = ""
        templates = CommandTemplate.templates(for: project)
        templateID = templates.first?.id; useFVM = project.kind == .flutter
        editing = true
    }

    @ViewBuilder
    private var templatePicker: some View {
        if templates.isEmpty {
            Text("此项目没有预设模板，请直接填写自定义命令。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("常用模板", selection: $templateID) {
                        ForEach(templates) { template in Text(template.name).tag(Optional(template.id)) }
                    }
                    if templates.first(where: { $0.id == templateID })?.supportsFVM == true {
                        Toggle("使用 FVM", isOn: $useFVM).fixedSize()
                    }
                }
                if let template = templates.first(where: { $0.id == templateID }) {
                    Text(template.command(useFVM: useFVM)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text(template.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("填入下方编辑区") {
                        presetName = template.name; command = template.command(useFVM: useFVM)
                    }.help("替换下方草稿，不保存也不执行；可继续编辑")
                }
                Text("模板仅供选择和编辑，保存后仍需手动运行；所需工具链请自行安装。")
                    .font(.caption2).foregroundStyle(.secondary)
                Divider()
            }
        }
    }

    private var historyPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("运行记录", systemImage: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text("\(projectHistory.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button(selectingHistory ? "完成" : "多选") {
                    selectingHistory.toggle()
                    if !selectingHistory { model.selectedSession = model.selectedSession }
                }.buttonStyle(.borderless).font(.caption)
            }.padding(.horizontal, 12).padding(.vertical, 8)
            if selectingHistory || model.historySelection.ids.count > 1 {
                HStack {
                    Button("全选") { model.selectAllDeletableHistory() }.help("选择当前项目的所有可删除记录")
                    Spacer(minLength: 4)
                    Button("删除 \(model.historySelection.ids.count) 项", role: .destructive) {
                        pendingSessionDeletion = model.historySelection.ids
                        showingSessionDeletion = true
                    }.disabled(!model.canDeleteSessions(model.historySelection.ids))
                }.font(.caption).buttonStyle(.borderless).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if projectHistory.isEmpty {
                VStack(spacing: 6) {
                    Text(model.project == nil ? "请先选择项目" : "该项目还没有运行记录").font(.caption)
                    Text("运行所选项目的命令后，记录会显示在这里。")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(16)
                Spacer()
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 8) {
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
                Text(session.command).font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                SessionBadge(status: session.status, compact: true)
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
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { logTitle; Spacer(minLength: 4); revealButton }
                VStack(alignment: .leading, spacing: 7) {
                    logTitle
                    revealButton.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if let session = model.session {
                ScrollView {
                    sessionMetadata(session).background(GeometryReader { geometry in
                        Color.clear.preference(key: LogMetadataHeightKey.self, value: geometry.size.height)
                    })
                }.frame(height: min(140, metadataHeight > 0 ? metadataHeight : 100))
                    .onPreferenceChange(LogMetadataHeightKey.self) { metadataHeight = $0 }
                logNavigation
                LogView(page: model.logPage, totalBytes: model.logTotalBytes, wrapsLines: logWrapsLines,
                        scrollRevision: model.logScrollRevision, placement: model.logScrollPlacement,
                        followsOutput: model.logFollowing, loading: model.logNavigating,
                        onScrollAway: model.pauseLogFollowing, onLoadWindow: model.shiftLogWindow, onSeek: model.seekLog)
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor).opacity(0.65)))
                if let path = model.selectedOutputPath {
                    Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
                        .accessibilityLabel("当前日志文件 \(path)")
                }
                if model.selectedOutputFile == nil {
                    Text("这次运行的日志文件不存在或尚未创建。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "terminal").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("选择一次运行查看日志").font(.headline)
                    Text("运行新命令后，输出会实时显示在这里。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                Text("仅保存在本机 · 分段读取完整日志，单段最多 1 MB")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 14)
    }

    private func sessionMetadata(_ session: RunSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(model.projectRuns.values.contains(where: { $0.isBusy && $0.session?.id == session.id }) ? "实时输出" : "历史记录")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(URL(fileURLWithPath: session.projectPath).lastPathComponent)
                        .font(.caption).lineLimit(1).truncationMode(.middle).help(session.projectPath)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { sessionFacts(session) }
                    VStack(alignment: .leading, spacing: 3) { sessionFacts(session) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                Text("本次命令  \(session.command)").font(.system(size: 10, design: .monospaced))
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
            Label("输出日志", systemImage: "terminal").font(.system(size: 13, weight: .semibold))
            if let session = model.session { SessionBadge(status: session.status) }
            Button { expandedLog.toggle() } label: {
                Image(systemName: expandedLog ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }.buttonStyle(.borderless).help(expandedLog ? "恢复运行记录列表" : "展开日志，隐藏运行记录列表")
                .accessibilityLabel(expandedLog ? "收起日志" : "展开日志")
        }.fixedSize()
    }
    private var logNavigation: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { logPageButtons; Spacer(minLength: 4); logDisplayOptions }
            VStack(alignment: .leading, spacing: 5) {
                logPageButtons
                HStack { logDisplayOptions; Spacer(minLength: 0) }
            }
        }.controlSize(.mini).font(.system(size: 10))
    }
    private var logPageButtons: some View {
        HStack(spacing: 5) {
            Button("最早") { model.showLog(.first) }
                .disabled(model.logNavigating || model.logPage == nil)
            Button(model.logHasNewOutput ? "最新 · 有新输出" : "最新") { model.showLog(.latest) }
                .disabled(model.logNavigating)
            if model.logShowsLoading { ProgressView().controlSize(.mini) }
            if let page = model.logPage {
                Text("\(logSize(page.startOffset))–\(logSize(page.endOffset)) / \(logSize(model.logTotalBytes))")
                    .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    .help("内存中的日志范围 / 文件总大小；上下滚动自动读取，右侧滚动条代表整份日志的字节进度")
            }
        }
    }
    private var logDisplayOptions: some View {
        HStack(spacing: 8) {
            Toggle("跟随输出", isOn: Binding(get: { model.logFollowing }, set: {
                if $0 { model.showLog(.latest) } else { model.pauseLogFollowing() }
            })).help("向上滚动时自动暂停跟随，点击最新可恢复")
            Toggle("自动换行", isOn: $logWrapsLines)
        }.toggleStyle(.checkbox).fixedSize()
    }
    private func logSize(_ value: UInt64) -> String {
        value == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
    private var revealButton: some View {
        Button("在 Finder 中显示日志文件", systemImage: "folder") { model.revealSelectedOutput() }
            .controlSize(.small).disabled(model.selectedOutputFile == nil).fixedSize()
            .help(model.selectedOutputPath ?? "请先选择一次运行记录")
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
    private var details: (String, String, Color) {
        switch status {
        case .running: return ("运行中", "play.fill", .blue)
        case .succeeded: return ("已完成", "checkmark.circle.fill", .green)
        case .failed: return ("失败", "exclamationmark.circle.fill", .red)
        case .stopped: return ("已停止", "stop.circle", .secondary)
        case .cancelled: return ("已取消", "xmark.circle", .secondary)
        case .interrupted: return ("已中断", "exclamationmark.triangle", .orange)
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
