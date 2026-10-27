import SwiftUI
import AppKit
import RunbarCore

@MainActor
private final class NetworkPanelModel: ObservableObject {
    enum Detail: String, CaseIterable { case overview = "概览", headers = "Headers", request = "Request", response = "Response" }
    @Published var query = NetworkQuery() { didSet { if query != oldValue { pageIndex = 0; refresh(delay: true) } } }
    @Published private(set) var page = NetworkPage.empty
    @Published private(set) var pageIndex = 0
    @Published var selectedID: String? { didSet { if selectedID != oldValue { bodyIndex = 0; loadDetail() } } }
    @Published var detail = Detail.overview { didSet { bodyIndex = 0; loadDetail() } }
    @Published private(set) var bodyText = "选择一条请求查看详情"
    @Published private(set) var bodyIndex = 0
    @Published private(set) var bodyPages = 1
    @Published private(set) var bodyBytes = 0
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private let reader = NetworkCacheReader()
    private var directory: URL?
    private var sessionID: UUID?
    private var pageTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    var selected: NetworkRecord? { page.records.first { $0.id == selectedID } }
    func configure(directory: URL?, sessionID: UUID) {
        if self.sessionID != sessionID {
            pageTask?.cancel(); detailTask?.cancel(); selectedID = nil; page = .empty; pageIndex = 0
        }
        self.directory = directory; self.sessionID = sessionID; refresh()
    }
    func refresh(delay: Bool = false) {
        pageTask?.cancel()
        guard let directory else { return }
        let query = query, index = pageIndex
        pageTask = Task { [weak self] in
            guard let self else { return }
            if delay { do { try await Task.sleep(for: .milliseconds(250)) } catch { return } }
            do {
                let old = self.selected
                let page = try await reader.page(directory: directory, query: query, page: index)
                guard !Task.isCancelled else { return }
                self.page = page; self.pageIndex = page.page; self.error = nil
                if old != self.selected { self.loadDetail() }
            } catch {
                guard !Task.isCancelled else { return }; self.error = error.localizedDescription
            }
        }
    }
    func movePage(_ delta: Int) {
        pageIndex = max(0, pageIndex + delta); selectedID = nil; refresh()
    }
    func moveBody(_ delta: Int) { bodyIndex = min(max(0, bodyIndex + delta), bodyPages - 1); loadDetail() }
    private func loadDetail() {
        detailTask?.cancel(); loading = false; error = nil
        guard let record = selected else { bodyText = "选择一条请求查看详情"; bodyPages = 1; bodyBytes = 0; return }
        bodyPages = 1; bodyBytes = 0
        switch detail {
        case .overview:
            let duration = record.durationMS.map { String(format: "%.1f ms", $0) } ?? "进行中"
            bodyText = """
                \(record.method) \(record.url)

                状态：\(record.failure ?? record.status.map(String.init) ?? "Pending")
                时间：\(record.startDate.formatted(date: .numeric, time: .standard))
                耗时：\(duration)
                类型：\(record.contentType.isEmpty ? "未知" : record.contentType)
                请求正文大小：\(size(record.requestBytes))
                响应正文大小：\(size(record.responseBytes))
                正文缓存：\(record.bodyState.title)\(record.bodyNote.isEmpty ? "" : " · " + record.bodyNote)
                """
        case .headers:
            bodyText = "Request Headers\n\n\(record.requestHeaders.isEmpty ? "尚无数据" : record.requestHeaders)\n\nResponse Headers\n\n\(record.responseHeaders.isEmpty ? "尚无数据" : record.responseHeaders)"
        case .request, .response:
            guard let directory else { return }
            loading = true; bodyText = "正在读取正文…"
            let response = detail == .response, index = bodyIndex
            detailTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let page = try await reader.body(directory: directory, record: record, response: response, page: index)
                    guard !Task.isCancelled else { return }
                    self.bodyText = page.text; self.bodyIndex = page.page; self.bodyPages = page.pages; self.bodyBytes = page.bytes; self.loading = false
                } catch {
                    guard !Task.isCancelled else { return }
                    self.bodyText = "正文文件不存在或读取失败。"; self.loading = false
                }
            }
        }
    }
    private func size(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "未知" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    func stop() { pageTask?.cancel(); detailTask?.cancel() }
}

