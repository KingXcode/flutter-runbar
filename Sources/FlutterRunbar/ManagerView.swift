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
    @State private var templateID = CommandTemplate.all[0].id
    @State private var useFVM = true
    @State private var editorError: String?
    @State private var pathSettings = false
    @State private var metadataHeight: CGFloat = 0
    @State private var collapsedHistoryProjects = Set<String>()
    private var historyGroups: [ProjectHistoryGroup] {
        Dictionary(grouping: model.history, by: \.projectPath)
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
                        }
                    } header: {
                        HStack { Text("项目"); Spacer(); Text("\(model.config.projects.count)").monospacedDigit() }
                    }
                }.listStyle(.sidebar)
                Divider()
                Button("添加项目…", systemImage: "folder.badge.plus") { model.chooseProject() }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            VStack(spacing: 0) {
                projectHeader
                Divider()
                HSplitView {
                    historyPane.frame(minWidth: 150, idealWidth: 170, maxWidth: 180)
                    logPane.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            }.background(Color(nsColor: .windowBackgroundColor))
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
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                Text(editingID == nil ? "添加命令" : "编辑命令").font(.title2)
                if editingID == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("常用模板", selection: $templateID) {
                                ForEach(CommandTemplate.all) { template in Text(template.name).tag(template.id) }
                            }
                            Toggle("使用 FVM", isOn: $useFVM).fixedSize()
                        }
                        if let template = CommandTemplate.all.first(where: { $0.id == templateID }) {
                            Text(template.command(useFVM: useFVM)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text(template.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("填入下方编辑区") {
                                presetName = template.name
                                command = template.command(useFVM: useFVM)
                            }.help("替换下方草稿，不保存也不执行；可继续编辑")
                        }
                        Text(useFVM ? "需已安装 FVM 并为项目配置 Flutter SDK。" : "使用 PATH 中的 flutter / dart；请确认两者属于预期 SDK。")
                            .font(.caption2).foregroundStyle(.secondary)
                        Divider()
                    }
                }
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

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.project?.name ?? "选择一个 Flutter 项目")
                        .font(.system(size: 16, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .help(model.project?.name ?? "")
                    Text(model.project?.path ?? "从左侧添加项目，管理命令与本地运行日志。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(model.project?.path ?? "")
                        .accessibilityLabel(model.project.map { "项目目录 \($0.path)" } ?? "尚未选择项目")
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.project != nil { PhaseBadge(phase: model.selectedState.phase) }
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
                    Button { editorError = nil; editingProjectID = project.id; editingID = nil; presetName = ""; command = ""; templateID = "pub-get"; useFVM = true; editing = true } label: { Image(systemName: "plus") }
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

    private var historyPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("运行记录", systemImage: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text("\(model.history.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }.padding(.horizontal, 12).padding(.vertical, 8)
            if model.history.isEmpty {
                VStack(spacing: 6) {
                    Text("还没有运行记录").font(.caption)
                    Text("运行命令后，记录会保存在这里。")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(16)
                Spacer()
            } else {
                List {
                    ForEach(historyGroups) { group in
                        DisclosureGroup(isExpanded: Binding(
                            get: { !collapsedHistoryProjects.contains(group.path) },
                            set: { expanded in
                                if expanded { collapsedHistoryProjects.remove(group.path) }
                                else { collapsedHistoryProjects.insert(group.path) }
                            }
                        )) {
                            ForEach(group.sessions) { session in historyRow(session) }
                        } label: {
                            HStack(spacing: 4) {
                                Label(URL(fileURLWithPath: group.path).lastPathComponent, systemImage: "folder")
                                    .font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(group.sessions.count, format: .number).font(.caption2).foregroundStyle(.secondary)
                            }.help(group.path)
                        }
                    }
                }.listStyle(.inset)
            }
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .onChange(of: model.selectedSession) { _, id in
                if let session = model.history.first(where: { $0.id == id }) {
                    collapsedHistoryProjects.remove(session.projectPath)
                }
            }
    }

    private func historyRow(_ session: RunSession) -> some View {
        Button { model.toggleSession(session) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(session.command).font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                        Spacer(minLength: 0)
                        SessionBadge(status: session.status, compact: true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        SessionBadge(status: session.status, compact: true)
                    }
                }
            }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(session.projectPath)\n\(session.command)")
            .listRowBackground(model.selectedSession == session.id ? Color.accentColor.opacity(0.12) : Color.clear)
            .accessibilityAddTraits(model.selectedSession == session.id ? .isSelected : [])
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
                LogView(text: model.logText)
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
                Text("仅保存在本机 · 视图显示尾部，文件保留完整输出")
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
        }.fixedSize()
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

/// Selectable, wrapping native log view with semantic colors in both appearances.
struct LogView: NSViewRepresentable {
    var text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 12, height: 12); view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("运行日志")
        scroll.documentView = view; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        guard view.string != text else { return }
        let atBottom = scroll.documentVisibleRect.maxY >= view.bounds.maxY - 40
        view.string = text
        if atBottom { view.scrollToEndOfDocument(nil) }
    }
}
