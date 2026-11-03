import SwiftUI
import AppKit
import RunbarCore

@MainActor
private final class ProxyWebSocketModel: ObservableObject {
    @Published var url = "" { didSet { resetQuery() } }
    @Published var kind = "" { didSet { resetQuery() } }
    @Published var follows = UserDefaults.standard.object(forKey: "proxyWebSocketFollows") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(follows, forKey: "proxyWebSocketFollows")
            if follows { visibleRow = Int.max; scrollRevision += 1; refresh() }
        }
    }
    @Published var format = NetworkBodyFormat(rawValue: UserDefaults.standard.string(forKey: "proxyWebSocketFormat") ?? "") ?? .json {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "proxyWebSocketFormat"); page = 0; loadDetail() }
    }
    @Published var metadata = false { didSet { page = 0; loadDetail() } }
    @Published private(set) var window = ProxyWebSocketWindow.empty
    @Published private(set) var selectedID: Int64?
    @Published private(set) var detail: ProxyWebSocketDetail?
    @Published private(set) var error: String?
    @Published private(set) var scrollRevision = 0
    @Published private(set) var scrollsToLatest = true
    @Published private(set) var position = 100
    private let reader = ProxyWebSocketReader()
    private var directory: URL?
    private var visibleRow = Int.max
    private var page = 0
    private var windowTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    func configure(_ directory: URL) {
        stop(); self.directory = directory; window = .empty; selectedID = nil; detail = nil
        visibleRow = Int.max; scrollsToLatest = true; scrollRevision += 1; refresh()
    }
    private func resetQuery() {
        visibleRow = Int.max; scrollsToLatest = true; selectedID = nil; detail = nil
        window = .empty; scrollRevision += 1; refresh(delay: true)
    }
    func refresh(delay: Bool = false, periodic: Bool = false) {
        if periodic, windowTask != nil { return }
        windowTask?.cancel()
        guard let directory else { return }
        let url = url, kind = kind, row = follows ? Int.max : visibleRow
        windowTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay { try await Task.sleep(for: .milliseconds(180)) }
                let window = try await reader.window(directory: directory, url: url, kind: kind, around: row)
                guard !Task.isCancelled else { return }
                self.window = window; self.error = nil
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { self.windowTask = nil }
        }
    }
    func viewport(first: Int, last: Int, progress: Double) {
        position = Int((min(1, max(0, progress)) * 100).rounded())
        visibleRow = first + max(0, last - first) / 2
        guard !follows, window.total > 0 else { return }
        let lower = max(0, first - 16), upper = min(window.total - 1, last + 16)
        if window.row(at: lower) == nil || window.row(at: upper) == nil { refresh() }
    }
    func earliest() { follows = false; visibleRow = 0; scrollsToLatest = false; scrollRevision += 1; refresh() }
    func latest() {
        scrollsToLatest = true; visibleRow = Int.max
        if !follows { follows = true } else { scrollRevision += 1; refresh() }
    }
    func select(_ id: Int64?) { selectedID = id; page = 0; loadDetail() }
    func movePage(_ delta: Int) { page = min(max(0, page + delta), max(0, (detail?.pages ?? 1) - 1)); loadDetail() }
    private func loadDetail() {
        detailTask?.cancel(); detail = nil
        guard let directory, let id = selectedID else { return }
        let format = format, metadata = metadata, page = page
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await reader.detail(directory: directory, id: id, metadata: metadata, format: format, page: page)
                guard !Task.isCancelled, self.selectedID == id else { return }
                self.detail = detail; self.error = nil
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func stop() { windowTask?.cancel(); windowTask = nil; detailTask?.cancel(); detailTask = nil }
}