struct NetworkPanel: View {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"; return formatter
    }()
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: NetworkMonitor
    let session: RunSession
    @StateObject private var data = NetworkPanelModel()
    @State private var confirmingClear = false
    private var project: Project? { model.config.projects.first { $0.path == session.projectPath } }
    private var enabled: Bool { project?.networkCaptureEnabled == true }
    private var state: NetworkMonitor.State? { monitor.states[session.id] }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Toggle("网络采集", isOn: Binding(get: { enabled }, set: { value in
                    if let project { model.setNetworkCaptureEnabled(value, projectID: project.id) }
                })).toggleStyle(.checkbox).fixedSize().disabled(project == nil)
                    .help("自动保存当前项目的开关，连接运行进程的 VM Service 后开始接收。关闭或暂停只停止 Runbar 读取，目标缓冲可能继续记录。")
                Text(state?.text ?? "本地历史缓存").font(.caption).foregroundStyle(state?.error == true ? .red : .secondary)
                    .lineLimit(1).help(state?.text ?? "已缓存的请求可在进程退出后查看")
                Spacer(minLength: 0)
                if monitor.isLive(session.id), enabled, monitor.hasConnection(session.id) {
                    Button(state?.paused == true ? "继续" : "暂停") { monitor.togglePause(session.id) }
                        .help("暂停 / 恢复 Runbar 接收；目标进程的采集缓冲仍可能增长")
                    if state?.canResumeApplication == true {
                        Button("恢复程序") { monitor.resumeApplication(session.id) }.help("恢复由 --start-paused 启动并已暂停的 Dart / Flutter 程序")
                    }
                    Menu {
                        Button("清理目标采集缓冲…", role: .destructive) { confirmingClear = true }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("网络采集操作")
                }
            }
            HStack(spacing: 6) {
                TextField("搜索请求地址", text: $data.query.text).textFieldStyle(.roundedBorder).accessibilityLabel("搜索网络请求地址")
                Picker("方法", selection: $data.query.method) {
                    Text("全部方法").tag("")
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 90).accessibilityLabel("网络方法筛选")
                Picker("状态", selection: $data.query.status) {
                    Text("全部状态").tag(NetworkQuery.Status.all)
                    Text("进行中").tag(NetworkQuery.Status.pending)
                    Text("2xx").tag(NetworkQuery.Status.success)
                    Text("3xx").tag(NetworkQuery.Status.redirect)
                    Text("4xx").tag(NetworkQuery.Status.clientError)
                    Text("5xx").tag(NetworkQuery.Status.serverError)
                    Text("连接失败").tag(NetworkQuery.Status.failed)
                }.labelsHidden().frame(width: 90).accessibilityLabel("网络状态筛选")
            }
            if let error = data.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            GeometryReader { geometry in
                if geometry.size.width >= 800 {
                    HSplitView { requests.frame(minWidth: 380); details.frame(minWidth: 300) }
                } else {
                    VSplitView { requests.frame(minHeight: 110); details.frame(minHeight: 120) }
                }
            }.frame(minHeight: 250)
            HStack {
                Text("\(data.page.matching) / \(data.page.total) 条").monospacedDigit()
                Spacer(minLength: 0)
                Button { data.movePage(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(data.pageIndex == 0).accessibilityLabel("上一页网络请求")
                Text("\(data.pageIndex + 1) / \(max(1, (data.page.matching + NetworkPage.pageSize - 1) / NetworkPage.pageSize)) 页").monospacedDigit()
                Button { data.movePage(1) } label: { Image(systemName: "chevron.right") }
                    .disabled((data.pageIndex + 1) * NetworkPage.pageSize >= data.page.matching).accessibilityLabel("下一页网络请求")
            }.font(.caption).foregroundStyle(.secondary)
            Text("仅本机缓存 · 每个请求 / 响应正文最多 1 MB")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                .help("每次运行：最多 50,000 条摘要、数据库 32 MB、正文合计 128 MB。单次服务返回最多 8 MB。超限会标记或暂停接收，已缓存内容保留。支持 Dart VM 的 HTTP / HTTPS 扩展；WebView、Web 和 WebSocket 不在本版范围。")
        }.controlSize(.small)
            .task(id: session.id) { data.configure(directory: monitor.directory(session.id), sessionID: session.id) }
            .onChange(of: monitor.revision) { _, _ in data.refresh() }
            .onDisappear { data.stop() }
            .confirmationDialog("清理目标采集缓冲？", isPresented: $confirmingClear) {
                Button("清理目标缓冲", role: .destructive) { monitor.clearTargetBuffer(session.id) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会同时清理 DevTools 中的网络记录，并使正在进行的请求停止记录。Runbar 的本地历史缓存会保留。")
            }
    }
    private var requests: some View {
        Table(data.page.records, selection: $data.selectedID) {
            TableColumn("时间") { record in Text(Self.timeFormatter.string(from: record.startDate)).monospacedDigit() }.width(82)
            TableColumn("方法", value: \.method).width(52)
            TableColumn("地址", value: \.url).width(min: 80, ideal: 180, max: .infinity)
            TableColumn("状态") { record in Text(record.failure != nil ? "失败" : record.status.map(String.init) ?? "Pending") }.width(55)
            TableColumn("耗时") { record in Text(record.durationMS.map { String(format: "%.0f ms", $0) } ?? "—").monospacedDigit() }.width(65)
        }.font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            .overlay {
                if data.page.records.isEmpty {
                    Text(data.page.total == 0 ? "暂无已缓存请求\n开启采集后，需要运行支持 HTTP profiling 的 Dart / Flutter 程序" : "没有匹配的请求")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding().allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
    }
    private var details: some View {
        VStack(spacing: 5) {
            Picker("请求详情", selection: $data.detail) {
                ForEach(NetworkPanelModel.Detail.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("网络请求详情")
            NetworkTextView(text: data.bodyText).frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
            if data.detail == .request || data.detail == .response {
                HStack(spacing: 6) {
                    if data.loading { ProgressView().controlSize(.mini) }
                    Text(ByteCountFormatter.string(fromByteCount: Int64(data.bodyBytes), countStyle: .file))
                    Spacer()
                    Button { data.moveBody(-1) } label: { Image(systemName: "chevron.left") }.disabled(data.bodyIndex == 0)
                    Text("\(data.bodyIndex + 1) / \(data.bodyPages)")
                    Button { data.moveBody(1) } label: { Image(systemName: "chevron.right") }.disabled(data.bodyIndex + 1 >= data.bodyPages)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.top, 5)
    }
}

private struct NetworkTextView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.isAutomaticLinkDetectionEnabled = false; view.textContainerInset = NSSize(width: 8, height: 8)
        view.isHorizontallyResizable = true; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text; view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
