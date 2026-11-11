import SwiftUI
import AppKit
import RunbarCore

@MainActor
private final class ProxyWebSocketModel: ObservableObject {
    @Published var url = "" { didSet { if url != oldValue { resetConnections() } } }
    @Published var kind = "" { didSet { if kind != oldValue { resetMessages(delay: true) } } }
    @Published var filter = ProxyWebSocketModel.savedFilter() {
        didSet {
            guard filter != oldValue else { return }
            if (try? filter.validate()) != nil, let value = try? JSONEncoder().encode(filter) {
                UserDefaults.standard.set(value, forKey: "proxyWebSocketFilter")
            }
            resetMessages(delay: true)
        }
    }
    @Published var follows = UserDefaults.standard.object(forKey: "proxyWebSocketFollows") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(follows, forKey: "proxyWebSocketFollows")
            if follows, !oldValue {
                visibleRow = Int.max; viewportAnchorID = nil; scrollsToLatest = true; scrollRevision += 1
                selectLatestMessage(); refreshMessages()
            }
        }
    }
    @Published var format = NetworkBodyFormat(rawValue: UserDefaults.standard.string(forKey: "proxyWebSocketFormat") ?? "") ?? .json {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "proxyWebSocketFormat"); page = 0; loadDetail() }
    }
    @Published var metadata = false { didSet { page = 0; loadDetail() } }
    @Published var grouped = UserDefaults.standard.bool(forKey: "proxyWebSocketGroupByURL") {
        didSet {
            guard grouped != oldValue else { return }
            UserDefaults.standard.set(grouped, forKey: "proxyWebSocketGroupByURL")
            resetConnections()
        }
    }
    @Published private(set) var connections = ProxyWebSocketFlowWindow.empty
    @Published private(set) var selectedFlow: ProxyWebSocketFlow?
    var selectedURL: String? { selectedFlow?.url }
    private var running = false
    @Published private(set) var window = ProxyWebSocketWindow.empty
    @Published private(set) var selectedID: Int64?
    @Published private(set) var detail: ProxyWebSocketDetail?
    @Published private(set) var detailError: String?
    @Published private(set) var error: String?
    @Published private(set) var connectionRevision = 0
    @Published private(set) var scrollRevision = 0
    @Published private(set) var scrollsToLatest = true
    @Published private(set) var position = 100
    @Published private(set) var searching = false
    private let reader = ProxyWebSocketReader()
    private var directory: URL?
    private var connectionRow = 0
    private var visibleRow = Int.max
    private var viewportAnchorID: Int64?
    private var page = 0
    private var connectionTask: Task<Void, Never>?
    private var windowTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var searchRefreshTask: Task<Void, Never>?
    private static func savedFilter() -> ProxyWebSocketFilter {
        guard let data = UserDefaults.standard.data(forKey: "proxyWebSocketFilter"), data.count <= 512 * 1024,
              let filter = try? JSONDecoder().decode(ProxyWebSocketFilter.self, from: data),
              (try? filter.validate()) != nil else { return ProxyWebSocketFilter() }
        return filter
    }
    func configure(_ directory: URL, running: Bool) {
        stop(); self.directory = directory; self.running = running; resetConnections()
    }
    private func resetConnections() {
        connectionTask?.cancel(); connections = .empty; connectionRow = 0; connectionRevision += 1
        selectedFlow = nil; resetMessages(); refreshConnections(delay: true)
    }
    private func resetMessages(delay: Bool = false) {
        searchRefreshTask?.cancel(); searchRefreshTask = nil
        windowTask?.cancel(); windowTask = nil
        detailTask?.cancel(); detailTask = nil
        visibleRow = Int.max; viewportAnchorID = nil; scrollsToLatest = true; selectedID = nil; detail = nil; detailError = nil
        window = .empty; position = 100; page = 0; error = nil; scrollRevision += 1
        searching = selectedURL != nil && filter.isActive
        refreshMessages(delay: delay)
    }
    func updateRunning(_ running: Bool) {
        self.running = running
        refresh()
    }
    func refresh(periodic: Bool = false) {
        refreshConnections(periodic: periodic); refreshMessages(periodic: periodic)
    }
    private func refreshConnections(delay: Bool = false, periodic: Bool = false) {
        if periodic, connectionTask != nil { return }
        connectionTask?.cancel()
        guard let directory else { return }
        let filter = url, row = connectionRow, running = running, grouped = grouped
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay { try await Task.sleep(for: .milliseconds(180)) }
                let result = try await reader.flows(directory: directory, filter: filter, around: row, running: running, grouped: grouped)
                guard !Task.isCancelled else { return }
                if self.connections != result { self.connections = result }
                if let current = self.selectedFlow, let updated = result.rows.first(where: { $0.id == current.id }) {
                    if updated != current { self.selectedFlow = updated }
                } else if self.selectedFlow == nil, let first = result.rows.first { self.selectFlow(first) }
                else if result.total == 0 { self.selectFlow(nil) }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { self.connectionTask = nil }
        }
    }
    private func refreshMessages(delay: Bool = false, periodic: Bool = false) {
        if periodic, windowTask != nil { return }
        searchRefreshTask?.cancel(); searchRefreshTask = nil
        windowTask?.cancel()
        guard let directory, let selectedFlow else { return }
        let kind = kind, filter = filter, row = follows ? Int.max : visibleRow
        let anchorID = follows ? nil : viewportAnchorID
        windowTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay { try await Task.sleep(for: .milliseconds(180)) }
                let result = try await reader.messages(directory: directory, url: selectedFlow.url, kind: kind,
                    around: row, filter: filter, anchorID: anchorID, flowID: selectedFlow.isGroup ? nil : selectedFlow.id,
                    includeLifecycle: selectedFlow.isGroup)
                guard !Task.isCancelled, self.selectedFlow?.id == selectedFlow.id, self.kind == kind, self.filter == filter else { return }
                if self.window != result { self.window = result }
                self.selectLatestMessage()
                self.searching = !result.isComplete; self.error = nil
                if !result.isComplete {
                    self.searchRefreshTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        self?.searchRefreshTask = nil; self?.refreshMessages()
                    }
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; self.searching = false }
            }
            if !Task.isCancelled { self.windowTask = nil }
        }
    }
    func connectionViewport(first: Int, last: Int, progress: Double) {
        connectionRow = first + max(0, last - first) / 2
        guard connections.total > 0 else { return }
        let lower = max(0, first - 16), upper = min(connections.total - 1, last + 16)
        if connections.row(at: lower) == nil || connections.row(at: upper) == nil { refreshConnections() }
    }
    func viewport(first: Int, last: Int, progress: Double) {
        let percent = Int((min(1, max(0, progress)) * 100).rounded())
        if position != percent { position = percent }
        visibleRow = first + max(0, last - first) / 2
        viewportAnchorID = follows ? nil : window.row(at: first)?.id
        guard !follows, window.total > 0 else { return }
        let lower = max(0, first - 16), upper = min(window.total - 1, last + 16)
        if window.row(at: lower) == nil || window.row(at: upper) == nil { refreshMessages() }
    }
    func earliest() { follows = false; visibleRow = 0; viewportAnchorID = nil; scrollsToLatest = false; scrollRevision += 1; refreshMessages() }
    func latest() {
        scrollsToLatest = true; visibleRow = Int.max; viewportAnchorID = nil
        if !follows { follows = true } else { scrollRevision += 1; selectLatestMessage(); refreshMessages() }
    }
    func selectFlow(_ flow: ProxyWebSocketFlow?) {
        guard selectedFlow?.id != flow?.id else { return }
        selectedFlow = flow; resetMessages()
    }
    private func selectLatestMessage() {
        guard follows else { return }
        if window.total == 0 { select(nil); return }
        // A just-enabled follow may still hold a historical window. Select
        // only the actual last row after the latest window has been loaded.
        guard let latest = window.row(at: window.total - 1) else { return }
        select(latest.id, keepVisible: true)
    }
    func selectFromList(_ id: Int64?) {
        if follows, id != window.row(at: window.total - 1)?.id { follows = false }
        select(id)
    }
    private func select(_ id: Int64?, keepVisible: Bool = false) {
        guard selectedID != id else { return }
        selectedID = id; page = 0
        if metadata { metadata = false } else { loadDetail(keepVisible: keepVisible && id != nil) }
    }
    func movePage(_ delta: Int) { page = min(max(0, page + delta), max(0, (detail?.pages ?? 1) - 1)); loadDetail() }
    private func loadDetail(keepVisible: Bool = false) {
        detailTask?.cancel(); detailError = nil
        // Keep the previous body visible during a follow update, avoiding a
        // blank/loading flash on every captured batch. Stale reads are still
        // cancelled and cannot replace the newest selection's detail.
        if !keepVisible { detail = nil }
        guard let directory, let id = selectedID else { return }
        let format = format, metadata = metadata, page = page
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await reader.detail(directory: directory, id: id, metadata: metadata, format: format, page: page)
                guard !Task.isCancelled, self.selectedID == id else { return }
                self.detail = result
            } catch {
                if !Task.isCancelled {
                    self.detail = nil; self.detailError = error.localizedDescription; self.error = error.localizedDescription
                }
            }
        }
    }
    func stop() {
        searchRefreshTask?.cancel(); searchRefreshTask = nil
        connectionTask?.cancel(); connectionTask = nil
        windowTask?.cancel(); windowTask = nil; detailTask?.cancel(); detailTask = nil
        if let directory { Task { await reader.cancelSearch(directory: directory) } }
    }
}

