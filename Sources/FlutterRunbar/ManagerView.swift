import SwiftUI
import AppKit
import RunbarCore

struct ManagerView: View {
    @ObservedObject var model: AppModel
    @State private var editing = false
    @State private var editingID: UUID?
    @State private var presetName = ""
    @State private var command = ""
    @State private var pathSettings = false
    @State private var metadataHeight: CGFloat = 0

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

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.project?.name ?? "选择一个 Flutter 项目")
                        .font(.system(size: 20, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .help(model.project?.name ?? "")
                    Text(model.project?.path ?? "从左侧添加项目，管理命令与本地运行日志。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(model.project?.path ?? "")
                        .accessibilityLabel(model.project.map { "项目目录 \($0.path)" } ?? "尚未选择项目")
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.project != nil { PhaseBadge(phase: model.selectedState.phase) }
                Button { pathSettings = true } label: { Image(systemName: "gearshape") }
                    .help("命令环境与 PATH 设置").accessibilityLabel("PATH 设置")
            }
            if let project = model.project {
                HStack(spacing: 8) {
                    Text("运行配置").font(.caption).foregroundStyle(.secondary)
                    Picker("运行配置", selection: $model.selectedPreset) {
                        ForEach(project.presets) { preset in Text(preset.name).tag(Optional(preset.id)) }
                    }.labelsHidden().frame(minWidth: 120, maxWidth: 240).disabled(model.selectedState.isBusy)
                    Button { editingID = nil; presetName = "新命令"; command = "fvm flutter run -d macos"; editing = true } label: { Image(systemName: "plus") }
                        .disabled(model.selectedState.isBusy).help("添加命令").accessibilityLabel("添加命令")
                    Button {
                        guard let preset = model.preset else { return }
                        editingID = preset.id; presetName = preset.name; command = preset.command; editing = true
                    } label: { Image(systemName: "pencil") }
                        .disabled(model.preset == nil || model.selectedState.isBusy).help("编辑所选命令").accessibilityLabel("编辑命令")
                    Spacer(minLength: 4)
                    Button(model.selectedState.isBusy ? (model.selectedState.phase == .stopping ? "正在停止…" : "停止当前运行") : "运行", systemImage: model.selectedState.isBusy ? "stop.fill" : "play.fill") {
                        model.selectedState.isBusy ? model.stop() : model.run()
                    }.buttonStyle(.borderedProminent)
                        .tint(model.selectedState.isBusy ? .orange : .accentColor)
                        .disabled(model.selectedState.phase == .stopping || (!model.selectedState.isBusy && model.preset == nil) || model.quitWhenFinished)
                }.controlSize(.small)
                Text(model.preset?.command ?? "尚未配置命令")
                    .font(.system(size: 12, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
                    .help(model.preset?.command ?? "")
            }
        }.padding(16)
    }

    private var historyPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("运行记录", systemImage: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text("\(model.history.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }.padding(.horizontal, 12).padding(.vertical, 12)
            if model.history.isEmpty {
                VStack(spacing: 6) {
                    Text("还没有运行记录").font(.caption)
                    Text("运行命令后，记录会保存在这里。")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(16)
                Spacer()
            } else {
                List(model.history) { session in
                    Button {
                        model.selectedSession = session.id
                        model.selectedProject = model.config.projects.first(where: { $0.path == session.projectPath })?.id
                        model.loadLog()
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(URL(fileURLWithPath: session.projectPath).lastPathComponent)
                                .font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text(session.command).font(.system(size: 10, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
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
                }.listStyle(.inset)
            }
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
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
        }.padding(14)
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
