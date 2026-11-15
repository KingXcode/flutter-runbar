import SwiftUI
import AppKit
import RunbarCore

@MainActor
private final class NetworkPanelModel: ObservableObject {
    typealias Detail = NetworkDetailSection
    @Published var query = NetworkQuery() { didSet {
        guard !query.hasSameConditions(as: oldValue) else { return }
        scheduleFilterSave()
        clearSelection(); window = .empty; visibleRow = Int.max; firstVisibleRow = nil; viewportAnchorID = nil; scrollsToLatest = true; countsDirty = true
        scrollRevision += 1; refresh(delay: true)
    } }
    @Published private(set) var window = NetworkListWindow.empty
    @Published private(set) var selectedID: String?
    @Published private(set) var selectedRow: Int?
    @Published private(set) var selected: NetworkRecord?
    @Published private(set) var positionPercent = 100
    @Published private(set) var scrollRevision = 0
    @Published private(set) var scrollsToLatest = true
    @Published var followsOutput = UserDefaults.standard.object(forKey: "networkFollowsOutput") as? Bool ?? true {
        didSet {
            guard followsOutput != oldValue else { return }
            UserDefaults.standard.set(followsOutput, forKey: "networkFollowsOutput")
            if followsOutput { scrollsToLatest = true; firstVisibleRow = nil; viewportAnchorID = nil; scrollRevision += 1; loadWindow() }
        }
    }
    @Published var detail = Detail.overview { didSet { bodyIndex = 0; loadDetail() } }
    @Published private(set) var preferences = UserDefaults.standard.data(forKey: "networkDetailPreferences")
        .flatMap { try? JSONDecoder().decode(NetworkDetailPreferences.self, from: $0) } ?? NetworkDetailPreferences()
    var bodyFormat: NetworkBodyFormat { preferences.format(for: detail) }
    var showsURLParameters: Bool { detail == .request && selected?.requestBytes == 0 &&
        selected.flatMap { URLComponents(string: $0.url)?.queryItems }?.isEmpty == false }
    @Published private(set) var formatError: String?
    @Published private(set) var bodyText = "选择一条请求查看详情"
    @Published private(set) var bodyAnnotations: [ResponseRewriteAnnotation] = []
    @Published var responseVersion = ResponseRewriteBodyVersion.client { didSet { bodyIndex = 0; loadDetail() } }
    @Published var tableMode = false { didSet { bodyIndex = 0; loadDetail() } }
    @Published private(set) var rewriteTargets: [ResponseRewriteTarget] = []
    @Published private(set) var responseTables: [ResponseRewriteTable] = []
    @Published private(set) var tableChanges: [String: [ResponseRewriteChange]] = [:]
    @Published var selectedTablePath = ""
    @Published private(set) var bodyIndex = 0
    @Published private(set) var bodyPages = 1
    @Published private(set) var bodyBytes = 0
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var queryLoading = false
    @Published private(set) var filterPreferences = NetworkFilterPreferences()
    @Published private(set) var filterSaveError: String?
    private static let filterPreferencesKey = "networkFilterPreferences"
    private var filterSaveTask: Task<Void, Never>?
    private var filtersDirty = false
    private let reader = NetworkCacheReader()
    private var directory: URL?
    private var sessionID: UUID?
    private var visibleRow = Int.max
    private(set) var firstVisibleRow: Int?
    private var viewportAnchorID: String?
    private var countsDirty = true
    private var requestedRow: Int?
    private var windowTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var searchRefreshTask: Task<Void, Never>?
    init() {
        guard let bytes = UserDefaults.standard.data(forKey: Self.filterPreferencesKey) else { return }
        do {
            let saved = try NetworkFilterPreferences.load(bytes)
            filterPreferences = saved; query = saved.query
        } catch { filterSaveError = "无法读取已保存的网络筛选：\(error.localizedDescription)" }
    }
    private func scheduleFilterSave() {
        filtersDirty = true; filterSaveTask?.cancel()
        filterSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.savePendingFilters()
        }
    }
    private func writeFilters(_ preferences: NetworkFilterPreferences) throws {
        let bytes = try preferences.data()
        UserDefaults.standard.set(bytes, forKey: Self.filterPreferencesKey)
        filterPreferences = preferences; filterSaveError = nil; filtersDirty = false
    }
    private func savePendingFilters() {
        guard filtersDirty else { return }
        do {
            var next = filterPreferences; try next.remember(query)
            try writeFilters(next)
        } catch { filterSaveError = "网络筛选未保存：\(error.localizedDescription)" }
    }
    func saveFilterPreset(_ name: String) -> Bool {
        do {
            var next = filterPreferences; try next.savePreset(name: name, query: query)
            try writeFilters(next); query = next.query
            return true
        } catch { filterSaveError = error.localizedDescription; return false }
    }
    func useFilterPreset(_ id: UUID) -> Bool {
        do {
            var next = filterPreferences; try next.usePreset(id)
            try writeFilters(next); query = next.query
            return true
        } catch { filterSaveError = error.localizedDescription; return false }
    }
    func removeFilterPreset(_ id: UUID) {
        do {
            var next = filterPreferences; next.removePreset(id)
            try writeFilters(next)
            // Deleting a saved scheme leaves the live filter untouched, including
            // any edits that have not reached the debounced auto-save yet.
            scheduleFilterSave()
        } catch { filterSaveError = error.localizedDescription }
    }
    func configure(directory: URL?, sessionID: UUID) {
        if self.sessionID != sessionID {
            stop(); clearSelection(); window = .empty; visibleRow = Int.max; firstVisibleRow = nil; viewportAnchorID = nil; scrollsToLatest = true; requestedRow = nil
            countsDirty = true; scrollRevision += 1
        }
        self.directory = directory; self.sessionID = sessionID; refresh()
    }
    func refresh(delay: Bool = false) {
        countsDirty = true; loadWindow(delay: delay)
    }
    private func loadWindow(delay: Bool = false, scrolling: Bool = false) {
        windowTask?.cancel()
        searchRefreshTask?.cancel(); searchRefreshTask = nil
        guard let directory else { return }
        queryLoading = true
        let query = query, anchor = followsOutput ? Int.max : visibleRow, refreshCounts = countsDirty
        let anchorID = followsOutput ? nil : viewportAnchorID
        requestedRow = anchor
        windowTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay || scrolling { try await Task.sleep(for: .milliseconds(delay ? 250 : 25)) }
                let window = try await reader.listWindow(directory: directory, query: query, around: anchor, refreshCounts: refreshCounts, anchorID: anchorID)
                guard !Task.isCancelled else { return }
                self.window = window; self.countsDirty = false; self.requestedRow = nil; self.error = nil; self.queryLoading = false
                if !window.counts.isComplete {
                    self.searchRefreshTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                        self?.searchRefreshTask = nil; self?.loadWindow()
                    }
                }
                if let id = self.selectedID {
                    self.selectedRow = window.rows.firstIndex(where: { $0.id == id }).map { window.offset + $0 }
                    let record = try await reader.request(directory: directory, id: id)
                    guard !Task.isCancelled, self.selectedID == id else { return }
                    if self.selected != record { self.selected = record; self.loadDetail() }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.requestedRow = nil; self.error = error.localizedDescription; self.queryLoading = false
            }
        }
    }
    func viewportChanged(first: Int, last: Int, progress: Double) {
        firstVisibleRow = window.matching > 0 ? min(max(0, first), window.matching - 1) : nil
        let percent = Int((min(1, max(0, progress)) * 100).rounded())
        if positionPercent != percent { positionPercent = percent }
        visibleRow = first + max(0, last - first) / 2
        viewportAnchorID = followsOutput ? nil : window.row(at: first)?.id
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
    func earliest() { followsOutput = false; visibleRow = 0; firstVisibleRow = 0; viewportAnchorID = nil; scrollsToLatest = false; scrollRevision += 1; loadWindow() }
    func latest() {
        visibleRow = Int.max; firstVisibleRow = nil; viewportAnchorID = nil; scrollsToLatest = true
        if !followsOutput { followsOutput = true }
        else { scrollRevision += 1; loadWindow() }
    }
    func select(row: Int?) {
        selectionTask?.cancel(); selectedRow = row
        selectedID = nil; selected = nil; bodyIndex = 0; loadDetail()
        guard let directory, let row else { return }
        let query = query, sessionID = sessionID
        let visibleID = window.row(at: row)?.id
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let record: NetworkRecord?
                if let visibleID { record = try await reader.request(directory: directory, id: visibleID) }
                else { record = try await reader.request(directory: directory, query: query, row: row) }
                guard !Task.isCancelled, self.sessionID == sessionID, self.query.hasSameConditions(as: query), self.selectedRow == row else { return }
                self.selectedID = record?.id; self.selected = record; self.loadDetail()
            } catch {
                guard !Task.isCancelled else { return }; self.error = error.localizedDescription
            }
        }
    }
    private func clearSelection() { select(row: nil) }
    func moveBody(_ delta: Int) { bodyIndex = min(max(0, bodyIndex + delta), bodyPages - 1); loadDetail() }
    func formatBody(_ format: NetworkBodyFormat) {
        preferences.setFormat(format, for: detail); savePreferences(); bodyIndex = 0; loadDetail()
    }
    func setWrapsLines(_ value: Bool) { preferences.wrapsLines = value; savePreferences() }
    private func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "networkDetailPreferences") }
    }
    func clearFieldFilters() {
        var value = query; value.clearFieldFilters(); query = value
    }
    private func loadDetail() {
        detailTask?.cancel(); loading = false; error = nil; formatError = nil
        bodyAnnotations = []; responseTables = []; tableChanges = [:]; rewriteTargets = []
        guard let record = selected else { bodyText = "选择一条请求查看详情"; bodyPages = 1; bodyBytes = 0; return }
        bodyPages = 1; bodyBytes = 0
        guard let directory else { return }
        loading = true; bodyText = "正在读取内容…"
        let section = detail, index = bodyIndex, format = bodyFormat, parameters = showsURLParameters
        let version = responseVersion, wantsTable = tableMode && section == .response && version != .changes
        detailTask = Task { [weak self] in
            guard let self else { return }
            func read(_ format: NetworkBodyFormat) async throws -> NetworkBodyPage {
                if section == .overview || section == .headers || parameters {
                    return try await reader.metadata(record: record, section: section, format: format, page: index)
                }
                return try await reader.body(directory: directory, record: record, response: section == .response, page: index,
                                             format: format, version: section == .response ? version : .client)
            }
            do {
                if wantsTable {
                    let bytes = try await reader.bodyData(directory: directory, record: record, response: true, version: version)
                    let tables = try await Task.detached(priority: .utility) { try ResponseRewritePresentation.tables(in: bytes) }.value
                    var changesByCell: [String: [ResponseRewriteChange]] = [:]
                    do {
                        if version == .client, let artifact = try await reader.rewriteArtifact(directory: directory, record: record) {
                            changesByCell = try await Task.detached(priority: .utility) {
                                try ResponseRewritePresentation.tableChanges(in: bytes, artifact: artifact)
                            }.value
                        }
                    }
                    catch {
                        guard !Task.isCancelled else { return }
                        guard version == .client else { throw error }
                        self.formatError = "改写记录未完整缓存：\(error.localizedDescription)"
                    }
                    guard !Task.isCancelled else { return }
                    self.responseTables = tables; self.tableChanges = changesByCell
                    if !tables.contains(where: { $0.path == self.selectedTablePath }) { self.selectedTablePath = tables.first?.path ?? "" }
                    self.bodyBytes = bytes.count; self.bodyText = tables.isEmpty ? "未识别到表头数组，请切换 JSON 查看。" : ""
                    self.loading = false; return
                }
                let page: NetworkBodyPage
                do { page = try await read(format) }
                catch {
                    guard !Task.isCancelled else { return }
                    guard format != .raw, error is RunbarError else { throw error }
                    let reason = error.localizedDescription
                    page = try await read(.raw)
                    guard !Task.isCancelled else { return }
                    self.formatError = reason + " 当前按原始内容显示，格式偏好保持不变。"
                }
                guard !Task.isCancelled else { return }
                self.bodyText = page.text; self.bodyIndex = page.page; self.bodyPages = page.pages; self.bodyBytes = page.bytes; self.loading = false
                self.bodyAnnotations = page.annotations
                self.rewriteTargets = section == .response ? page.rewriteTargets : []
                if let note = page.rewriteNote { self.formatError = [self.formatError, note].compactMap { $0 }.joined(separator: " ") }
            } catch {
                guard !Task.isCancelled else { return }
                self.bodyText = error.localizedDescription; self.loading = false
            }
        }
    }
    func rewriteSample(recordID: String, showError: Bool = true) async -> ResponseRewriteSample? {
        guard let directory else { return nil }
        let expectedSession = sessionID
        do {
            // A context menu belongs to the clicked request, even if the live
            // list or selection changes while its sample is being read.
            guard let record = try await reader.request(directory: directory, id: recordID) else {
                throw RunbarError.message("该请求已不存在。")
            }
            let request = try await reader.bodyData(directory: directory, record: record, response: false, version: .client)
            let response = try await reader.bodyData(directory: directory, record: record, response: true,
                                                     version: record.rewrite?.state == .changed ? .original : .client)
            guard !Task.isCancelled, sessionID == expectedSession, self.directory == directory else { return nil }
            return ResponseRewriteSample(method: record.method, url: record.url, requestBody: request, responseBody: response)
        } catch {
            guard !Task.isCancelled, sessionID == expectedSession, self.directory == directory else { return nil }
            if showError { self.error = "无法读取规则样本：\(error.localizedDescription)" }
            return nil
        }
    }
    func stop() {
        filterSaveTask?.cancel(); filterSaveTask = nil; savePendingFilters()
        windowTask?.cancel(); selectionTask?.cancel(); detailTask?.cancel(); searchRefreshTask?.cancel()
        let directory = directory
        Task { await reader.cancelContentSearch(directory: directory) }
    }
}