struct ProxyWebSocketView: View {
    let directory: URL
    let sessionID: UUID
    let running: Bool
    @StateObject private var data = ProxyWebSocketModel()
    @State private var showingFilters = false
    @State private var sendTarget: ProxyWebSocketFlow?
    @AppStorage("proxyWebSocketWraps") private var wraps = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { groupingToggle; urlFilter; messageSearch; filterButton; direction; followToggle }
                VStack(spacing: 5) {
                    HStack(spacing: 8) { groupingToggle; urlFilter; direction; followToggle }
                    HStack(spacing: 8) { messageSearch; filterButton }
                }
            }.fixedSize(horizontal: false, vertical: true)
            if let error = data.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            GeometryReader { geometry in
                if geometry.size.width >= 880 {
                    HSplitView {
                        connections.frame(minWidth: 150, idealWidth: geometry.size.width * 0.22,
                                          maxWidth: .infinity, maxHeight: .infinity)
                        messages.frame(minWidth: 260, idealWidth: geometry.size.width * 0.38,
                                       maxWidth: .infinity, maxHeight: .infinity)
                        details.frame(minWidth: 280, idealWidth: geometry.size.width * 0.40,
                                      maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VSplitView {
                        HSplitView {
                            connections.frame(minWidth: 120, idealWidth: geometry.size.width * 0.32,
                                              maxWidth: .infinity, maxHeight: .infinity)
                            messages.frame(minWidth: 180, idealWidth: geometry.size.width * 0.68,
                                           maxWidth: .infinity, maxHeight: .infinity)
                        }.frame(maxWidth: .infinity, minHeight: 140,
                                idealHeight: geometry.size.height * 0.52, maxHeight: .infinity)
                        details.frame(maxWidth: .infinity, minHeight: 140,
                                      idealHeight: geometry.size.height * 0.48, maxHeight: .infinity)
                    }
                }
            }.frame(minHeight: 290)
            Text(data.grouped ? "按 URL 合并 · 建立和断开事件始终显示" : "按连接 ID 分开显示 · 单条消息最多保留 1 MB")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                .help("搜索范围为所选连接或 URL 下全部已缓存的收发消息，按当前方向筛选。JSON 搜索原文中的键或值；二进制搜索 Base64。连接与消息列表各最多保留 256 行，预览最多 512 字节。完整内容分块检索，命中序号临时保存在磁盘，条件自动保存。")
        }.controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: sessionID) {
                sendTarget = nil
                data.configure(directory, running: running)
            }
            .task(id: running) {
                guard running else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    data.refresh(periodic: true)
                }
            }
            .onChange(of: running) { _, value in data.updateRunning(value) }
            .onDisappear { data.stop() }
            .sheet(item: $sendTarget) { target in
                ProxyWebSocketComposer(directory: directory, target: target)
            }
    }
    private var groupingToggle: some View {
        Toggle("按 URL 合并", isOn: $data.grouped)
            .toggleStyle(.checkbox).fixedSize()
            .help("合并同一 URL 的连接，在收发列表中保留建立和断开事件")
    }
    private var urlFilter: some View {
        TextField("筛选连接 URL", text: $data.url).textFieldStyle(.roundedBorder).frame(minWidth: 160)
            .accessibilityLabel("筛选 WebSocket 连接 URL")
    }
    private var messageSearch: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索完整消息内容", text: $data.filter.search).textFieldStyle(.plain)
                .accessibilityLabel("搜索 WebSocket 完整消息内容")
            if !data.filter.search.isEmpty {
                Button { data.filter.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("清空 WebSocket 搜索")
            }
        }.padding(.horizontal, 6).padding(.vertical, 4).frame(minWidth: 190)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
            .help("按原始消息全文查找，不区分大小写，搜索内容自动保存")
    }
    private var direction: some View {
        Picker("消息方向", selection: $data.kind) {
            Text("全部消息").tag(""); Text("发送").tag("send"); Text("接收").tag("receive")
        }.labelsHidden().frame(width: 95).accessibilityLabel("WebSocket 消息方向")
    }
    private var followToggle: some View {
        Toggle("跟随", isOn: $data.follows).toggleStyle(.checkbox).fixedSize()
            .help("自动选中所选连接下符合当前条件的最新消息并更新右侧详情；向上滚动或选择历史消息暂停跟随")
    }
    private var filterButton: some View {
        Button(data.filter.conditionCount == 0 ? "筛选" : "筛选 \(data.filter.conditionCount)",
               systemImage: "line.3.horizontal.decrease") { showingFilters.toggle() }
            .fixedSize().accessibilityLabel("WebSocket 消息包含和排除筛选")
            .popover(isPresented: $showingFilters, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("消息筛选").font(.headline)
                        Spacer()
                        Button("清空") { data.filter = ProxyWebSocketFilter() }.disabled(!data.filter.isActive)
                    }
                    HStack {
                        Text("包含词关系")
                        Picker("包含词关系", selection: $data.filter.mode) {
                            ForEach(NetworkKeywordMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    HStack {
                        Text("包含").frame(width: 32, alignment: .leading)
                        TextField("如 subscribe, 行情", text: $data.filter.includes)
                    }
                    HStack {
                        Text("排除").frame(width: 32, alignment: .leading)
                        TextField("如 ping, heartbeat", text: $data.filter.excludes)
                    }
                    Text("逗号、分号或换行分隔多个词。先保留满足搜索和包含条件的消息，再剔除命中任一排除词的消息。只填排除词可直接隐藏心跳等消息。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("修改即时生效，自动记住。每组最多 16 个关键词，不区分大小写。检索原始缓存内容，JSON 可直接输入字段名或字段值。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(16).frame(width: 420).textFieldStyle(.roundedBorder).controlSize(.small)
            }
    }
    private var connections: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(data.grouped ? "连接 URL" : "WebSocket 连接").fontWeight(.semibold)
                Spacer(minLength: 0)
                Text("\(data.connections.total)").monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption).lineLimit(1).frame(height: 22)
            ProxySocketTable(rows: .connections(data.connections), grouped: data.grouped, selection: data.selectedFlow.map { .flow($0.id) },
                follows: false, revision: data.connectionRevision, latest: false,
                onSelect: { selection in if case .flow(let id) = selection { data.selectFlow(data.connections.rows.first { $0.id == id }) } else if selection == nil { data.selectFlow(nil) } },
                onViewport: data.connectionViewport, onPause: {})
                .id(data.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if data.connections.total == 0 {
                        empty("暂无 WebSocket 连接", hint: "WSS 需开启解密并信任证书")
                    }
                }.overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
            if let flow = data.selectedFlow, !flow.isGroup {
                Text(connectionTiming(flow))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .help(connectionTiming(flow))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var messages: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("收发消息").fontWeight(.semibold).fixedSize()
                Text(data.selectedURL ?? "请选择连接").foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(data.selectedURL ?? "")
                Spacer(minLength: 0)
                Button("发送消息", systemImage: "paperplane") { sendTarget = data.selectedFlow }
                    .disabled(!running || data.selectedFlow?.state != .connected)
            }.font(.caption).frame(height: 22)
            ProxySocketTable(rows: .messages(data.window), selection: data.selectedID.map(ProxySocketSelection.message),
                follows: data.follows, revision: data.scrollRevision, latest: data.scrollsToLatest,
                onSelect: { selection in if case .message(let id) = selection { data.selectFromList(id) } else if selection == nil { data.selectFromList(nil) } },
                onViewport: data.viewport, onPause: { data.follows = false })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if data.window.total == 0 {
                        empty(data.selectedURL == nil ? "选择左侧连接查看消息" : data.searching ? "正在检索完整缓存消息…" : "暂无匹配的收发消息",
                              hint: "每行单行预览，点击查看完整缓存内容")
                    }
                }.overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { messagePosition; Spacer(minLength: 0); messageNavigation }
                VStack(alignment: .leading, spacing: 3) {
                    messagePosition
                    HStack { Spacer(minLength: 0); messageNavigation }
                }
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var messagePosition: some View {
        HStack(spacing: 4) {
            if let total = data.window.sourceTotal { Text("\(data.window.total) / \(total) 条") }
            else { Text("\(data.window.total) 条") }
            Text("· \(data.position)%")
            if data.searching { Text("· 检索中") }
        }.monospacedDigit().fixedSize().help("检索中时显示已找到的结果，完成后为全部匹配数量")
    }
    private var messageNavigation: some View {
        HStack(spacing: 5) {
            Button("最早") { data.earliest() }.disabled(data.window.total == 0)
            Button("最新") { data.latest() }.disabled(data.window.total == 0)
        }.fixedSize()
    }
    private var details: some View {
        VStack(spacing: 5) {
            HStack {
                Text("消息详情").font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }.frame(height: 22)
            if data.selectedID == nil {
                empty("选择一条消息查看完整数据", hint: "默认 JSON 格式化，文本不换行")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("WebSocket 详情", selection: $data.metadata) {
                    Text("消息正文").tag(false); Text("连接 / Headers").tag(true)
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("WebSocket 详情")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { formatPicker; Spacer(minLength: 0); wrapToggle }
                    VStack(alignment: .leading, spacing: 4) {
                        formatPicker
                        HStack { Spacer(minLength: 0); wrapToggle }
                    }
                }.fixedSize(horizontal: false, vertical: true)
                NetworkTextView(text: data.detail?.text ?? data.detailError ?? "正在读取…", wrapsLines: wraps)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                if let detail = data.detail {
                    if !detail.note.isEmpty {
                        Text(detail.note).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(detail.note)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if detail.pages > 1 {
                        HStack {
                            Text("正文分页").font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button { data.movePage(-1) } label: { Image(systemName: "chevron.left") }.disabled(detail.page == 0)
                            Text("\(detail.page + 1) / \(detail.pages)").font(.caption).monospacedDigit()
                            Button { data.movePage(1) } label: { Image(systemName: "chevron.right") }.disabled(detail.page + 1 >= detail.pages)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var formatPicker: some View {
        Picker("消息格式", selection: $data.format) {
            ForEach([NetworkBodyFormat.json, .xml, .raw], id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 160).disabled(data.metadata)
            .accessibilityLabel("WebSocket 消息格式")
    }
    private var wrapToggle: some View {
        Toggle("自动换行", isOn: $wraps).toggleStyle(.checkbox).fixedSize()
    }
    private func empty(_ title: String, hint: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
            Text(hint).font(.system(size: 10))
        }.font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .padding(12).allowsHitTesting(false)
    }
}

private enum ProxySocketSelection: Equatable { case flow(String), message(Int64) }
private enum ProxySocketRows: Equatable {
    case connections(ProxyWebSocketFlowWindow), messages(ProxyWebSocketWindow)
    var total: Int { switch self { case .connections(let value): value.total; case .messages(let value): value.total } }
    var isConnections: Bool { if case .connections = self { true } else { false } }
    func selection(at row: Int) -> ProxySocketSelection? {
        switch self {
        case .connections(let value): return value.row(at: row).map { .flow($0.id) }
        case .messages(let value): return value.row(at: row).map { .message($0.id) }
        }
    }
    func index(of selection: ProxySocketSelection?) -> Int? {
        switch (self, selection) {
        case (.connections(let value), .flow(let id)): return value.rows.firstIndex(where: { $0.id == id }).map { value.offset + $0 }
        case (.messages(let value), .message(let id)): return value.rows.firstIndex(where: { $0.id == id }).map { value.offset + $0 }
        default: return nil
        }
    }
}

/// Both tables own the full scroll range while retaining at most 256 connections or
/// message summaries. Full payloads are never assigned to table cells.
private struct ProxySocketTable: NSViewRepresentable {
    let rows: ProxySocketRows
    var grouped = false
    let selection: ProxySocketSelection?
    let follows: Bool
    let revision: Int
    let latest: Bool
    let onSelect: (ProxySocketSelection?) -> Void
    let onViewport: (Int, Int, Double) -> Void
    let onPause: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ProxySocketScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder; scroll.autohidesScrollers = true
        let scroller = ProxySocketScroller()
        scroller.onUserScroll = { [weak coordinator = context.coordinator] in coordinator?.pauseFollowing() }
        scroll.verticalScroller = scroller
        scroll.onUserScroll = scroller.onUserScroll
        let table = ProxySocketTableView()
        table.onUserScroll = scroller.onUserScroll
        table.headerView = NSTableHeaderView(); table.rowHeight = 23
        table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        table.setAccessibilityLabel(rows.isConnections ? "WebSocket 连接 URL" : "WebSocket 收发消息（从旧到新，单行预览）")
        let columns: [(String, String, Double)]
        if rows.isConnections {
            columns = grouped ? [("state", "状态", 60), ("url", "URL", 240)] :
                [("state", "状态", 60), ("opened", "建立时间", 116), ("id", "连接 ID", 80), ("url", "URL", 240)]
        } else {
            columns = [("kind", "方向", 55), ("time", "时间", 105), ("preview", "消息", 360)]
        }
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title; column.width = width
            column.minWidth = identifier == "preview" ? 160 : identifier == "url" ? 120 : width
            column.resizingMask = identifier == "preview" || identifier == "url" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        scroll.documentView = table; scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scroll = scroll; context.coordinator.table = table
        context.coordinator.observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in
                MainActor.assumeIsolated { coordinator?.scheduleViewport() }
            }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator, previous = coordinator.parent
        coordinator.parent = self
        if follows && (!previous.follows || previous.revision != revision) { coordinator.userPaused = false }
        guard let table = coordinator.table else { return }
        coordinator.updating = true
        let previousVisible = table.rows(in: scroll.contentView.bounds)
        let previousFirst = previousVisible.location != NSNotFound && previousVisible.length > 0 ? previousVisible.location : nil
        let previousID: Int64? = previousFirst.flatMap { row in
            if case .message(let id) = previous.rows.selection(at: row) { return id }; return nil
        }
        let pixelOffset = previousFirst.map { scroll.contentView.bounds.minY - table.rect(ofRow: $0).minY } ?? 0
        let countChanged = table.numberOfRows != rows.total
        if countChanged { table.noteNumberOfRowsChanged() }
        if countChanged || rows != previous.rows {
            let visible = table.rows(in: scroll.contentView.bounds)
            if visible.location != NSNotFound, visible.length > 0 {
                let lower = max(0, visible.location), upper = min(rows.total, NSMaxRange(visible))
                if upper > lower { table.reloadData(forRowIndexes: IndexSet(integersIn: lower..<upper), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)) }
            }
        }
        if let index = rows.index(of: selection) {
            if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        } else if table.selectedRow >= 0 { table.deselectAll(nil) }
        let navigation = coordinator.revision != revision
        let reposition = !coordinator.positioned || navigation || (follows && !coordinator.userPaused && (countChanged || !previous.follows))
        coordinator.revision = revision
        if rows.total == 0 { coordinator.positioned = false }
        if rows.total > 0, reposition {
            coordinator.positioned = true
            table.layoutSubtreeIfNeeded(); table.scrollRowToVisible(latest ? rows.total - 1 : 0)
            // Defer once for the first real clip-view size after split layout.
            DispatchQueue.main.async { [weak coordinator, weak table] in
                guard let coordinator, let table, coordinator.parent.revision == revision,
                      coordinator.parent.follows == follows, !follows || !coordinator.userPaused, table.numberOfRows > 0 else { return }
                coordinator.updating = true
                table.layoutSubtreeIfNeeded(); table.scrollRowToVisible(latest ? table.numberOfRows - 1 : 0)
                coordinator.updating = false; coordinator.scheduleViewport()
            }
        } else if !follows, case .messages(let window) = rows, let anchor = window.anchorRow,
                  let previousID, window.row(at: anchor)?.id == previousID, anchor != previousFirst {
            // Older matches can be prepended while the initial search runs.
            // Keep the same message under the user's eyes as its rank changes.
            table.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX,
                y: table.rect(ofRow: anchor).minY + pixelOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        coordinator.updating = false; coordinator.scheduleViewport()
    }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let observation = coordinator.observation { NotificationCenter.default.removeObserver(observation) }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: ProxySocketTable
        weak var table: NSTableView?
        weak var scroll: NSScrollView?
        var observation: NSObjectProtocol?
        var updating = false, positioned = false, scheduled = false, userPaused = false
        var revision = -1
        private let time: DateFormatter = { let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"; return formatter }()
        init(_ parent: ProxySocketTable) { self.parent = parent }
        func pauseFollowing() { userPaused = true; if parent.follows { parent.onPause() } }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.total }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column else { return nil }
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView ?? NSTableCellView()
            if cell.textField == nil {
                cell.identifier = column.identifier
                let field = NSTextField(labelWithString: ""); field.translatesAutoresizingMaskIntoConstraints = false
                field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                field.maximumNumberOfLines = 1; field.cell?.wraps = false; field.cell?.usesSingleLineMode = true
                field.lineBreakMode = .byTruncatingTail
                cell.addSubview(field); cell.textField = field
                NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            guard let field = cell.textField else { return cell }
            field.textColor = .labelColor
            switch parent.rows {
            case .connections(let window):
                if let flow = window.row(at: row) {
                    switch column.identifier.rawValue {
                    case "state":
                        field.stringValue = flow.state.rawValue
                        field.textColor = flow.state == .connected ? .systemGreen : .secondaryLabelColor
                    case "opened":
                        field.stringValue = flow.openedAt?.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second()) ?? "—"
                    case "id": field.stringValue = String(flow.id.prefix(8))
                    default: field.stringValue = flow.url
                    }
                    cell.toolTip = flow.isGroup ? flow.url :
                        "\(flow.state.rawValue) · \(flow.id)\n\(flow.url)\n\(connectionTiming(flow))"
                } else {
                    field.stringValue = column.identifier.rawValue == "url" ? "正在读取…" : ""
                    cell.toolTip = nil
                }
            case .messages(let window):
                if let event = window.row(at: row) {
                    switch column.identifier.rawValue {
                    case "kind":
                        switch event.kind {
                        case .open: field.stringValue = "建立"; field.textColor = .systemTeal
                        case .close: field.stringValue = "断开"; field.textColor = .systemOrange
                        case .send: field.stringValue = "发送"; field.textColor = .systemBlue
                        case .receive: field.stringValue = "接收"; field.textColor = .systemGreen
                        }
                    case "time": field.stringValue = time.string(from: event.date)
                    default:
                        switch event.kind {
                        case .open: field.stringValue = "连接 \(event.flowID.prefix(8)) 已建立"
                        case .close:
                            field.stringValue = "连接 \(event.flowID.prefix(8)) 已断开" +
                                (event.note.isEmpty ? "" : " · " + event.note)
                        case .send, .receive:
                            field.stringValue = event.preview.isEmpty ? "（空消息）" : event.preview
                        }
                    }
                    cell.toolTip = "\(event.date.formatted()) · \(event.kind.title) · \(event.bytes) 字节 · 连接 \(event.flowID)\n\(event.note)"
                } else { field.stringValue = column.identifier.rawValue == "preview" ? "正在读取…" : ""; cell.toolTip = nil }
            }
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            if table.selectedRow < 0 { parent.onSelect(nil) }
            else if let selection = parent.rows.selection(at: table.selectedRow) { parent.onSelect(selection) }
            else { scheduleViewport() }
        }
        func scheduleViewport() {
            guard !scheduled else { return }; scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.scheduled = false
                guard let table = self.table, let scroll = self.scroll, self.parent.rows.total > 0 else { return }
                let range = table.rows(in: scroll.contentView.bounds)
                guard range.location != NSNotFound, range.length > 0 else { return }
                let first = max(0, range.location), last = min(self.parent.rows.total - 1, NSMaxRange(range) - 1)
                let travel = max(0, table.bounds.height - scroll.contentView.bounds.height)
                let progress = travel > 0 ? scroll.contentView.bounds.minY / travel : 1
                self.parent.onViewport(first, last, progress)
            }
        }
    }
}

private final class ProxySocketScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY > 0 { onUserScroll?() }
        super.scrollWheel(with: event)
    }
}
private final class ProxySocketTableView: NSTableView {
    var onUserScroll: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if [115, 116, 119, 121, 125, 126].contains(Int(event.keyCode)) { onUserScroll?() }
        super.keyDown(with: event)
    }
}
private final class ProxySocketScroller: NSScroller {
    var onUserScroll: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onUserScroll?(); super.mouseDown(with: event) }
    override func accessibilityPerformDecrement() -> Bool { onUserScroll?(); return super.accessibilityPerformDecrement() }
    override func accessibilityPerformIncrement() -> Bool { onUserScroll?(); return super.accessibilityPerformIncrement() }
}


