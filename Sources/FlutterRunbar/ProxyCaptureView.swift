import SwiftUI
import AppKit
import RunbarCore

struct ProxyCaptureSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var certificates: ProxyCertificateModel
    let projectID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var options: ProxyProjectOptions
    @State private var executable: String
    @State private var error: String?
    @State private var showingCertificateSetup = false
    init(model: AppModel, projectID: UUID?) {
        self.model = model; self.projectID = projectID
        certificates = model.proxyCertificates
        _options = State(initialValue: model.config.projects.first { $0.id == projectID }?.proxyCapture ?? ProxyProjectOptions())
        _executable = State(initialValue: UserDefaults.standard.string(forKey: "proxyMitmdumpPath") ?? "")
    }
    private var project: Project? { model.config.projects.first { $0.id == projectID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("代理抓包").font(.title2)
            if let project {
                Text(project.name).font(.headline)
                Toggle("下次运行时开启代理抓包", isOn: $options.enabled)
                Toggle("解密 HTTPS / WSS", isOn: $options.decryptTLS)
                    .disabled(!options.enabled)
            }
            Text("现有 DevTools 采集继续独立工作。代理监听本机随机端口，只为该次运行注入 HTTP_PROXY / HTTPS_PROXY 和本机绕过规则。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("抓包引擎").font(.headline)
            if executable.isEmpty, let bundled = ProxyLaunchConfiguration.bundledEngine() {
                HStack {
                    Label("内置 mitmproxy \(bundled.version)", systemImage: "checkmark.circle.fill")
                    Spacer()
                    Button("开源许可…") { NSWorkspace.shared.open(bundled.notices) }
                }.font(.caption)
                Text("已随 Runbar 安装，无需额外安装 Python、Homebrew 或抓包工具。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let found = ProxyLaunchConfiguration.findExecutable(preferred: executable) {
                Label("使用外部引擎：\(found.path)", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(executable.isEmpty ? "当前安装缺少内置引擎，请重新安装 Runbar，或在高级选项中指定外部引擎。" : "自定义引擎不可用，请重新选择或恢复内置引擎。")
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("高级：使用自定义引擎（可选）") {
                HStack {
                    TextField("留空使用 Runbar 内置引擎", text: $executable).textFieldStyle(.roundedBorder)
                    Button("选择…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                        panel.message = "可选：选择自定义 mitmdump 可执行文件（10+）"
                        if panel.runModal() == .OK, let url = panel.url { executable = url.path }
                    }
                    Button("恢复内置") { executable = "" }.disabled(executable.isEmpty)
                }.padding(.top, 6)
            }.font(.caption)
            Divider()
            HStack {
                Text("HTTPS / WSS 证书").font(.headline)
                Spacer()
                Button(certificates.status.state == .trusted ? "查看授权…" : "配置证书信任…") {
                    showingCertificateSetup = true
                }.disabled(certificates.working)
            }
            Label(certificates.title, systemImage: certificates.status.state == .trusted ? "checkmark.seal.fill" : "lock.shield")
                .font(.caption).foregroundStyle(certificates.status.state == .trusted ? Color.green : Color.secondary)
            Text("首次开启解密时，按引导直接打开系统信任窗口完成授权。关闭解密则 TLS 原样透传，仅显示 CONNECT 摘要。")
                .font(.caption).foregroundStyle(.secondary)
            Text("Dart 默认直连：仅当 App / 网络库已支持代理时环境变量才生效。证书固定、自定义证书库、原生插件及 WebView 可能需要各自配置；远端手机 / 模拟器不能通过这里的 127.0.0.1 自动接入。停止或分离当前命令也会结束其代理。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(certificates.working)
                Button("保存") {
                    if options.enabled && ProxyLaunchConfiguration.findExecutable(preferred: executable) == nil {
                        error = "抓包引擎不可用。请恢复内置引擎、重新安装 Runbar，或选择有效的自定义 mitmdump。"; return
                    }
                    if let projectID, !model.setProxyOptions(options, projectID: projectID) { return }
                    UserDefaults.standard.set(executable, forKey: "proxyMitmdumpPath")
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(certificates.working)
            }
        }.padding(22).frame(width: 590).controlSize(.small).interactiveDismissDisabled(certificates.working)
            .task { certificates.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in certificates.refresh() }
            .onChange(of: options.decryptTLS) { _, enabled in
                if enabled, certificates.status.state != .trusted { showingCertificateSetup = true }
            }
            .sheet(isPresented: $showingCertificateSetup) {
                ProxyCertificateSetupView(model: model, preferredEngine: executable)
            }
    }
}

struct NetworkWorkspaceView: View {
    enum Source: String, CaseIterable { case devtools = "DevTools", proxyHTTP = "代理 HTTP", webSocket = "WebSocket" }
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: NetworkMonitor
    let session: RunSession
    @State private var source = Source.devtools
    @State private var status: ProxyCaptureStatus?
    @State private var showingSettings = false
    @State private var showingCertificates = false
    private var directory: URL? { monitor.directory(session.id)?.deletingLastPathComponent().appendingPathComponent("proxy", isDirectory: true) }
    var body: some View {
        VStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    sourcePicker
                    captureStatus
                    Spacer(minLength: 0)
                    captureActions
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) { sourcePicker; Spacer(minLength: 0) }
                    HStack(spacing: 8) { captureStatus; Spacer(minLength: 0); captureActions }
                }
                VStack(alignment: .leading, spacing: 5) {
                    sourcePicker
                    HStack(spacing: 8) { captureStatus; Spacer(minLength: 0); captureActions.labelStyle(.iconOnly) }
                }
            }.fixedSize(horizontal: false, vertical: true).controlSize(.small)
            if source != .devtools, let warning = status?.warning {
                HStack(spacing: 8) {
                    Text(warning).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2).help(warning)
                    if status?.issue == "tlsHandshake", session.proxyCapture?.decryptTLS == true {
                        Button("配置证书…") { showingCertificates = true }.controlSize(.small)
                    }
                }
            }
            if source != .devtools, let dropped = status?.dropped, dropped > 0 {
                Text("\(dropped) 个采集事件未缓存").font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if source == .devtools {
                NetworkPanel(model: model, monitor: monitor, session: session)
            } else if session.proxyCapture != nil, let directory {
                if source == .proxyHTTP {
                    NetworkPanel(model: model, monitor: monitor, session: session, proxyMode: true, captureRevision: status?.updatedAt ?? .distantPast)
                } else { ProxyWebSocketView(directory: directory, sessionID: session.id, captureRevision: status?.updatedAt ?? .distantPast) }
            } else {
                ContentUnavailableView {
                    Label("本次运行未开启代理抓包", systemImage: "network")
                } description: {
                    Text("在命令旁的「代理抓包」中开启后重新运行项目。关联到已运行 App 时，继续使用 DevTools；代理无法追溯直连流量。")
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).task(id: session.id) {
            source = session.proxyCapture == nil ? .devtools : .proxyHTTP
            status = nil
            guard let directory, session.proxyCapture != nil else { return }
            while !Task.isCancelled {
                status = await Task.detached(priority: .utility) { ProxyCaptureStatus.read(directory: directory) }.value
                if session.status != .running || status?.running == false { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }.sheet(isPresented: $showingSettings) {
            ProxyCaptureSettingsView(model: model, projectID: model.selectedProject)
        }.sheet(isPresented: $showingCertificates) {
            ProxyCertificateSetupView(model: model)
        }
    }
    private var sourcePicker: some View {
        Picker("网络数据来源", selection: $source) {
            ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 290)
            .accessibilityLabel("网络数据来源")
    }
    @ViewBuilder private var captureStatus: some View {
        if source != .devtools, let info = session.proxyCapture {
            Text(session.status == .running ? (status?.message ?? info.address) : "本地历史缓存 · 代理已结束")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 80, alignment: .leading)
                .help("\(info.address) · 每次运行独立代理，仅记录经过该端口的流量")
        }
    }
    @ViewBuilder private var captureActions: some View {
        if source != .devtools {
            HStack(spacing: 8) {
                if let info = session.proxyCapture {
                    Menu {
                        Button("复制代理地址") { model.copy(info.address) }
                        if let directory {
                            Button("在 Finder 中显示抓包缓存") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                        }
                        Button("证书信任设置…") { showingCertificates = true }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
                        .accessibilityLabel("代理抓包操作")
                }
                if session.proxyCapture?.decryptTLS == true {
                    Button("证书授权…", systemImage: "lock.shield") { showingCertificates = true }
                }
                Button("抓包设置", systemImage: "gearshape") { showingSettings = true }
                    .disabled(model.selectedProject.map { model.state(for: $0).isBusy } == true)
            }.fixedSize()
        }
    }
}
