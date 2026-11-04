import SwiftUI
import AppKit
import RunbarCore

@MainActor
private final class ProxyWebSocketModel: ObservableObject {
    @Published var url = "" { didSet { if url != oldValue { resetConnections() } } }
    @Published var kind = "" { didSet { if kind != oldValue { resetMessages(delay: true) } } }
    @Published var follows = UserDefaults.standard.object(forKey: "proxyWebSocketFollows") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(follows, forKey: "proxyWebSocketFollows")
            if follows, !oldValue { visibleRow = Int.max; scrollsToLatest = true; scrollRevision += 1; refreshMessages() }
        }
    }
    @Published var format = NetworkBodyFormat(rawValue: UserDefaults.standard.string(forKey: "proxyWebSocketFormat") ?? "") ?? .json {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "proxyWebSocketFormat"); page = 0; loadDetail() }
    }
    @Published var metadata = false { didSet { page = 0; loadDetail() } }
    @Published private(set) var connections = ProxyWebSocketURLWindow.empty
    @Published private(set) var selectedURL: String?
    @Published private(set) var window = ProxyWebSocketWindow.empty
    @Published private(set) var selectedID: Int64?
    @Published private(set) var detail: ProxyWebSocketDetail?
    @Published private(set) var error: String?
    @Published private(set) var connectionRevision = 0
    @Published private(set) var scrollRevision = 0
    @Published private(set) var scrollsToLatest = true
    @Published private(set) var position = 100
    private let reader = ProxyWebSocketReader()
    private var directory: URL?
    private var connectionRow = 0
    private var visibleRow = Int.max
    private var page = 0
    private var connectionTask: Task<Void, Never>?
    private var windowTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    func configure(_ directory: URL) {
        stop(); self.directory = directory; resetConnections()
    }
    private func resetConnections() {
        connectionTask?.cancel(); connections = .empty; connectionRow = 0; connectionRevision += 1
        selectedURL = nil; resetMessages(); refreshConnections(delay: true)
    }
    private func resetMessages(delay: Bool = false) {
        windowTask?.cancel(); windowTask = nil
        detailTask?.cancel(); detailTask = nil
        visibleRow = Int.max; scrollsToLatest = true; selectedID = nil; detail = nil
        window = .empty; position = 100; page = 0; error = nil; scrollRevision += 1
        refreshMessages(delay: delay)
    }
    func refresh(periodic: Bool = false) {
        refreshConnections(periodic: periodic); refreshMessages(periodic: periodic)
    }
    private func refreshConnections(delay: Bool = false, periodic: Bool = false) {
        if periodic, connectionTask != nil { return }
        connectionTask?.cancel()
        guard let directory else { return }
        let filter = url, row = connectionRow
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay { try await Task.sleep(for: .milliseconds(180)) }
                let result = try await reader.connections(directory: directory, filter: filter, around: row)
                guard !Task.isCancelled else { return }
                if self.connections != result { self.connections = result }
                if self.selectedURL == nil, let first = result.urls.first { self.selectURL(first) }
                else if result.total == 0, self.selectedURL != nil { self.selectURL(nil) }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { self.connectionTask = nil }
        }
    }
    private func refreshMessages(delay: Bool = false, periodic: Bool = false) {
        if periodic, windowTask != nil { return }
        windowTask?.cancel()
        guard let directory, let selectedURL else { return }
        let kind = kind, row = follows ? Int.max : visibleRow
        windowTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay { try await Task.sleep(for: .milliseconds(180)) }
                let result = try await reader.messages(directory: directory, url: selectedURL, kind: kind, around: row)
                guard !Task.isCancelled, self.selectedURL == selectedURL, self.kind == kind else { return }
                if self.window != result { self.window = result }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { self.windowTask = nil }
        }
    }
    func connectionViewport(first: Int, last: Int, progress: Double) {
        connectionRow = first + max(0, last - first) / 2
        guard connections.total > 0 else { return }
        let lower = max(0, first - 16), upper = min(connections.total - 1, last + 16)
        if connections.url(at: lower) == nil || connections.url(at: upper) == nil { refreshConnections() }
    }
    func viewport(first: Int, last: Int, progress: Double) {
        let percent = Int((min(1, max(0, progress)) * 100).rounded())
        if position != percent { position = percent }
        visibleRow = first + max(0, last - first) / 2
        guard !follows, window.total > 0 else { return }
        let lower = max(0, first - 16), upper = min(window.total - 1, last + 16)
        if window.row(at: lower) == nil || window.row(at: upper) == nil { refreshMessages() }
    }
    func earliest() { follows = false; visibleRow = 0; scrollsToLatest = false; scrollRevision += 1; refreshMessages() }
    func latest() {
        scrollsToLatest = true; visibleRow = Int.max
        if !follows { follows = true } else { scrollRevision += 1; refreshMessages() }
    }
    func selectURL(_ url: String?) {
        guard selectedURL != url else { return }
        selectedURL = url; resetMessages()
    }
    func select(_ id: Int64?) {
        guard selectedID != id else { return }
        selectedID = id; page = 0
        if metadata { metadata = false } else { loadDetail() }
    }
    func movePage(_ delta: Int) { page = min(max(0, page + delta), max(0, (detail?.pages ?? 1) - 1)); loadDetail() }
    private func loadDetail() {
        detailTask?.cancel(); detail = nil
        guard let directory, let id = selectedID else { return }
        let format = format, metadata = metadata, page = page
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await reader.detail(directory: directory, id: id, metadata: metadata, format: format, page: page)
                guard !Task.isCancelled, self.selectedID == id else { return }
                self.detail = result
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func stop() {
        connectionTask?.cancel(); connectionTask = nil
        windowTask?.cancel(); windowTask = nil; detailTask?.cancel(); detailTask = nil
    }
}