private func connectionTiming(_ flow: ProxyWebSocketFlow) -> String {
    var fields = ["建立 " + (flow.openedAt?.formatted() ?? "未记录")]
    if flow.state == .closed {
        fields.append("断开 " + (flow.closedAt?.formatted() ?? "未记录"))
    }
    if let opened = flow.openedAt, let closed = flow.closedAt, closed >= opened {
        let seconds = closed.timeIntervalSince(opened)
        fields.append("持续 " + seconds.formatted(.number.precision(.fractionLength(0...2))) + " 秒")
    }
    if let code = flow.closeCode { fields.append("关闭码 \(code)") }
    if !flow.closeReason.isEmpty { fields.append(flow.closeReason) }
    return fields.joined(separator: " · ")
}

private struct ProxyWebSocketComposer: View {
    let directory: URL
    let target: ProxyWebSocketFlow
    @Environment(\.dismiss) private var dismiss
    @State private var activeTargets: [ProxyWebSocketTarget] = []
    @State private var selectedID = ""
    @State private var text = ""
    @State private var sending = false
    @State private var result = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("发送 WebSocket 消息").font(.headline)
            Text(target.url).font(.caption).textSelection(.enabled).lineLimit(2)
            if target.isGroup {
                HStack {
                    Picker("连接 ID", selection: $selectedID) {
                        Text("请选择活动连接").tag("")
                        ForEach(activeTargets) { item in Text(item.id).tag(item.id) }
                    }
                    Button("刷新") { refreshTargets() }
                }.disabled(sending)
            } else {
                Text("连接 ID \(target.id)").font(.caption).textSelection(.enabled)
            }
            Text("通过所选连接向服务器发送 UTF-8 文本 / JSON，最大 1 MB。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced))
                .border(Color(nsColor: .separatorColor)).frame(minHeight: 220).disabled(sending)
                .accessibilityLabel("待发送的 WebSocket 消息")
            Text(result).font(.caption).textSelection(.enabled)
            HStack {
                Text("\(text.utf8.count) 字节").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.disabled(sending)
                Button(sending ? "发送中…" : "发送") {
                    sending = true; result = ""
                    Task { @MainActor in
                        do {
                            try await ProxyWebSocketSender.send(directory: directory, flowID: target.isGroup ? selectedID : target.id, text: text)
                            result = "已提交发送，请在收发消息列表查看消息及服务器响应。"
                        } catch { result = error.localizedDescription }
                        sending = false
                    }
                }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(sending || (target.isGroup && selectedID.isEmpty) || text.isEmpty || text.utf8.count > 1024 * 1024)
            }
        }.padding(20).frame(width: 560)
            .onAppear { if target.isGroup { refreshTargets() } }
    }

    private func refreshTargets() {
        do {
            activeTargets = try ProxyWebSocketSender.connections(directory: directory).filter { $0.url == target.url }
            if !activeTargets.contains(where: { $0.id == selectedID }) {
                selectedID = activeTargets.count == 1 ? activeTargets[0].id : ""
            }
            result = activeTargets.isEmpty ? "该 URL 暂无活动连接" : ""
        } catch {
            activeTargets = []; selectedID = ""; result = error.localizedDescription
        }
    }
}