struct ProxyWebSocketView: View {
    let directory: URL
    let sessionID: UUID
    let captureRevision: Date
    @StateObject private var data = ProxyWebSocketModel()
    @AppStorage("proxyWebSocketWraps") private var wraps = false
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("筛选 WebSocket 地址或连接 ID", text: $data.url).textFieldStyle(.roundedBorder)
                Picker("事件", selection: $data.kind) {
                    Text("全部事件").tag("")
                    ForEach(ProxyWebSocketEvent.Kind.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().frame(width: 100)
                Toggle("跟随", isOn: $data.follows).toggleStyle(.checkbox).fixedSize()
            }
            if let error = data.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            GeometryReader { geometry in
                if geometry.size.width >= 800 {
                    HSplitView { events.frame(minWidth: 370); details.frame(minWidth: 300) }
                } else {
                    VSplitView { events.frame(minHeight: 120); details.frame(minHeight: 120) }
                }
            }.frame(minHeight: 250)
            HStack {
                Text("\(data.window.total) 个事件 · 当前位置 \(data.position)%").monospacedDigit()
                Spacer()
                Button("最早") { data.earliest() }.disabled(data.window.total == 0)
                Button("最新") { data.latest() }.disabled(data.window.total == 0)
            }.font(.caption).foregroundStyle(.secondary)
            Text("发送含业务订阅指令，接收含服务端推送 · 仅保存经过代理的消息 · 单消息最多保留 1 MB")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                .help("订阅是业务协议，不是 WebSocket 标准事件；按发送原文查看，不推断订阅是否成功。二进制按 Base64 显示。列表最多保留 256 条摘要；仅选中后读取正文。")
        }.controlSize(.small).task(id: sessionID) {
            data.configure(directory)
        }.onChange(of: captureRevision) { _, _ in data.refresh(periodic: true) }
            .onDisappear { data.stop() }
    }
    private var events: some View {
        ProxyWebSocketTable(window: data.window, selectedID: data.selectedID, follows: data.follows,
            revision: data.scrollRevision, latest: data.scrollsToLatest, onSelect: data.select,
            onViewport: data.viewport, onPause: { data.follows = false })
            .overlay {
                if data.window.total == 0 {
                    Text("暂无 WebSocket 事件\n连接后显示发送 / 订阅和接收 / 推送；WSS 需要开启 TLS 解密并信任证书")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding().allowsHitTesting(false)
                }
            }.overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
    }
    @ViewBuilder private var details: some View {
        if data.selectedID == nil {
            VStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right").font(.title2)
                Text("选择一条事件查看消息与连接信息").font(.caption)
            }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                Picker("WebSocket 详情", selection: $data.metadata) {
                    Text("消息").tag(false); Text("连接 / Headers").tag(true)
                }.pickerStyle(.segmented)
                HStack {
                    Picker("消息格式", selection: $data.format) {
                        ForEach(NetworkBodyFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 200).disabled(data.metadata)
                    Spacer()
                    Toggle("自动换行", isOn: $wraps).toggleStyle(.checkbox).fixedSize()
                }
                NetworkTextView(text: data.detail?.text ?? "正在读取…", wrapsLines: wraps)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                if let detail = data.detail {
                    HStack {
                        Text(detail.note).lineLimit(2).help(detail.note)
                        Spacer()
                        if detail.pages > 1 {
                            Button { data.movePage(-1) } label: { Image(systemName: "chevron.left") }.disabled(detail.page == 0)
                            Text("\(detail.page + 1) / \(detail.pages)")
                            Button { data.movePage(1) } label: { Image(systemName: "chevron.right") }.disabled(detail.page + 1 >= detail.pages)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 4)
        }
    }
}

/// All row geometry, only 256 row summaries. Dragging the scroller can address
/// any position in the local cache, rather than only the loaded page.
private struct ProxyWebSocketTable: NSViewRepresentable {
    let window: ProxyWebSocketWindow
    let selectedID: Int64?
    let follows: Bool
    let revision: Int
    let latest: Bool
    let onSelect: (Int64?) -> Void
    let onViewport: (Int, Int, Double) -> Void
    let onPause: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ProxySocketScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder; scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        let scroller = ProxySocketScroller()
        scroller.onUserScroll = { context.coordinator.pauseFollowing() }
        scroll.verticalScroller = scroller
        scroll.onUserScroll = { context.coordinator.pauseFollowing() }
        let table = ProxySocketTableView()
        table.onUserScroll = { context.coordinator.pauseFollowing() }
        table.headerView = NSTableHeaderView(); table.rowHeight = 23
        table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        for (identifier, title, width) in [("time", "时间", 105.0), ("kind", "事件", 65.0), ("connection", "连接 ID", 95.0), ("url", "地址", 360.0), ("bytes", "大小", 80.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title; column.width = width; column.minWidth = 50; table.addTableColumn(column)
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
        let coordinator = context.coordinator
        let previous = coordinator.parent
        coordinator.parent = self
        if follows && (!previous.follows || previous.revision != revision) { coordinator.userPaused = false }
        guard let table = coordinator.table else { return }
        coordinator.updating = true
        if table.numberOfRows != window.total { table.noteNumberOfRowsChanged() }
        let visible = table.rows(in: scroll.contentView.bounds)
        if visible.location != NSNotFound, visible.length > 0 {
            let lower = max(0, visible.location), upper = min(window.total, NSMaxRange(visible))
            if upper > lower { table.reloadData(forRowIndexes: IndexSet(integersIn: lower..<upper), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)) }
        }
        if let selectedID, let row = window.rows.firstIndex(where: { $0.id == selectedID }) {
            let index = window.offset + row
            if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        } else if selectedID == nil { table.deselectAll(nil) }
        let reposition = !coordinator.positioned || coordinator.revision != revision
        coordinator.revision = revision
        if window.total == 0 { coordinator.positioned = false }
        if window.total > 0, (follows && !coordinator.userPaused) || reposition {
            coordinator.positioned = true
            table.scrollRowToVisible(follows || latest ? window.total - 1 : 0)
        }
        coordinator.updating = false; coordinator.scheduleViewport()
    }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let observation = coordinator.observation { NotificationCenter.default.removeObserver(observation) }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: ProxyWebSocketTable
        weak var table: NSTableView?
        weak var scroll: NSScrollView?
        var observation: NSObjectProtocol?
        var updating = false, positioned = false, scheduled = false, userPaused = false
        var revision = -1
        private let time: DateFormatter = { let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"; return formatter }()
        init(_ parent: ProxyWebSocketTable) { self.parent = parent }
        func pauseFollowing() { userPaused = true; if parent.follows { parent.onPause() } }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.window.total }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column else { return nil }
            let field = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTextField) ?? NSTextField(labelWithString: "")
            field.identifier = column.identifier; field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.lineBreakMode = .byTruncatingMiddle
            guard let event = parent.window.row(at: row) else { field.stringValue = "…"; return field }
            switch column.identifier.rawValue {
            case "time": field.stringValue = time.string(from: event.date)
            case "kind": field.stringValue = event.kind.title
            case "connection": field.stringValue = String(event.flowID.prefix(8))
            case "url": field.stringValue = event.url
            default: field.stringValue = ByteCountFormatter.string(fromByteCount: event.bytes, countStyle: .file)
            }
            field.toolTip = column.identifier.rawValue == "url" ? event.url : column.identifier.rawValue == "connection" ? event.flowID : event.note
            return field
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let id = parent.window.row(at: table.selectedRow)?.id
            parent.onSelect(id)
        }
        func scheduleViewport() {
            guard !scheduled else { return }; scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.scheduled = false
                guard let table = self.table, let scroll = self.scroll, self.parent.window.total > 0 else { return }
                let range = table.rows(in: scroll.contentView.bounds)
                guard range.location != NSNotFound, range.length > 0 else { return }
                let first = max(0, range.location), last = min(self.parent.window.total - 1, range.location + range.length - 1)
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