struct ProxyWebSocketView: View {
    let directory: URL
    let sessionID: UUID
    let captureRevision: Date
    @StateObject private var data = ProxyWebSocketModel()
    @AppStorage("proxyWebSocketWraps") private var wraps = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("筛选 WebSocket 连接 URL", text: $data.url).textFieldStyle(.roundedBorder)
                Picker("消息方向", selection: $data.kind) {
                    Text("全部消息").tag(""); Text("发送").tag("send"); Text("接收").tag("receive")
                }.labelsHidden().frame(width: 95).accessibilityLabel("WebSocket 消息方向")
                Toggle("跟随", isOn: $data.follows).toggleStyle(.checkbox).fixedSize()
                    .help("跟随所选 URL 的最新消息；向上查看暂停跟随")
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
            Text("同 URL 的连接合并展示 · 消息从旧到新排列 · 单条消息最多保留 1 MB，截断会注明")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                .help("发送含业务订阅指令，接收含服务端推送。URL 与消息列表各最多保留 256 行；消息预览最多读取前 512 字节，选中后读取完整缓存正文的当前页。")
        }.controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: sessionID) { data.configure(directory) }
            .onChange(of: captureRevision) { _, _ in data.refresh(periodic: true) }
            .onDisappear { data.stop() }
    }
    private var connections: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("连接 URL").fontWeight(.semibold)
                Spacer(minLength: 0)
                Text("\(data.connections.total)").monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption).lineLimit(1).frame(height: 22)
            ProxySocketTable(rows: .connections(data.connections), selection: data.selectedURL.map(ProxySocketSelection.url),
                follows: false, revision: data.connectionRevision, latest: false,
                onSelect: { selection in if case .url(let url) = selection { data.selectURL(url) } else if selection == nil { data.selectURL(nil) } },
                onViewport: data.connectionViewport, onPause: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if data.connections.total == 0 {
                        empty("暂无 WebSocket 连接", hint: "WSS 需开启解密并信任证书")
                    }
                }.overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var messages: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("收发消息").fontWeight(.semibold).fixedSize()
                Text(data.selectedURL ?? "请选择连接 URL").foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(data.selectedURL ?? "")
                Spacer(minLength: 0)
            }.font(.caption).frame(height: 22)
            ProxySocketTable(rows: .messages(data.window), selection: data.selectedID.map(ProxySocketSelection.message),
                follows: data.follows, revision: data.scrollRevision, latest: data.scrollsToLatest,
                onSelect: { selection in if case .message(let id) = selection { data.select(id) } else if selection == nil { data.select(nil) } },
                onViewport: data.viewport, onPause: { data.follows = false })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if data.window.total == 0 {
                        empty(data.selectedURL == nil ? "选择左侧连接查看消息" : "暂无匹配的收发消息",
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
        Text("\(data.window.total) 条 · \(data.position)%").monospacedDigit().fixedSize()
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
                NetworkTextView(text: data.detail?.text ?? "正在读取…", wrapsLines: wraps)
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

private enum ProxySocketSelection: Equatable { case url(String), message(Int64) }
private enum ProxySocketRows: Equatable {
    case connections(ProxyWebSocketURLWindow), messages(ProxyWebSocketWindow)
    var total: Int { switch self { case .connections(let value): value.total; case .messages(let value): value.total } }
    var isConnections: Bool { if case .connections = self { true } else { false } }
    func selection(at row: Int) -> ProxySocketSelection? {
        switch self {
        case .connections(let value): return value.url(at: row).map(ProxySocketSelection.url)
        case .messages(let value): return value.row(at: row).map { .message($0.id) }
        }
    }
    func index(of selection: ProxySocketSelection?) -> Int? {
        switch (self, selection) {
        case (.connections(let value), .url(let url)): return value.urls.firstIndex(of: url).map { value.offset + $0 }
        case (.messages(let value), .message(let id)): return value.rows.firstIndex(where: { $0.id == id }).map { value.offset + $0 }
        default: return nil
        }
    }
}

/// Both tables own the full scroll range while retaining at most 256 URLs or
/// message summaries. Full payloads are never assigned to table cells.
private struct ProxySocketTable: NSViewRepresentable {
    let rows: ProxySocketRows
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
        let columns: [(String, String, Double)] = rows.isConnections ? [("url", "URL", 240)] :
            [("kind", "方向", 55), ("time", "时间", 105), ("preview", "消息", 360)]
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
                field.stringValue = window.url(at: row) ?? "正在读取…"; cell.toolTip = window.url(at: row)
            case .messages(let window):
                if let event = window.row(at: row) {
                    switch column.identifier.rawValue {
                    case "kind":
                        field.stringValue = event.kind.title
                        field.textColor = event.kind == .send ? .systemBlue : .systemGreen
                    case "time": field.stringValue = time.string(from: event.date)
                    default: field.stringValue = event.preview.isEmpty ? "（空消息）" : event.preview
                    }
                    cell.toolTip = "\(event.kind.title) · \(event.bytes) 字节 · 连接 \(event.flowID)\n\(event.note)"
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