private enum NetworkPanelLayout: String {
    case horizontal, vertical
}

private struct NetworkRewriteEditorRequest: Identifiable {
    let id = UUID()
    let projectID: UUID
    let sample: ResponseRewriteSample?
    let action: ResponseRewriteAction?
    let ruleID: UUID?
}

struct NetworkPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: NetworkMonitor
    let session: RunSession
    var proxyMode = false
    var captureRevision = Date.distantPast
    private var captureDirectory: URL? {
        let original = monitor.directory(session.id)
        return proxyMode ? original?.deletingLastPathComponent().appendingPathComponent("proxy", isDirectory: true) : original
    }
    @StateObject private var data = NetworkPanelModel()
    @AppStorage("networkPanelLayout") private var panelLayout = NetworkPanelLayout.horizontal
    @State private var confirmingClear = false
    @State private var showingFieldFilters = false
    @State private var showingFilterPresets = false
    @State private var filterPresetName = ""
    @State private var jsonSource = NetworkJSONCondition.Source.response
    @State private var jsonPath = ""
    @State private var jsonOperation = NetworkJSONCondition.Operation.equals
    @State private var jsonValue = ""
    @State private var jsonError: String?
    @State private var jsonExclusion = false
    @State private var rewriteEditor: NetworkRewriteEditorRequest?
    @State private var rewriteTask: Task<Void, Never>?
    @State private var loadingRewriteSample = false
    private var rewriteProjectID: UUID? { model.config.projects.first { $0.path == session.projectPath }?.id }
    private var enabled: Bool { model.networkCaptureEnabled(for: session) }
    private var sourceExists: Bool {
        if let id = session.attachment?.application.id { return model.applications.contains { $0.id == id } }
        return model.config.projects.contains { $0.path == session.projectPath }
    }
    private var state: NetworkMonitor.State? { monitor.states[session.id] }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if proxyMode {
                    Text("代理 HTTP / HTTPS").font(.caption).foregroundStyle(.secondary)
                    Toggle("只看已改写", isOn: $data.query.onlyRewritten).toggleStyle(.checkbox).fixedSize()
                } else {
                Toggle("网络采集", isOn: Binding(get: { enabled }, set: { value in
                    model.setNetworkCaptureEnabled(value, session: session)
                })).toggleStyle(.checkbox).fixedSize().disabled(!sourceExists)
                    .help("自动保存当前项目或应用的采集开关。暂停新增请求时，已记录的正文继续补齐；关闭开关停止读取，目标缓冲可能继续记录。")
                Text(state?.text ?? "本地历史缓存").font(.caption).foregroundStyle(state?.error == true ? .red : .secondary)
                    .lineLimit(1).help(state?.text ?? "已缓存的请求可在进程退出后查看")
                }
                Spacer(minLength: 0)
                Picker("布局", selection: $panelLayout) {
                    Text("左右布局").tag(NetworkPanelLayout.horizontal)
                    Text("上下布局").tag(NetworkPanelLayout.vertical)
                }.labelsHidden().frame(width: 100)
                    .accessibilityLabel("请求与详情布局")
                    .help("设置请求列表与详情的排列方式，自动记住选择；拖动分隔条调整比例，窄窗口建议使用上下布局")
                Toggle("跟随", isOn: $data.followsOutput).toggleStyle(.checkbox).fixedSize()
                    .help("跟随最新请求并滚动到底部；向上查看会暂停跟随")
                    .accessibilityLabel("跟随网络请求")
                if !proxyMode, monitor.isLive(session.id), enabled, monitor.hasConnection(session.id) {
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { contentSearch; fieldFiltersButton; filterPresetsButton; methodFilter; statusFilter }
                VStack(spacing: 5) {
                    HStack(spacing: 6) { contentSearch; fieldFiltersButton; filterPresetsButton }
                    HStack(spacing: 6) { methodFilter; statusFilter; Spacer(minLength: 0) }
                }
            }
            if let error = data.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            if let error = data.filterSaveError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            GeometryReader { geometry in
                if panelLayout == .horizontal {
                    HSplitView {
                        // Let the list scroll horizontally in a narrow window while
                        // keeping enough room for the detail controls.
                        requests.frame(minWidth: min(200, max(0, geometry.size.width - 301)),
                                       idealWidth: geometry.size.width * 0.55,
                                       maxWidth: .infinity, maxHeight: .infinity)
                        details.frame(minWidth: 300, idealWidth: geometry.size.width * 0.45,
                                      maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VSplitView {
                        requests.frame(maxWidth: .infinity, minHeight: 110,
                                       idealHeight: geometry.size.height * 0.55, maxHeight: .infinity)
                        details.frame(maxWidth: .infinity, minHeight: 120,
                                      idealHeight: geometry.size.height * 0.45, maxHeight: .infinity)
                    }
                }
            }.frame(minHeight: 250)
            HStack {
                Text("\(data.window.matching) / \(data.window.total) 条").monospacedDigit()
                if !data.window.counts.isComplete { Text("正在筛选更早记录…") }
                Text("当前位置 \(data.positionPercent)%").monospacedDigit()
                Spacer(minLength: 0)
                Button("最早") { data.earliest() }.disabled(data.window.matching == 0)
                    .accessibilityLabel("最早的网络请求")
                Button("最新") { data.latest() }.disabled(data.window.matching == 0)
                    .accessibilityLabel("最新的网络请求")
            }.font(.caption).foregroundStyle(.secondary)
            Text(proxyMode ? "代理记录按需读取 · 每个请求 / 响应正文最多保留 1 MB；截断情况见概览" : "完整列表按需读取 · 磁盘自动增长 · 每个请求 / 响应正文最多 1 MB")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                .help(proxyMode ? "只读取经过本次代理的请求。列表最多保留 256 条摘要；选中后读取详情，每个正文最多保留 1 MB，截断和压缩编码说明见概览。TLS 透传只记录 CONNECT；开启解密并信任证书后才能读取 HTTPS 内容。" : "请求摘要和正文按需保存在磁盘。为系统保留 512 MiB 可用空间，并预留本次写入及回滚日志所需空间；不足时暂停，释放空间后点击继续。内存只保留最多 256 条摘要与当前正文页，单次服务返回最多 8 MB。DevTools 支持 Dart VM 的 HTTP / HTTPS；WebSocket 请使用独立代理抓包模式。")
        }.controlSize(.small)
            .task(id: session.id) {
                if !proxyMode { data.query.onlyRewritten = false }
                data.configure(directory: captureDirectory, sessionID: session.id)
            }
            .onChange(of: monitor.revision) { _, _ in if !proxyMode { data.refresh() } }
            .onChange(of: captureRevision) { _, _ in if proxyMode { data.refresh() } }
            .onChange(of: data.selectedID) { _, id in
                if !proxyMode, let id { monitor.prioritizeBody(id, sessionID: session.id) }
            }
            .onDisappear { rewriteTask?.cancel(); loadingRewriteSample = false; data.stop() }
            .sheet(item: $rewriteEditor) { request in
                ResponseRewriteRulesView(model: model, projectID: request.projectID, sample: request.sample,
                                         initialAction: request.action, editingRuleID: request.ruleID)
            }
            .confirmationDialog("清理目标采集缓冲？", isPresented: $confirmingClear) {
                Button("清理目标缓冲", role: .destructive) { monitor.clearTargetBuffer(session.id) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会同时清理 DevTools 中的网络记录，并使正在进行的请求停止记录。Runbar 的本地历史缓存会保留。")
            }
    }
    private func openRewrite(recordID: String, action: ResponseRewriteAction? = nil, ruleID: UUID? = nil) {
        guard let projectID = rewriteProjectID else { return }
        rewriteTask?.cancel(); loadingRewriteSample = true
        rewriteTask = Task {
            let sample = await data.rewriteSample(recordID: recordID, showError: ruleID == nil)
            guard !Task.isCancelled else { return }
            loadingRewriteSample = false
            if sample != nil || ruleID != nil {
                rewriteEditor = NetworkRewriteEditorRequest(projectID: projectID, sample: sample, action: action, ruleID: ruleID)
            }
        }
    }
    private func rewriteMenu(recordID: String, method: String, url: String, target: ResponseRewriteTarget? = nil) -> NSMenu? {
        guard proxyMode, let projectID = rewriteProjectID else { return nil }
        let menu = NSMenu(); menu.autoenablesItems = false
        if let target {
            let title = target.action.kind == .table ? "整列：\(target.action.column)" : "字段：\(target.path)"
            let label = NSMenuItem(title: String(title.prefix(100)), action: nil, keyEquivalent: "")
            label.isEnabled = false; label.toolTip = title; menu.addItem(label)
        }
        let title = target.map { $0.action.kind == .table ? "新建整列改写规则…" : "新建字段改写规则…" } ?? "响应改写…"
        menu.addItem(NetworkRewriteMenuItem(title: title) { openRewrite(recordID: recordID, action: target?.action) })
        let rules = model.config.projects.first { $0.id == projectID }?.responseRewrite?.rules.filter { rule in
            guard rule.method.isEmpty || rule.method.uppercased() == method.uppercased() else { return false }
            let pattern = rule.urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            switch rule.urlMode {
            case .full: return url == pattern
            case .contains: return !pattern.isEmpty && url.contains(pattern)
            case .path:
                let path = URLComponents(string: url)?.percentEncodedPath ?? ""
                return (path.isEmpty ? "/" : path) == pattern
            }
        } ?? []
        if !rules.isEmpty {
            let item = NSMenuItem(title: target == nil ? "编辑此接口的规则" : "编辑或添加到已有规则", action: nil, keyEquivalent: "")
            let submenu = NSMenu(); submenu.autoenablesItems = false
            for rule in rules {
                let option = NetworkRewriteMenuItem(title: rule.name) {
                    openRewrite(recordID: recordID, action: target?.action, ruleID: rule.id)
                }
                option.toolTip = "保留此规则的请求条件和备注；保存后应用到后续请求。"
                submenu.addItem(option)
            }
            item.submenu = submenu; menu.addItem(item)
        }
        return menu
    }
    private var responseRewriteMenu: ((ResponseRewriteTarget) -> NSMenu?)? {
        guard proxyMode, rewriteProjectID != nil, data.detail == .response,
              data.responseVersion != .changes, !data.loading, let record = data.selected else { return nil }
        return { target in rewriteMenu(recordID: record.id, method: record.method, url: record.url, target: target) }
    }
    private var contentSearch: some View {
        NetworkKeywordEditor(query: $data.query, scope: .everywhere, placeholder: "搜索全部内容，回车添加关键词")
            .frame(minWidth: 150)
            .accessibilityLabel("搜索 URL、请求头、请求参数及响应内容")
    }
    private var methodFilter: some View {
        Picker("方法", selection: $data.query.method) {
            Text("全部方法").tag("")
            ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { Text($0).tag($0) }
        }.labelsHidden().frame(width: 90).accessibilityLabel("网络方法筛选")
    }
    private var statusFilter: some View {
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
    private var fieldFiltersButton: some View {
        Button(data.query.fieldFilterCount == 0 ? "筛选" : "筛选 \(data.query.fieldFilterCount)", systemImage: "line.3.horizontal.decrease") {
            showingFieldFilters.toggle()
        }.fixedSize().accessibilityLabel("按字段组合筛选网络请求")
            .popover(isPresented: $showingFieldFilters, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("网络筛选").font(.headline)
                        Spacer()
                        Button("清空字段", action: data.clearFieldFilters).disabled(data.query.fieldFilterCount == 0)
                    }
                    HStack {
                        Text("每组包含词")
                        Picker("关键词关系", selection: $data.query.keywordMode) {
                            ForEach(NetworkKeywordMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                        Spacer(minLength: 0)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            keywordRow("URL", scope: .url, placeholder: "地址关键词")
                            keywordRow("请求/响应头", scope: .headers, placeholder: "Header 名称或内容")
                            keywordRow("请求参数", scope: .request, placeholder: "URL 参数或请求正文关键词")
                            keywordRow("响应内容", scope: .response, placeholder: "响应正文关键词")
                            Text("选择包含或排除，再回车 / + 添加。逗号、分号和换行可分隔多个词。包含条件先取结果，命中任一排除词则剔除；排除优先。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Divider()
                            jsonFilters
                        }.padding(.trailing, 3)
                    }.frame(maxHeight: 450)
                    Text("只设排除条件时从全部请求中剔除；未缓存正文无法判断是否包含排除词。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(width: 550).controlSize(.small)
            }
    }
    private var filterPresetsButton: some View {
        Button("方案", systemImage: "bookmark") { showingFilterPresets.toggle() }
            .fixedSize().accessibilityLabel("网络筛选方案")
            .help("当前网络筛选自动记住；保存命名方案，下次一键使用")
            .popover(isPresented: $showingFilterPresets, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("网络筛选方案").font(.headline)
                        Spacer()
                        Button("重置当前筛选") { data.query = NetworkQuery() }.disabled(data.query.isEmpty)
                    }
                    Text("当前条件自动记住。点击方案替换当前条件；重置不删除方案。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if data.filterPreferences.presets.isEmpty {
                        Text("还没有方案，输入名称保存当前条件即可。")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 5) {
                                ForEach(data.filterPreferences.presets) { preset in
                                    HStack {
                                        Button {
                                            if data.useFilterPreset(preset.id) { showingFilterPresets = false }
                                        } label: {
                                            HStack {
                                                Image(systemName: data.query.hasSameConditions(as: preset.query) ? "checkmark.circle.fill" : "circle")
                                                Text(preset.name).lineLimit(1)
                                                Spacer()
                                            }.contentShape(Rectangle())
                                        }.buttonStyle(.plain).help("使用 \(preset.name)，替换当前网络筛选")
                                        Button { data.removeFilterPreset(preset.id) } label: { Image(systemName: "trash") }
                                            .buttonStyle(.borderless).accessibilityLabel("删除网络筛选方案 \(preset.name)")
                                    }.padding(.vertical, 4)
                                }
                            }
                        }.frame(height: min(210, CGFloat(data.filterPreferences.presets.count) * 32))
                    }
                    Divider()
                    HStack {
                        TextField("方案名称", text: $filterPresetName).textFieldStyle(.roundedBorder).onSubmit(saveFilterPreset)
                        Button("保存", action: saveFilterPreset)
                            .disabled(filterPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("保存包含 / 排除词、JSON 条件、方法和状态；同名保存会更新原方案。所有项目与关联 App 均可复用。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let error = data.filterSaveError { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }.padding(16).frame(width: 390).controlSize(.small)
            }
    }
    private func saveFilterPreset() {
        if data.saveFilterPreset(filterPresetName) { filterPresetName = "" }
    }
    private func keywordRow(_ title: String, scope: NetworkKeywordScope, placeholder: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).frame(width: 85, alignment: .leading).padding(.top, 4)
            NetworkKeywordEditor(query: $data.query, scope: scope, placeholder: placeholder)
        }
    }
    private var jsonFilters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("字段条件（JSON）").font(.headline)
            ForEach(data.query.jsonConditions) { rule in
                HStack(spacing: 6) {
                    Text(rule.isExclusion ? "排除" : "保留").foregroundStyle(rule.isExclusion ? Color.orange : Color.accentColor)
                    Text(rule.source.title).foregroundStyle(.secondary)
                    Text(rule.path).font(.system(.caption, design: .monospaced)).lineLimit(1)
                    Text(rule.operation.title)
                    if rule.operation.needsValue { Text(rule.value).lineLimit(1) }
                    Spacer(minLength: 0)
                    Button { data.query.jsonConditions.removeAll { $0.id == rule.id } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("删除这条条件")
                }.padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .help("\(rule.source.title) · \(rule.path) \(rule.operation.title) \(rule.value)")
            }
            HStack(spacing: 7) {
                Picker("JSON 条件作用", selection: $jsonExclusion) { Text("保留").tag(false); Text("排除").tag(true) }
                    .labelsHidden().frame(width: 70)
                Picker("JSON 来源", selection: $jsonSource) {
                    ForEach(NetworkJSONCondition.Source.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 110)
                TextField("字段路径，如 data.connectionid", text: $jsonPath)
                    .accessibilityLabel("JSON 字段路径")
            }
            HStack(spacing: 7) {
                Picker("字段比较方式", selection: $jsonOperation) {
                    ForEach(NetworkJSONCondition.Operation.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 110)
                TextField(jsonOperation.needsValue ? "值，如 1、true、null 或文本" : "无需填写值", text: $jsonValue)
                    .disabled(!jsonOperation.needsValue).onSubmit(addJSONCondition)
                    .accessibilityLabel("JSON 字段比较值")
                Button("添加", action: addJSONCondition).disabled(data.query.jsonConditions.count >= 16)
            }
            if let jsonError { Text(jsonError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("例：响应 JSON · data.connectionid · 等于 · 1。数组可写 items[0].id 或 items[*].id。数字 1 与字符串 \"1\" 区分；空字符串写 \"\"。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("保留条件须全部满足；任一排除条件命中即剔除。不等于 / 不包含也匹配缺少该字段的 JSON；非 JSON 和未缓存正文不会命中字段条件。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.textFieldStyle(.roundedBorder)
    }
    private func addJSONCondition() {
        guard data.query.jsonConditions.count < 16 else { return }
        let rule = NetworkJSONCondition(source: jsonSource, path: jsonPath.trimmingCharacters(in: .whitespacesAndNewlines),
                                        operation: jsonOperation, value: jsonValue, isExclusion: jsonExclusion)
        do {
            try rule.validate(); data.query.jsonConditions.append(rule)
            jsonPath = ""; jsonValue = ""; jsonError = nil
        } catch { jsonError = error.localizedDescription }
    }
    private var requests: some View {
        NetworkRequestsTable(window: data.window, selection: data.selectedRow, showsRewrite: proxyMode,
                             following: data.followsOutput, scrollRevision: data.scrollRevision, scrollsToLatest: data.scrollsToLatest,
                             firstVisibleRow: data.firstVisibleRow,
                             rewriteMenu: { record in rewriteMenu(recordID: record.id, method: record.method, url: record.url) },
                             onSelection: data.select, onViewport: data.viewportChanged) {
            data.followsOutput = false
        }
            // Let the AppKit scroll view fill the split pane before drawing
            // overlays; its measured content width must not leave a blank lane.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if data.window.matching == 0 {
                    Text(data.queryLoading || !data.window.counts.isComplete ? "正在筛选已缓存内容…" :
                         data.window.total == 0 ? (proxyMode ? "暂无代理请求\n请确认目标 App 的网络库已使用本次运行的代理" : "暂无已缓存请求\n开启采集后，需要运行支持 HTTP profiling 的 Dart / Flutter 程序") : "没有匹配的请求")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding().allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
    }
    private var details: some View {
        // Keep one split-pane root when selection changes. A conditional root
        // makes NSSplitView replace the pane and recalculate its divider.
        ZStack {
            if data.selected == nil {
                VStack(spacing: 8) {
                    Image(systemName: "network").font(.title2)
                    Text("选择一条请求查看详情")
                    Text("概览、请求头和正文在选中后读取").font(.caption)
                }.foregroundStyle(.secondary)
            } else { selectedDetails }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var selectedDetails: some View {
        VStack(spacing: 5) {
            if proxyMode {
                HStack(spacing: 6) {
                    if let rewrite = data.selected?.rewrite {
                        Label(rewrite.title, systemImage: rewrite.state == .changed ? "pencil.circle.fill" : "info.circle")
                            .foregroundStyle(rewrite.state == .changed ? Color.orange : Color.secondary).help(rewrite.detail)
                    }
                    Spacer(minLength: 0)
                    Button("以此请求新建规则") {
                        if let record = data.selected { openRewrite(recordID: record.id) }
                    }.disabled(rewriteProjectID == nil || data.selected?.bodyState != .saved || loadingRewriteSample)
                }.font(.caption)
            }
            Picker("请求详情", selection: $data.detail) {
                ForEach(NetworkPanelModel.Detail.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("网络请求详情")
            if proxyMode, data.detail == .response {
                HStack(spacing: 6) {
                    Picker("响应版本", selection: $data.responseVersion) {
                        ForEach(ResponseRewriteBodyVersion.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    Toggle("表格", isOn: $data.tableMode).toggleStyle(.checkbox).fixedSize()
                        .disabled(data.responseVersion == .changes).help("将首行表头的二维数组显示为表格")
                }
                if let rewrite = data.selected?.rewrite, let reason = rewrite.reason, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 6) {
                Picker("显示格式", selection: Binding(get: { data.bodyFormat }, set: data.formatBody)) {
                    ForEach([NetworkBodyFormat.json, .xml, .raw], id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                    .disabled(data.selected == nil || (data.detail == .response && (data.tableMode || data.responseVersion == .changes)))
                    .accessibilityLabel("网络正文显示格式")
                    .help("默认 JSON；按当前详情标签记住选择，内容不符合格式时显示原始内容")
                Spacer(minLength: 0)
                Toggle("自动换行", isOn: Binding(get: { data.preferences.wrapsLines }, set: data.setWrapsLines))
                    .toggleStyle(.checkbox).fixedSize().help("记住换行设置；关闭时可横向滚动长行")
                    .disabled(data.detail == .response && data.tableMode && data.responseVersion != .changes)
            }
            if let error = data.formatError { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(error) }
            if proxyMode, data.detail == .response, data.tableMode, data.responseVersion != .changes,
               let table = data.responseTables.first(where: { $0.path == data.selectedTablePath }) {
                if data.responseTables.count > 1 {
                    Picker("表格位置", selection: $data.selectedTablePath) {
                        ForEach(data.responseTables, id: \.path) { Text($0.path).tag($0.path) }
                    }.font(.caption)
                }
                ResponseRewriteTableView(table: table,
                    changesByCell: data.responseVersion == .client ? data.tableChanges : [:],
                    ruleName: data.selected?.rewrite?.ruleName ?? "", rewriteMenu: responseRewriteMenu)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            NetworkTextView(text: data.bodyText, wrapsLines: data.preferences.wrapsLines, annotations: data.bodyAnnotations,
                            rewriteTargets: data.rewriteTargets, rewriteMenu: responseRewriteMenu)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
            }
            if let selected = data.selected, data.detail == .request || data.detail == .response || data.bodyPages > 1 {
                HStack(spacing: 6) {
                    if data.loading { ProgressView().controlSize(.mini) }
                    if data.showsURLParameters { Text("URL 参数") }
                    else if data.detail == .overview || data.detail == .headers { Text("详情") }
                    else if selected.bodyState == .saved {
                        Text(data.bodyBytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(data.bodyBytes), countStyle: .file))
                    } else if let error = monitor.bodyErrors[selected.id] {
                        Text(error).lineLimit(1).help(error)
                    } else {
                        Text(selected.bodyState == .pending ? (proxyMode ? "等待请求完成后缓存正文" : "等待正文，选中后优先加载") : selected.bodyState.title)
                    }
                    Spacer()
                    if selected.bodyState == .saved || data.showsURLParameters || data.detail == .overview || data.detail == .headers {
                        Button { data.moveBody(-1) } label: { Image(systemName: "chevron.left") }.disabled(data.bodyIndex == 0)
                        Text("\(data.bodyIndex + 1) / \(data.bodyPages)")
                        Button { data.moveBody(1) } label: { Image(systemName: "chevron.right") }.disabled(data.bodyIndex + 1 >= data.bodyPages)
                    } else if !proxyMode, monitor.hasConnection(session.id), enabled {
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
    let showsRewrite: Bool
    let following: Bool
    let scrollRevision: Int
    let scrollsToLatest: Bool
    let firstVisibleRow: Int?
    var rewriteMenu: ((NetworkRequestSummary) -> NSMenu?)? = nil
    let onSelection: (Int?) -> Void
    let onViewport: (Int, Int, Double) -> Void
    let onScrollAway: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NetworkRequestsScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let verticalScroller = NetworkRequestsScroller()
        scroll.verticalScroller = verticalScroller
        let table = NetworkRequestTableView()
        table.setAccessibilityLabel("网络请求列表（完整历史，从旧到新）")
        table.rowHeight = 23
        // Older matches can be prepended while the viewport stays anchored to
        // the same request. Row-number striping would flip at an odd shift.
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = .separatorColor
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        var columns = [("time", "时间", 100.0), ("method", "方法", 60.0), ("url", "地址", 260.0),
                       ("status", "状态", 60.0), ("duration", "耗时", 70.0)]
        if showsRewrite { columns.append(("rewrite", "改写", 115.0)) }
        for (key, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); column.title = title
            column.width = width; column.minWidth = key == "url" ? 100 : width
            column.resizingMask = key == "url" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        scroll.documentView = table
        scroll.onScrollAway = { [weak coordinator = context.coordinator] in coordinator?.pauseFollowing() }
        verticalScroller.onInteraction = scroll.onScrollAway
        table.onScrollAway = scroll.onScrollAway
        table.rewriteMenu = { [weak coordinator = context.coordinator] row in
            guard let coordinator, let record = coordinator.parent.window.row(at: row) else { return nil }
            return coordinator.parent.rewriteMenu?(record)
        }
        context.coordinator.observe(scroll)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator, old = coordinator.parent
        coordinator.parent = self; coordinator.applying = true
        if following && (!old.following || old.scrollRevision != scrollRevision) { coordinator.userPaused = false }
        let oldVisible = table.rows(in: scroll.documentVisibleRect)
        let oldFirst = oldVisible.location != NSNotFound && oldVisible.length > 0 ? oldVisible.location : nil
        let oldFirstID = oldFirst.flatMap { old.window.row(at: $0)?.id }
        let firstOffset = oldFirst.map { scroll.contentView.bounds.minY - table.rect(ofRow: $0).minY } ?? 0
        let initialPlacement = window.matching > 0 && !coordinator.positioned
        if window.matching == 0 { coordinator.positioned = false }
        let countChanged = table.numberOfRows != window.matching
        if countChanged {
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0
                table.noteNumberOfRowsChanged()
            }
        }
        if old.window.offset != window.offset || old.window.rows != window.rows {
            // Limit comparisons to the two cached windows. Rows outside them
            // still show the same placeholder, even when the total grows.
            var candidates = IndexSet(integersIn: window.offset..<(window.offset + window.rows.count))
            candidates.insert(integersIn: old.window.offset..<(old.window.offset + old.window.rows.count))
            let changedRows = IndexSet(candidates.filter {
                $0 < window.matching && old.window.row(at: $0) != window.row(at: $0)
            })
            if !changedRows.isEmpty {
                table.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
        }
        if let selection, selection >= 0, selection < window.matching {
            if table.selectedRow != selection { table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false) }
        } else if table.selectedRow >= 0 { table.deselectAll(nil) }
        let navigation = old.scrollRevision != scrollRevision
        if window.matching > 0 && (initialPlacement || navigation || (following && (countChanged || !old.following))) {
            coordinator.positioned = true
            // A layout change creates a new table. Preserve the paused viewport
            // instead of treating the new table as a request to jump to the end.
            let restoringFirstRow = initialPlacement && !following ? firstVisibleRow : nil
            coordinator.placeViewport(in: table, restoringFirstRow: restoringFirstRow)
            // SwiftUI may resize the initial clip view after this update.
            let revision = scrollRevision
            DispatchQueue.main.async { [weak table, weak coordinator] in
                guard let table, let coordinator, coordinator.parent.scrollRevision == revision,
                      coordinator.parent.following == following, !coordinator.userPaused || !following, table.numberOfRows > 0 else { return }
                coordinator.applying = true
                coordinator.placeViewport(in: table, restoringFirstRow: restoringFirstRow)
                coordinator.applying = false; coordinator.reportViewport()
            }
        } else if !following, let anchor = window.anchorRow, let oldFirstID,
                  window.row(at: anchor)?.id == oldFirstID, anchor != oldFirst {
            // A newest-first content scan prepends older matches. Keep the
            // same request under the user's eyes instead of keeping its rank.
            table.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: table.rect(ofRow: anchor).minY + firstOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        coordinator.applying = false; coordinator.reportViewport()
    }
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: NetworkRequestsTable
        var applying = false
        var positioned = false
        var userPaused = false
        private weak var scroll: NSScrollView?
        private var observation: NSObjectProtocol?
        private var frameObservation: NSObjectProtocol?
        private var reportPending = false
        private var followPending = false
        private static let formatter: DateFormatter = {
            let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX")
            value.dateFormat = "HH:mm:ss.SSS"; return value
        }()
        init(_ parent: NetworkRequestsTable) { self.parent = parent }
        deinit {
            if let observation { NotificationCenter.default.removeObserver(observation) }
            if let frameObservation { NotificationCenter.default.removeObserver(frameObservation) }
        }
        func placeViewport(in table: NSTableView, restoringFirstRow: Int?) {
            table.layoutSubtreeIfNeeded()
            if let restoringFirstRow, let scroll, table.numberOfRows > 0 {
                let row = min(max(0, restoringFirstRow), table.numberOfRows - 1)
                let maximumY = max(table.bounds.minY, table.bounds.maxY - scroll.contentView.bounds.height)
                let y = min(table.rect(ofRow: row).minY, maximumY)
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            } else {
                table.scrollRowToVisible(parent.scrollsToLatest ? table.numberOfRows - 1 : 0)
            }
        }
        func observe(_ scroll: NSScrollView) {
            self.scroll = scroll; scroll.contentView.postsBoundsChangedNotifications = true; scroll.contentView.postsFrameChangedNotifications = true
            observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                 object: scroll.contentView, queue: .main) { [weak self] _ in
                guard let self, !self.applying else { return }
                self.followTailAfterLayout()
                self.reportViewport()
            }
            frameObservation = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in self?.followTailAfterLayout() }
        }
        func followTailAfterLayout() {
            guard !applying, parent.following, !userPaused, !followPending else { return }
            followPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.followPending = false
                guard self.parent.following, !self.userPaused, let scroll = self.scroll,
                      let table = scroll.documentView as? NSTableView, table.numberOfRows > 0,
                      scroll.contentView.bounds.maxY < table.rect(ofRow: table.numberOfRows - 1).maxY - 2 else { return }
                self.applying = true
                table.layoutSubtreeIfNeeded(); table.scrollRowToVisible(table.numberOfRows - 1)
                self.applying = false; self.reportViewport()
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
                self.parent.onViewport(rows.location, min(table.numberOfRows - 1, NSMaxRange(rows) - 1), Double(progress))
            }
        }
        func pauseFollowing() {
            guard !applying else { return }
            userPaused = true
            if parent.following { parent.onScrollAway() }
        }
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
            cell.textField?.textColor = .labelColor
            if let record = parent.window.row(at: row) {
                switch id.rawValue {
                case "time": value = Self.formatter.string(from: record.startDate)
                case "method": value = record.method
                case "url": value = record.url
                case "status": value = record.failed ? "失败" : record.status.map(String.init) ?? "Pending"
                case "rewrite":
                    switch record.rewriteState {
                    case .changed: value = "已改写 · \(record.rewriteCount) 处"; cell.textField?.textColor = .systemOrange
                    case .unchanged: value = "命中，未变化"
                    case .skipped: value = "改写跳过"
                    case nil: value = "—"
                    }
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
private final class NetworkRequestsScroller: NSScroller {
    var onInteraction: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onInteraction?(); super.mouseDown(with: event) }
    override func accessibilityPerformIncrement() -> Bool { onInteraction?(); return super.accessibilityPerformIncrement() }
    override func accessibilityPerformDecrement() -> Bool { onInteraction?(); return super.accessibilityPerformDecrement() }
}
private final class NetworkRequestTableView: NSTableView {
    var onScrollAway: (() -> Void)?
    var rewriteMenu: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let menu = rewriteMenu?(row) else { return super.menu(for: event) }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return menu
    }
    override func keyDown(with event: NSEvent) {
        if [115, 116, 126].contains(event.keyCode) { onScrollAway?() } // Home, Page Up, Up
        super.keyDown(with: event)
    }
}

struct NetworkTextView: NSViewRepresentable {
    let text: String
    let wrapsLines: Bool
    var annotations: [ResponseRewriteAnnotation] = []
    var rewriteTargets: [ResponseRewriteTarget] = []
    var rewriteMenu: ((ResponseRewriteTarget) -> NSMenu?)? = nil
    final class Coordinator {
        var wrapsLines: Bool?
        var annotations: [ResponseRewriteAnnotation] = []
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let view = RewriteNetworkTextView(); view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.isAutomaticLinkDetectionEnabled = false; view.textContainerInset = NSSize(width: 8, height: 8)
        view.isHorizontallyResizable = true; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? RewriteNetworkTextView else { return }
        view.rewriteTargets = rewriteTargets; view.rewriteMenu = rewriteMenu
        if context.coordinator.wrapsLines != wrapsLines {
            let origin = scroll.contentView.bounds.origin
            context.coordinator.wrapsLines = wrapsLines
            scroll.hasHorizontalScroller = !wrapsLines
            view.isHorizontallyResizable = !wrapsLines
            view.textContainer?.widthTracksTextView = wrapsLines
            view.textContainer?.containerSize = NSSize(width: wrapsLines ? max(1, scroll.contentSize.width - 16) : CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
            if wrapsLines { view.setFrameSize(NSSize(width: max(1, scroll.contentSize.width), height: max(view.frame.height, scroll.contentSize.height))) }
            scroll.contentView.scroll(to: NSPoint(x: wrapsLines ? 0 : origin.x, y: origin.y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        let changedText = view.string != text
        if changedText {
            view.string = text; view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
            view.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        if changedText || context.coordinator.annotations != annotations {
            (view as? RewriteNetworkTextView)?.dismissValuePopover()
            context.coordinator.annotations = annotations
            if let storage = view.textStorage {
                storage.beginEditing()
                let all = NSRange(location: 0, length: storage.length)
                storage.removeAttribute(.backgroundColor, range: all)
                storage.removeAttribute(.toolTip, range: all)
                for item in annotations where item.range.location >= 0 && NSMaxRange(item.range) <= storage.length {
                    storage.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.22), range: item.range)
                    storage.addAttribute(.toolTip, value: item.tooltip, range: item.range)
                }
                storage.endEditing()
            }
        }
    }
}

private final class RewriteNetworkTextView: NSTextView {
    var rewriteTargets: [ResponseRewriteTarget] = []
    var rewriteMenu: ((ResponseRewriteTarget) -> NSMenu?)?
    private var valuePopover: NSPopover?
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let rewriteMenu, !rewriteTargets.isEmpty, let layoutManager, let textContainer else { return menu }
        let point = convert(event.locationInWindow, from: nil)
        let textPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: textPoint, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(textPoint) else { return menu }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        let selection = selectedRange()
        let range = selection.length > 0 && NSLocationInRange(index, selection) ? selection : NSRange(location: index, length: 1)
        guard let target = rewriteTargets.first(where: {
            $0.range.location <= range.location && NSMaxRange($0.range) >= NSMaxRange(range)
        }), let actions = rewriteMenu(target) else { return menu }
        dismissValuePopover()
        let hadSystemItems = !menu.items.isEmpty
        let items = actions.items
        for (offset, item) in items.enumerated() {
            actions.removeItem(item); menu.insertItem(item, at: offset)
        }
        if hadSystemItems { menu.insertItem(.separator(), at: items.count) }
        return menu
    }
    func dismissValuePopover() {
        valuePopover?.close(); valuePopover = nil
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        dismissValuePopover()
        guard let storage = textStorage, storage.length > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard index < storage.length, let tooltip = storage.attribute(.toolTip, at: index, effectiveRange: nil) as? String else { return }
        let label = NSTextView(); label.isEditable = false; label.isSelectable = true; label.string = tooltip
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular); label.textContainerInset = NSSize(width: 10, height: 10)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 180))
        scroll.hasVerticalScroller = true; scroll.documentView = label
        label.frame = scroll.bounds; label.autoresizingMask = [.width]; label.textContainer?.widthTracksTextView = true
        let controller = NSViewController(); controller.view = scroll
        let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = controller
        popover.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: self, preferredEdge: .maxY)
        valuePopover = popover
    }
}

/// The menu owns the closure and its immutable request/field snapshot.
private final class NetworkRewriteMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

/// Drafts filter live; committing them as chips does not restart the same search.
private struct NetworkKeywordEditor: View {
    @Binding var query: NetworkQuery
    let scope: NetworkKeywordScope
    let placeholder: String
    @State private var error: String?
    @State private var excluding = false
    private var draft: Binding<String> {
        Binding(get: { query.draft(in: scope, excluding: excluding) }, set: { query.setDraft($0, in: scope, excluding: excluding); error = nil })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Picker("关键词作用", selection: $excluding) { Text("包含").tag(false); Text("排除").tag(true) }
                    .labelsHidden().frame(width: 65)
                TextField(excluding ? "排除关键词，回车添加" : placeholder, text: draft)
                    .textFieldStyle(.roundedBorder).onSubmit(commit)
                Button(action: commit) { Image(systemName: "plus") }
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("添加关键词")
            }
            chips(excluding: false)
            chips(excluding: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.help("回车或 + 添加多个词，点 × 删除。逗号、分号和换行分隔多个词，空格保留。包含 / 排除各最多 16 个；排除词命中任一个即剔除。")
    }
    @ViewBuilder private func chips(excluding: Bool) -> some View {
        if !query.keywords(in: scope, excluding: excluding).isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 4)], alignment: .leading, spacing: 4) {
                ForEach(query.keywords(in: scope, excluding: excluding), id: \.self) { word in
                    HStack(spacing: 4) {
                        Image(systemName: excluding ? "minus.circle" : "plus.circle")
                        Text(word).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button { query.removeKeyword(word, in: scope, excluding: excluding) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("删除关键词 \(word)")
                    }.font(.caption).padding(.horizontal, 6).padding(.vertical, 3)
                        .background((excluding ? Color.orange : Color.accentColor).opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                        .help("\(excluding ? "排除" : "包含")：\(word)")
                }
            }
        }
    }
    private func commit() {
        do { try query.commitKeywords(in: scope, excluding: excluding); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
