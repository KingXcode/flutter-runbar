import SwiftUI
import AppKit
import RunbarCore

@MainActor
private final class NetworkPanelModel: ObservableObject {
    enum Detail: String, CaseIterable { case overview = "概览", headers = "Headers", request = "Request", response = "Response" }
    @Published var query = NetworkQuery() { didSet {
        guard query != oldValue else { return }
        clearSelection(); window = .empty; visibleRow = 0; countsDirty = true
        scrollRevision += 1; refresh(delay: true)
    } }
    @Published private(set) var window = NetworkListWindow.empty
    @Published private(set) var selectedID: String?
    @Published private(set) var selectedRow: Int?
    @Published private(set) var selected: NetworkRecord?
    @Published private(set) var positionPercent = 100
    @Published private(set) var scrollRevision = 0
    @Published var followsOutput = UserDefaults.standard.object(forKey: "networkFollowsOutput") as? Bool ?? true {
        didSet {
            guard followsOutput != oldValue else { return }
            UserDefaults.standard.set(followsOutput, forKey: "networkFollowsOutput")
            if followsOutput { scrollRevision += 1; loadWindow() }
        }
    }
    @Published var detail = Detail.overview { didSet {
        bodyFormat = .raw; bodyIndex = 0; loadDetail()
    } }
    @Published private(set) var bodyFormat = NetworkBodyFormat.raw
    @Published private(set) var formatError: String?
    @Published private(set) var bodyText = "选择一条请求查看详情"
    @Published private(set) var bodyIndex = 0
    @Published private(set) var bodyPages = 1
    @Published private(set) var bodyBytes = 0
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private let reader = NetworkCacheReader()
    private var directory: URL?
    private var sessionID: UUID?
    private var visibleRow = 0
    private var countsDirty = true
    private var requestedRow: Int?
    private var windowTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    func configure(directory: URL?, sessionID: UUID) {
        if self.sessionID != sessionID {
            stop(); clearSelection(); window = .empty; visibleRow = 0; requestedRow = nil
            countsDirty = true; scrollRevision += 1
        }
        self.directory = directory; self.sessionID = sessionID; refresh()
    }
    func refresh(delay: Bool = false) {
        countsDirty = true; loadWindow(delay: delay)
    }
    private func loadWindow(delay: Bool = false, scrolling: Bool = false) {
        windowTask?.cancel()
        guard let directory else { return }
        let query = query, anchor = followsOutput ? Int.max : visibleRow, refreshCounts = countsDirty
        requestedRow = anchor
        windowTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay || scrolling { try await Task.sleep(for: .milliseconds(delay ? 250 : 25)) }
                let window = try await reader.listWindow(directory: directory, query: query, around: anchor, refreshCounts: refreshCounts)
                guard !Task.isCancelled else { return }
                self.window = window; self.countsDirty = false; self.requestedRow = nil; self.error = nil
                if let id = self.selectedID {
                    if let local = window.rows.firstIndex(where: { $0.id == id }) { self.selectedRow = window.offset + local }
                    let record = try await reader.request(directory: directory, id: id)
                    guard !Task.isCancelled, self.selectedID == id else { return }
                    if self.selected != record { self.selected = record; self.loadDetail() }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.requestedRow = nil; self.error = error.localizedDescription
            }
        }
    }
    func viewportChanged(first: Int, last: Int, progress: Double) {
        let percent = Int((min(1, max(0, progress)) * 100).rounded())
        if positionPercent != percent { positionPercent = percent }
        visibleRow = first + max(0, last - first) / 2
        guard !followsOutput, window.matching > 0 else { return }
        // Prefetch before reaching the edge, but don't restart the same disk
        // read on every pixel or on the redraw that fills placeholder cells.
        let padding = min(24, max(0, (NetworkListWindow.capacity - (last - first + 1)) / 4))
        let lower = max(0, first - padding), upper = min(window.matching - 1, last + padding)
        guard window.row(at: lower) == nil || window.row(at: upper) == nil else { return }
        let offset = min(max(0, visibleRow - NetworkListWindow.capacity / 2), max(0, window.matching - NetworkListWindow.capacity))
        guard offset != window.offset else { return }
        if let requestedRow, abs(requestedRow - visibleRow) < 32 { return }
        loadWindow(scrolling: true)
    }
    func earliest() { followsOutput = false; visibleRow = 0; scrollRevision += 1; loadWindow() }
    func latest() {
        if !followsOutput { followsOutput = true }
        else { scrollRevision += 1; loadWindow() }
    }
    func select(row: Int?) {
        selectionTask?.cancel(); selectedRow = row
        selectedID = nil; selected = nil; bodyFormat = .raw; bodyIndex = 0; loadDetail()
        guard let directory, let row else { return }
        let query = query, sessionID = sessionID
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let record = try await reader.request(directory: directory, query: query, row: row)
                guard !Task.isCancelled, self.sessionID == sessionID, self.query == query, self.selectedRow == row else { return }
                self.selectedID = record?.id; self.selected = record; self.loadDetail()
            } catch {
                guard !Task.isCancelled else { return }; self.error = error.localizedDescription
            }
        }
    }
    private func clearSelection() { select(row: nil) }
    func moveBody(_ delta: Int) { bodyIndex = min(max(0, bodyIndex + delta), bodyPages - 1); loadDetail() }
    func formatBody(_ format: NetworkBodyFormat) {
        bodyFormat = format; bodyIndex = 0; loadDetail()
    }
    private func loadDetail() {
        detailTask?.cancel(); loading = false; error = nil; formatError = nil
        guard let record = selected else { bodyText = "选择一条请求查看详情"; bodyPages = 1; bodyBytes = 0; return }
        bodyPages = 1; bodyBytes = 0
        switch detail {
        case .overview:
            let duration = record.durationMS.map { String(format: "%.1f ms", $0) } ?? (record.timingVersion == nil ? "旧版未记录完整响应耗时" : "响应尚未完成")
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
            let response = detail == .response, index = bodyIndex, format = bodyFormat
            detailTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let page: NetworkBodyPage
                    do { page = try await reader.body(directory: directory, record: record, response: response, page: index, format: format) }
                    catch {
                        guard !Task.isCancelled else { return }
                        guard format != .raw else { throw error }
                        self.formatError = error.localizedDescription; self.bodyFormat = .raw
                        page = try await reader.body(directory: directory, record: record, response: response, page: 0)
                    }
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
    func stop() { windowTask?.cancel(); selectionTask?.cancel(); detailTask?.cancel() }
}

struct NetworkPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: NetworkMonitor
    let session: RunSession
    @StateObject private var data = NetworkPanelModel()
    @State private var confirmingClear = false
    private var enabled: Bool { model.networkCaptureEnabled(for: session) }
    private var sourceExists: Bool {
        if let id = session.attachment?.application.id { return model.applications.contains { $0.id == id } }
        return model.config.projects.contains { $0.path == session.projectPath }
    }
    private var state: NetworkMonitor.State? { monitor.states[session.id] }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Toggle("网络采集", isOn: Binding(get: { enabled }, set: { value in
                    model.setNetworkCaptureEnabled(value, session: session)
                })).toggleStyle(.checkbox).fixedSize().disabled(!sourceExists)
                    .help("自动保存当前项目或应用的采集开关。暂停新增请求时，已记录的正文继续补齐；关闭开关停止读取，目标缓冲可能继续记录。")
                Text(state?.text ?? "本地历史缓存").font(.caption).foregroundStyle(state?.error == true ? .red : .secondary)
                    .lineLimit(1).help(state?.text ?? "已缓存的请求可在进程退出后查看")
                Spacer(minLength: 0)
                Toggle("跟随", isOn: $data.followsOutput).toggleStyle(.checkbox).fixedSize()
                    .help("跟随最新请求并滚动到底部；向上查看会暂停跟随")
                    .accessibilityLabel("跟随网络请求")
                if monitor.isLive(session.id), enabled, monitor.hasConnection(session.id) {
                    Button(state?.paused == true ? "继续" : "暂停") { monitor.togglePause(session.id) }
                        .help("暂停 / 恢复新增请求，已记录的正文继续补齐，选中的请求优先加载；目标缓冲仍可能增长")
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
                Text("\(data.window.matching) / \(data.window.total) 条").monospacedDigit()
                Text("当前位置 \(data.positionPercent)%").monospacedDigit()
                Spacer(minLength: 0)
                Button("最早") { data.earliest() }.disabled(data.window.matching == 0)
                    .accessibilityLabel("最早的网络请求")
                Button("最新") { data.latest() }.disabled(data.window.matching == 0)
                    .accessibilityLabel("最新的网络请求")
            }.font(.caption).foregroundStyle(.secondary)
            Text("完整列表按需读取 · 每个请求 / 响应正文最多 1 MB")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                .help("每次运行：最多 50,000 条摘要、数据库 32 MB、正文合计 128 MB。单次服务返回最多 8 MB。超限会标记或暂停接收，已缓存内容保留。支持 Dart VM 的 HTTP / HTTPS 扩展；WebView、Web 和 WebSocket 不在本版范围。")
        }.controlSize(.small)
            .task(id: session.id) { data.configure(directory: monitor.directory(session.id), sessionID: session.id) }
            .onChange(of: monitor.revision) { _, _ in data.refresh() }
            .onChange(of: data.selectedID) { _, id in
                if let id { monitor.prioritizeBody(id, sessionID: session.id) }
            }
            .onDisappear { data.stop() }
            .confirmationDialog("清理目标采集缓冲？", isPresented: $confirmingClear) {
                Button("清理目标缓冲", role: .destructive) { monitor.clearTargetBuffer(session.id) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会同时清理 DevTools 中的网络记录，并使正在进行的请求停止记录。Runbar 的本地历史缓存会保留。")
            }
    }
    private var requests: some View {
        NetworkRequestsTable(window: data.window, selection: data.selectedRow,
                             following: data.followsOutput, scrollRevision: data.scrollRevision,
                             onSelection: data.select, onViewport: data.viewportChanged) {
            data.followsOutput = false
        }
            .overlay {
                if data.window.matching == 0 {
                    Text(data.window.total == 0 ? "暂无已缓存请求\n开启采集后，需要运行支持 HTTP profiling 的 Dart / Flutter 程序" : "没有匹配的请求")
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
            if data.detail == .response {
                HStack(spacing: 5) {
                    Button("JSON 格式化") { data.formatBody(.json) }
                        .tint(data.bodyFormat == .json ? .accentColor : .secondary)
                        .accessibilityValue(data.bodyFormat == .json ? "已启用" : "未启用")
                    Button("XML 格式化") { data.formatBody(.xml) }
                        .tint(data.bodyFormat == .xml ? .accentColor : .secondary)
                        .accessibilityValue(data.bodyFormat == .xml ? "已启用" : "未启用")
                    Button("原始") { data.formatBody(.raw) }.disabled(data.bodyFormat == .raw)
                    Spacer(minLength: 0)
                }.disabled(data.selected?.bodyState != .saved || data.loading)
                    .help("在后台格式化完整响应并分页显示，保留原始正文；最多读取 1 MB")
            }
            if let error = data.formatError { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(error) }
            NetworkTextView(text: data.bodyText).frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
            if let selected = data.selected, data.detail == .request || data.detail == .response {
                HStack(spacing: 6) {
                    if data.loading || monitor.loadingBodies.contains(selected.id) { ProgressView().controlSize(.mini) }
                    if selected.bodyState == .saved {
                        Text(data.bodyBytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(data.bodyBytes), countStyle: .file))
                    } else if let error = monitor.bodyErrors[selected.id] {
                        Text(error).lineLimit(1).help(error)
                    } else {
                        Text(selected.bodyState == .pending ? "等待正文，选中后优先加载" : selected.bodyState.title)
                    }
                    Spacer()
                    if selected.bodyState == .saved {
                        Button { data.moveBody(-1) } label: { Image(systemName: "chevron.left") }.disabled(data.bodyIndex == 0)
                        Text("\(data.bodyIndex + 1) / \(data.bodyPages)")
                        Button { data.moveBody(1) } label: { Image(systemName: "chevron.right") }.disabled(data.bodyIndex + 1 >= data.bodyPages)
                    } else if monitor.hasConnection(session.id), enabled {
                        Button("重新获取") { monitor.prioritizeBody(selected.id, sessionID: session.id) }
                            .disabled(monitor.loadingBodies.contains(selected.id))
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.top, 5)
    }
}

/// The native table owns the full scroll geometry, while the data source holds
/// only a small window. Offscreen rows never create views or retain headers.
private struct NetworkRequestsTable: NSViewRepresentable {
    let window: NetworkListWindow
    let selection: Int?
    let following: Bool
    let scrollRevision: Int
    let onSelection: (Int?) -> Void
    let onViewport: (Int, Int, Double) -> Void
    let onScrollAway: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NetworkRequestsScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let table = NetworkRequestTableView()
        table.setAccessibilityLabel("网络请求列表（完整历史，从旧到新）")
        table.rowHeight = 23; table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (key, title, width) in [("time", "时间", 100.0), ("method", "方法", 60.0), ("url", "地址", 260.0),
                                     ("status", "状态", 60.0), ("duration", "耗时", 70.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); column.title = title
            column.width = width; column.minWidth = key == "url" ? 100 : width
            column.resizingMask = key == "url" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        scroll.documentView = table
        scroll.onScrollAway = { [weak coordinator = context.coordinator] in coordinator?.pauseFollowing() }
        table.onScrollAway = scroll.onScrollAway
        context.coordinator.observe(scroll)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator, old = coordinator.parent
        coordinator.parent = self; coordinator.applying = true
        let countChanged = !coordinator.initialized || table.numberOfRows != window.matching
        coordinator.initialized = true
        if countChanged { table.reloadData() }
        else if old.window != window {
            let rows = table.rows(in: scroll.documentVisibleRect)
            if rows.location != NSNotFound, rows.length > 0 {
                table.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<min(window.matching, NSMaxRange(rows))),
                                 columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
        }
        if let selection, selection >= 0, selection < window.matching {
            if table.selectedRow != selection { table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false) }
        } else if table.selectedRow >= 0 { table.deselectAll(nil) }
        let navigation = old.scrollRevision != scrollRevision
        if window.matching > 0 && (navigation || (following && (countChanged || !old.following))) {
            table.layoutSubtreeIfNeeded()
            table.scrollRowToVisible(following ? window.matching - 1 : 0)
            // SwiftUI may resize the initial clip view after this update.
            let revision = scrollRevision
            DispatchQueue.main.async { [weak table, weak coordinator] in
                guard let table, let coordinator, coordinator.parent.scrollRevision == revision,
                      coordinator.parent.following == following, table.numberOfRows > 0 else { return }
                coordinator.applying = true
                table.layoutSubtreeIfNeeded(); table.scrollRowToVisible(following ? table.numberOfRows - 1 : 0)
                coordinator.applying = false; coordinator.reportViewport()
            }
        }
        coordinator.applying = false; coordinator.reportViewport()
    }
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: NetworkRequestsTable
        var applying = false
        var initialized = false
        private weak var scroll: NSScrollView?
        private var observation: NSObjectProtocol?
        private var reportPending = false
        private static let formatter: DateFormatter = {
            let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX")
            value.dateFormat = "HH:mm:ss.SSS"; return value
        }()
        init(_ parent: NetworkRequestsTable) { self.parent = parent }
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
        func observe(_ scroll: NSScrollView) {
            self.scroll = scroll; scroll.contentView.postsBoundsChangedNotifications = true
            observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                 object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                guard let self, let scroll, !self.applying else { return }
                if self.parent.following, NSApp.currentEvent?.type == .leftMouseDragged,
                   let document = scroll.documentView, scroll.contentView.bounds.maxY < document.bounds.maxY - 2 {
                    self.pauseFollowing()
                }
                self.reportViewport()
            }
        }
        func reportViewport() {
            guard !reportPending else { return }; reportPending = true
            // Defer callbacks out of updateNSView and coalesce AppKit layout
            // notifications, keeping SwiftUI state mutations outside rendering.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.reportPending = false
                guard let scroll = self.scroll, let table = scroll.documentView as? NSTableView, table.numberOfRows > 0 else { return }
                let rows = table.rows(in: scroll.documentVisibleRect)
                guard rows.location != NSNotFound, rows.length > 0 else { return }
                let range = max(0, table.bounds.height - scroll.contentView.bounds.height)
                let progress = range > 0 ? (scroll.contentView.bounds.minY - table.bounds.minY) / range : 1
                // Scroller accessibility actions have no mouse-drag event.
                // Treat any settled viewport away from the tail as browsing,
                // after deferred programmatic following has finished.
                if self.parent.following, range > 0, progress < 1 - 2 / range {
                    self.pauseFollowing()
                }
                self.parent.onViewport(rows.location, min(table.numberOfRows - 1, NSMaxRange(rows) - 1), Double(progress))
            }
        }
        func pauseFollowing() { if parent.following && !applying { parent.onScrollAway() } }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.window.matching }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table = notification.object as? NSTableView else { return }
            parent.onSelection(table.selectedRow >= 0 ? table.selectedRow : nil)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn else { return nil }
            let id = column.identifier
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? NSTableCellView()
            if cell.textField == nil {
                cell.identifier = id
                let field = NSTextField(labelWithString: ""); field.translatesAutoresizingMaskIntoConstraints = false
                field.font = .monospacedSystemFont(ofSize: 11, weight: .regular); field.lineBreakMode = .byTruncatingMiddle
                cell.addSubview(field); cell.textField = field
                NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                                             field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                                             field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            let value: String
            if let record = parent.window.row(at: row) {
                switch id.rawValue {
                case "time": value = Self.formatter.string(from: record.startDate)
                case "method": value = record.method
                case "url": value = record.url
                case "status": value = record.failed ? "失败" : record.status.map(String.init) ?? "Pending"
                default: value = record.durationMS.map { String(format: "%.0f ms", $0) } ?? "—"
                }
            } else { value = id.rawValue == "url" ? "正在读取…" : "" }
            cell.textField?.stringValue = value; cell.toolTip = value
            return cell
        }
    }
}

private final class NetworkRequestsScrollView: NSScrollView {
    var onScrollAway: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY > 0 { onScrollAway?() }
        super.scrollWheel(with: event)
    }
}
private final class NetworkRequestTableView: NSTableView {
    var onScrollAway: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if [115, 116, 126].contains(event.keyCode) { onScrollAway?() } // Home, Page Up, Up
        super.keyDown(with: event)
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
