import SwiftUI
import AppKit
import RunbarCore

/// Project-owned rules. Editing a rule is a draft until the explicit save action.
struct ResponseRewriteRulesView: View {
    @ObservedObject var model: AppModel
    let projectID: UUID
    let sample: ResponseRewriteSample?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var draft: ResponseRewriteRule?
    @State private var baseline: ResponseRewriteRule?
    @State private var targetActionID: UUID?
    @State private var quickEntryMessage: String?
    @State private var missingRule = false
    @State private var saving = false
    @State private var error: String?
    @State private var pending: Navigation?
    @State private var showingUnsaved = false
    @State private var showingDelete = false
    @State private var sampleExpanded: Bool
    @State private var sampleMethod: String
    @State private var sampleURL: String
    @State private var sampleRequest: String
    @State private var sampleResponse: String
    @State private var preview: ResponseRewritePreview?
    @State private var previewError: String?
    @State private var previewWorking = false
    @State private var previewTask: Task<Void, Never>?
    private enum Navigation { case select(UUID), create, close }

    init(model: AppModel, projectID: UUID, sample: ResponseRewriteSample? = nil,
         initialAction: ResponseRewriteAction? = nil, editingRuleID: UUID? = nil) {
        self.model = model; self.projectID = projectID; self.sample = sample
        let rules = model.config.projects.first { $0.id == projectID }?.responseRewrite?.rules ?? []
        var initial: ResponseRewriteRule?
        var saved: ResponseRewriteRule?
        var targetID: UUID?
        var message: String?
        var initialError: String?
        if let editingRuleID {
            if var rule = rules.first(where: { $0.id == editingRuleID }) {
                saved = rule
                if let initialAction {
                    if let existing = rule.actions.first(where: { Self.sameTarget($0, initialAction) }) {
                        targetID = existing.id
                        message = "已定位现有替换项，保留规则原先设置的新值。请求条件仍可在上方编辑。"
                    } else if rule.actions.count < 32 {
                        var appended = initialAction; appended.id = UUID()
                        rule.actions.append(appended); targetID = appended.id
                        message = "此字段尚未包含在规则中，已追加替换项并带入当前值；请设置要返回的新值后保存。"
                    } else {
                        initialError = "这条规则已有 32 个替换项，无法追加当前字段。请先删除不需要的替换项。"
                        message = initialError
                    }
                }
                initial = rule
            } else {
                initialError = Self.missingRuleMessage
            }
        } else if sample != nil || initialAction != nil {
            var rule = sample.map(Self.seed) ?? ResponseRewriteRule()
            if let initialAction {
                rule.actions = [initialAction]; targetID = initialAction.id
                message = "已带入所选字段及当前值，请设置要返回的新值后保存。请求 URL 和参数条件仍可在上方编辑。"
            }
            initial = rule
        } else {
            initial = rules.first; saved = initial
        }
        _draft = State(initialValue: initial)
        _baseline = State(initialValue: saved)
        _selectedID = State(initialValue: initial?.id ?? editingRuleID)
        _targetActionID = State(initialValue: targetID)
        _quickEntryMessage = State(initialValue: message)
        _missingRule = State(initialValue: editingRuleID != nil && initial == nil)
        _error = State(initialValue: initialError)
        _sampleExpanded = State(initialValue: sample == nil)
        _sampleMethod = State(initialValue: sample?.method ?? "POST")
        _sampleURL = State(initialValue: sample?.url ?? "")
        _sampleRequest = State(initialValue: sample.map { String(decoding: $0.requestBody, as: UTF8.self) } ?? "")
        _sampleResponse = State(initialValue: sample.map { String(decoding: $0.responseBody, as: UTF8.self) } ?? "")
    }
    private var settings: ResponseRewriteSettings {
        model.config.projects.first { $0.id == projectID }?.responseRewrite ?? ResponseRewriteSettings()
    }
    private var projectName: String { model.config.projects.first { $0.id == projectID }?.name ?? "项目已移除" }
    private var dirty: Bool { draft != baseline }
    private var busy: Bool { saving || model.responseRewriteSyncing.contains(projectID) }
    private var canSave: Bool { dirty && draft?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && !busy && !missingRule }
    private static let missingRuleMessage = "这条规则已被删除或已不属于当前项目，无法继续保存。请重新选择已有规则，或明确新建规则。"
    private var suppliedSample: ResponseRewriteSample? {
        guard !sampleResponse.isEmpty else { return nil }
        return ResponseRewriteSample(method: sampleMethod, url: sampleURL,
            requestBody: Data(sampleRequest.utf8), responseBody: Data(sampleResponse.utf8))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("响应改写规则").font(.title2)
                    Text(projectName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("启用响应改写", isOn: Binding(get: { settings.enabled }, set: { value in
                    var next = settings; next.enabled = value
                    Task { _ = await saveSettings(next) }
                })).toggleStyle(.switch).disabled(busy)
            }.padding(18)
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 218)
                Divider()
                if draft != nil {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                identitySection
                                Divider()
                                matchingSection
                                Divider()
                                replacementSection.id("replacement-section")
                                Divider()
                                previewSection
                            }.padding(20)
                        }.task(id: targetActionID) {
                            guard quickEntryMessage != nil else { return }
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            if let targetActionID { proxy.scrollTo(targetActionID, anchor: .top) }
                            else { proxy.scrollTo("replacement-section", anchor: .top) }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label(missingRule ? "规则已不存在" : "尚未选择规则", systemImage: "pencil.line")
                    } description: {
                        Text(missingRule ? Self.missingRuleMessage : "新建规则，设置需要匹配的请求和要替换的返回值。")
                    } actions: { Button("新建规则") { navigate(.create) } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }.frame(width: 980, height: 760).controlSize(.small)
            .interactiveDismissDisabled(dirty || busy)
            .confirmationDialog("当前规则有未保存修改", isPresented: $showingUnsaved, titleVisibility: .visible) {
                Button("保存并继续") { Task { if await saveDraft(), let action = pending { perform(action) }; pending = nil } }
                    .disabled(!canSave)
                Button("放弃修改", role: .destructive) { if let action = pending { perform(action) }; pending = nil }
                Button("取消", role: .cancel) { pending = nil }
            } message: { Text("保存后才会影响后续请求。") }
            .confirmationDialog("删除这条规则？", isPresented: $showingDelete, titleVisibility: .visible) {
                Button("删除规则", role: .destructive) { Task { await deleteRule() } }
                Button("取消", role: .cancel) {}
            } message: { Text("历史请求中的原值和改写记录仍会保留。") }
            .onChange(of: settings) { _, next in
                if let baseline, !next.rules.contains(where: { $0.id == baseline.id }) {
                    missingRule = true; error = Self.missingRuleMessage
                } else if !dirty, !missingRule, let selectedID { load(next.rules.first { $0.id == selectedID }) }
            }
            .onChange(of: draft) { _, _ in clearPreview() }
            .onDisappear { previewTask?.cancel() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("已保存规则").font(.headline)
                Spacer()
                Button(action: { navigate(.create) }) { Image(systemName: "plus") }
                    .help("新建规则").disabled(busy || settings.rules.count >= 100)
            }.padding(.horizontal, 12).padding(.top, 14)
            List {
                ForEach(settings.rules) { rule in
                    Button { navigate(.select(rule.id)) } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(rule.enabled ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.name).fontWeight(.medium).lineLimit(2)
                                Text((rule.method.isEmpty ? "不限方法" : rule.method) + " " + rule.urlPattern)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).help(rule.urlPattern)
                                if !rule.notes.isEmpty { Text(rule.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(rule.notes) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .listRowBackground(selectedID == rule.id ? Color.accentColor.opacity(0.13) : Color.clear)
                }
                if baseline == nil, let draft {
                    Label(draft.name.isEmpty ? "未命名规则" : draft.name, systemImage: "pencil")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.listStyle(.sidebar)
            HStack(spacing: 10) {
                Button(action: { Task { await moveRule(-1) } }) { Image(systemName: "arrow.up") }.help("上移规则")
                    .disabled(dirty || busy || selectedIndex == nil || selectedIndex == 0)
                Button(action: { Task { await moveRule(1) } }) { Image(systemName: "arrow.down") }.help("下移规则")
                    .disabled(dirty || busy || selectedIndex == nil || selectedIndex == settings.rules.count - 1)
                Spacer()
                Button(action: { showingDelete = true }) { Image(systemName: "trash") }.help("删除规则")
                    .disabled(dirty || busy || baseline == nil)
            }.padding(.horizontal, 12)
            Text("按顺序匹配，首条命中的规则处理响应。规则随项目保存，清空抓包记录不会删除规则。")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private var selectedIndex: Int? { settings.rules.firstIndex { $0.id == selectedID } }
    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("规则名称（必填）").font(.headline)
                    TextField("例如：A 股行情 · 模拟清盘中", text: limited(\.name, count: 80)).textFieldStyle(.roundedBorder)
                }
                Toggle("启用这条规则", isOn: field(\.enabled, fallback: true)).padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("备注（可选）")
                TextEditor(text: limited(\.notes, count: 500)).font(.body).frame(height: 62)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                Text("记录用途或测试场景，最多 500 字。保存后下次继续使用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(busy)
    }
    private var matchingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("匹配哪些请求").font(.headline)
            HStack(spacing: 14) {
                Picker("请求方法", selection: field(\.method, fallback: "")) {
                    Text("不限").tag("")
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 175)
                Picker("URL 匹配", selection: field(\.urlMode, fallback: .path)) {
                    ForEach(ResponseRewriteURLMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            TextField("填写完整 URL 或路径，例如 /dfc/stock/rt", text: field(\.urlPattern, fallback: ""))
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            RewriteJSONEditor(title: "JSON 请求体条件（可空）", text: field(\.requestJSON, fallback: ""), placeholder: "{\"blocks\":[2000]}")
            Text("只匹配填写的字段；数组完整相等。参数留空表示不限制，不会自动匹配 URL 查询参数。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("URL 查询参数与更多条件") {
                VStack(alignment: .leading, spacing: 10) {
                    RewriteJSONEditor(title: "URL 查询参数条件（可空）", text: field(\.queryJSON, fallback: ""), placeholder: "{\"market\":\"sh\"}；重复参数使用字符串数组")
                    Text("查询参数按解码后的字符串比较；与请求体条件同时满足才命中。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(field(\.requestConditions, fallback: [])) { $condition in
                        HStack {
                            TextField("请求 JSON 路径", text: $condition.path).textFieldStyle(.roundedBorder)
                            Picker("操作", selection: $condition.operation) {
                                ForEach(ResponseRewriteRequestCondition.Operation.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(width: 100)
                            TextField("JSON 值", text: $condition.valueJSON).textFieldStyle(.roundedBorder).frame(width: 100)
                            Button { draft?.requestConditions.removeAll { $0.id == condition.id } } label: { Image(systemName: "minus.circle") }
                                .help("删除条件")
                        }
                    }
                    Button("添加请求字段条件", systemImage: "plus") { draft?.requestConditions.append(ResponseRewriteRequestCondition()) }
                        .disabled((draft?.requestConditions.count ?? 0) >= 32)
                }.padding(.top, 8)
            }
        }.disabled(busy)
    }
    private var replacementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("修改哪些返回值").font(.headline)
                Spacer()
                Button("添加替换项", systemImage: "plus") { draft?.actions.append(ResponseRewriteAction()) }
                    .disabled((draft?.actions.count ?? 0) >= 32)
            }
            if targetActionID == nil, let quickEntryMessage {
                Text(quickEntryMessage).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(field(\.actions, fallback: [])) { $action in
                VStack(alignment: .leading, spacing: 10) {
                    if targetActionID == action.id {
                        Label("快捷定位：" + Self.targetDescription(action), systemImage: "scope")
                            .font(.headline).textSelection(.enabled)
                        if let quickEntryMessage {
                            Text(quickEntryMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    RewriteActionEditor(action: $action, sample: suppliedSample,
                        canDelete: (draft?.actions.count ?? 0) > 1,
                        onDelete: {
                            draft?.actions.removeAll { $0.id == action.id }
                            if targetActionID == action.id { targetActionID = nil; quickEntryMessage = nil }
                        })
                }.padding(targetActionID == action.id ? 10 : 0)
                    .background(targetActionID == action.id ? Color.accentColor.opacity(0.07) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .id(action.id)
                if action.id != draft?.actions.last?.id { Divider() }
            }
            Text("仅替换现有值。所有替换项验证成功后一起应用；表头行保持不变。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(busy)
    }
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("样本试运行").font(.headline)
                Spacer()
                if previewWorking { ProgressView().controlSize(.small) }
                Button("试运行当前草稿") { testDraft() }.disabled(draft == nil || sampleResponse.isEmpty || previewWorking || busy)
            }
            Text("试运行不会发送请求，也不会改变已保存规则；真实改写最多处理 1 MB 的完整 JSON。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("样本请求与响应", isExpanded: $sampleExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("方法", text: $sampleMethod).frame(width: 75)
                        TextField("样本请求 URL", text: $sampleURL)
                    }.textFieldStyle(.roundedBorder)
                    RewriteJSONEditor(title: "样本请求正文", text: $sampleRequest, placeholder: "可粘贴请求 JSON")
                    RewriteJSONEditor(title: "样本响应正文", text: $sampleResponse, placeholder: "从请求列表创建规则可自动带入样本，也可以在这里粘贴 JSON", height: 110)
                }.padding(.top, 8)
            }
            if let previewError { Text(previewError).foregroundStyle(.red).textSelection(.enabled) }
            if let preview {
                if let summary = preview.summary {
                    Text(summary.title + (summary.reason.map { " · " + $0 } ?? ""))
                        .foregroundStyle(summary.state == .changed ? Color.orange : Color.secondary)
                } else { Text("请求条件未命中，响应保持原样。").foregroundStyle(.secondary) }
                if !preview.changes.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        GridRow { Text("字段位置"); Text("原始值"); Text("修改后") }.font(.caption).foregroundStyle(.secondary)
                        ForEach(preview.changes.prefix(20)) { change in
                            GridRow {
                                Text(change.path).lineLimit(2).help(change.path)
                                Text(change.originalJSON).lineLimit(3).help(change.originalJSON)
                                Text(change.replacementJSON).lineLimit(3).help("原始值：\(change.originalJSON)")
                                    .padding(3).background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    if preview.changes.count > 20 { Text("此处展示前 20 处，共 \(preview.changes.count) 处修改。").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .onChange(of: sampleMethod) { _, _ in clearPreview() }
        .onChange(of: sampleURL) { _, _ in clearPreview() }
        .onChange(of: sampleRequest) { _, _ in clearPreview() }
        .onChange(of: sampleResponse) { _, _ in clearPreview() }
    }
    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(missingRule ? "无法编辑" : draft == nil ? "未选择规则" : dirty ? "未保存" : "已保存")
                    .font(.caption).foregroundStyle(dirty ? Color.orange : Color.secondary)
                if let message = missingRule ? Self.missingRuleMessage : error ?? model.responseRewriteStatus[projectID] {
                    Text(message).font(.caption).foregroundStyle(error == nil && !missingRule ? Color.secondary : Color.red)
                        .lineLimit(2).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if busy { ProgressView().controlSize(.small) }
            Button("关闭") { navigate(.close) }.keyboardShortcut(.cancelAction).disabled(busy)
            Button("放弃修改") { load(baseline) }.disabled(!dirty || busy)
            Button("保存规则") { Task { _ = await saveDraft() } }.keyboardShortcut("s", modifiers: .command).disabled(!canSave)
                .buttonStyle(.borderedProminent)
        }.padding(14)
    }
    private func field<Value>(_ keyPath: WritableKeyPath<ResponseRewriteRule, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { draft?[keyPath: keyPath] ?? fallback }, set: { draft?[keyPath: keyPath] = $0; error = nil })
    }
    private func limited(_ keyPath: WritableKeyPath<ResponseRewriteRule, String>, count: Int) -> Binding<String> {
        Binding(get: { draft?[keyPath: keyPath] ?? "" }, set: { draft?[keyPath: keyPath] = String($0.prefix(count)); error = nil })
    }
    private func load(_ rule: ResponseRewriteRule?) {
        selectedID = rule?.id; draft = rule; baseline = rule
        targetActionID = nil; quickEntryMessage = nil
        missingRule = rule.map { saved in !settings.rules.contains { $0.id == saved.id } } ?? false
        error = missingRule ? Self.missingRuleMessage : nil; clearPreview()
    }
    private func navigate(_ action: Navigation) {
        guard !busy else { return }
        if dirty { pending = action; showingUnsaved = true } else { perform(action) }
    }
    private func perform(_ action: Navigation) {
        switch action {
        case .select(let id):
            let rule = settings.rules.first { $0.id == id }
            load(rule)
            if rule == nil { selectedID = id; missingRule = true; error = Self.missingRuleMessage }
        case .create:
            let rule = suppliedSample.map(Self.seed) ?? ResponseRewriteRule()
            selectedID = rule.id; draft = rule; baseline = nil; error = nil
            missingRule = false; targetActionID = nil; quickEntryMessage = nil; clearPreview()
        case .close: dismiss()
        }
    }
    private func saveSettings(_ next: ResponseRewriteSettings) async -> Bool {
        saving = true; error = nil
        defer { saving = false }
        return await model.saveResponseRewrite(next, projectID: projectID)
    }
    private func saveDraft() async -> Bool {
        guard var draft else { return false }
        guard !missingRule else { error = Self.missingRuleMessage; return false }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = settings
        if let baseline {
            guard let existing = next.rules.first(where: { $0.id == baseline.id }) else {
                missingRule = true; error = Self.missingRuleMessage; return false
            }
            if existing != baseline {
                error = "这条规则已在其他窗口修改，请放弃当前草稿后重新编辑。"; return false
            }
        }
        if let index = next.rules.firstIndex(where: { $0.id == draft.id }) { next.rules[index] = draft }
        else { next.rules.append(draft) }
        guard await saveSettings(next) else { return false }
        load(settings.rules.first { $0.id == draft.id }); return true
    }
    private func moveRule(_ delta: Int) async {
        guard let selectedIndex, settings.rules.indices.contains(selectedIndex + delta), !dirty else { return }
        var next = settings; next.rules.swapAt(selectedIndex, selectedIndex + delta)
        _ = await saveSettings(next)
    }
    private func deleteRule() async {
        guard let selectedID, !dirty else { return }
        var next = settings; next.rules.removeAll { $0.id == selectedID }
        if await saveSettings(next) { load(settings.rules.first) }
    }
    private func clearPreview() { previewTask?.cancel(); previewTask = nil; preview = nil; previewError = nil; previewWorking = false }
    private func testDraft() {
        guard var rule = draft, let sample = suppliedSample else { return }
        rule.enabled = true
        var configuration = ResponseRewriteSettings(); configuration.enabled = true; configuration.rules = [rule]
        clearPreview(); previewWorking = true
        previewTask = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ResponseRewriteEngine.preview(settings: configuration, method: sample.method, url: sample.url,
                        requestBody: sample.requestBody, responseBody: sample.responseBody)
                }.value
                guard !Task.isCancelled else { return }
                preview = result; previewWorking = false
            } catch {
                guard !Task.isCancelled else { return }
                previewError = error.localizedDescription; previewWorking = false
            }
        }
    }
    private static func seed(_ sample: ResponseRewriteSample) -> ResponseRewriteRule {
        var rule = ResponseRewriteRule(); rule.method = sample.method; rule.urlMode = .path
        rule.urlPattern = URLComponents(string: sample.url)?.percentEncodedPath ?? sample.url
        if rule.urlPattern.isEmpty { rule.urlPattern = "/" }
        rule.name = String((sample.method + " " + rule.urlPattern).prefix(80))
        if let table = RewriteSampleFields(data: sample.responseBody).tables.first {
            rule.actions[0].kind = .table; rule.actions[0].path = table.path
            rule.actions[0].column = ""; rule.actions[0].headerRow = 0
        }
        return rule
    }
    private static func sameTarget(_ lhs: ResponseRewriteAction, _ rhs: ResponseRewriteAction) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        if lhs.kind == .json { return ResponseRewriteEngine.pathsMatch(lhs.path, rhs.path) }
        return ResponseRewriteEngine.pathsEqual(lhs.path, rhs.path) && lhs.column == rhs.column && lhs.headerRow == rhs.headerRow
    }
    private static func targetDescription(_ action: ResponseRewriteAction) -> String {
        action.kind == .table ? "\(action.path) · 列「\(action.column)」· 表头第 \(action.headerRow + 1) 行" : action.path
    }
}

private struct RewriteJSONEditor: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var height: CGFloat = 62
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text).font(.system(.body, design: .monospaced))
                if text.isEmpty { Text(placeholder).font(.caption).foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) }
            }.frame(height: height).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
        }
    }
}

private struct RewriteActionEditor: View {
    @Binding var action: ResponseRewriteAction
    let sample: ResponseRewriteSample?
    let canDelete: Bool
    let onDelete: () -> Void
    @State private var fields = RewriteSampleFields(data: Data())
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("响应结构", selection: $action.kind) {
                    ForEach(ResponseRewriteAction.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 330)
                Spacer()
                Button(action: onDelete) { Image(systemName: "minus.circle") }.help("删除替换项").disabled(!canDelete)
            }
            HStack {
                TextField(action.kind == .table ? "表格路径，例如 $.body.symbols" : "字段路径，例如 $.body.items[*].isClearing", text: $action.path)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                if sample != nil {
                    Menu("从样本选择") {
                        if action.kind == .table {
                            ForEach(fields.tables, id: \.path) { table in
                                Button(table.path) { action.path = table.path; action.column = ""; action.headerRow = 0 }
                            }
                        } else {
                            ForEach(fields.paths, id: \.self) { path in Button(path) { action.path = path } }
                        }
                    }.fixedSize()
                }
            }
            if action.kind == .table {
                HStack(spacing: 12) {
                    Stepper("表头第 \(action.headerRow + 1) 行", value: $action.headerRow, in: 0...100).fixedSize()
                    TextField("请选择要修改的列", text: $action.column).textFieldStyle(.roundedBorder)
                    if let table = fields.tables.first(where: { $0.path == action.path }) {
                        Menu("样本列名") {
                            ForEach(Array(Set(table.columns)).sorted(), id: \.self) { name in Button(name) { action.column = name } }
                        }.fixedSize()
                    }
                }
                Text("按列修改表头后的数据行，不只修改右键选中的单元格。行条件留空时，整列的所有数据行都会改写。")
                    .font(.caption).foregroundStyle(.secondary)
                RewriteJSONEditor(title: "仅修改满足条件的数据行（可空）", text: $action.rowConditionsJSON,
                    placeholder: "留空修改全部数据行；例如 {\"code\":\"600000\"}")
            } else {
                Text("支持 .字段、[下标]、[\"含特殊字符的字段\"] 和 [*]；只替换已有值。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            RewriteValueEditor(valueJSON: $action.valueJSON)
        }
        .task(id: sample?.responseBody) {
            let bytes = sample?.responseBody ?? Data()
            let suggestions = await Task.detached(priority: .utility) { RewriteSampleFields(data: bytes) }.value
            guard !Task.isCancelled else { return }
            fields = suggestions
        }
        .onChange(of: action.kind) { _, kind in
            if kind == .table, let table = fields.tables.first { action.path = table.path; action.column = ""; action.headerRow = 0 }
        }
    }
}

private struct RewriteValueEditor: View {
    @Binding var valueJSON: String
    @State private var kind: Kind
    @FocusState private var editing: Bool
    private enum Kind: String, CaseIterable {
        case boolean, string, number, null, json
        var title: String {
            switch self {
            case .boolean: return "布尔 Boolean"
            case .string: return "字符串 String"
            case .number: return "数字 Number"
            case .null: return "空值 Null"
            case .json: return "JSON 对象 / 数组"
            }
        }
        static func infer(_ value: String) -> Kind {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "true" || text == "false" { return .boolean }
            if text == "null" { return .null }
            if text.first == "\"" { return .string }
            if let first = text.first, "-0123456789".contains(first) { return .number }
            return .json
        }
    }
    init(valueJSON: Binding<String>) {
        _valueJSON = valueJSON; _kind = State(initialValue: Kind.infer(valueJSON.wrappedValue))
    }
    private var stringValue: Binding<String> {
        Binding(get: {
            (try? JSONSerialization.jsonObject(with: Data(valueJSON.utf8), options: [.fragmentsAllowed])) as? String ?? ""
        }, set: { value in
            if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) {
                valueJSON = String(decoding: bytes, as: UTF8.self)
            }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("替换成")
            HStack(alignment: .top, spacing: 12) {
                Picker("新值类型", selection: Binding(get: { kind }, set: { next in
                    guard next != kind else { return }
                    kind = next
                    switch next {
                    case .boolean: valueJSON = "true"
                    case .string: valueJSON = "\"\""
                    case .number: valueJSON = "0"
                    case .null: valueJSON = "null"
                    case .json: valueJSON = "{}"
                    }
                })) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 170)
                switch kind {
                case .boolean:
                    Picker("布尔值", selection: $valueJSON) { Text("true").tag("true"); Text("false").tag("false") }
                        .labelsHidden().frame(width: 120)
                case .string:
                    TextField("输入字符串，无需手动加双引号", text: stringValue).textFieldStyle(.roundedBorder).focused($editing)
                case .number:
                    TextField("例如 0、3.14 或 1e6", text: $valueJSON).textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced)).focused($editing)
                case .null:
                    Text("null").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .json:
                    TextEditor(text: $valueJSON).font(.system(.body, design: .monospaced)).frame(height: 62).focused($editing)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                }
            }
            Text("类型会保留：布尔 true 与字符串 \"true\" 不同。")
                .font(.caption).foregroundStyle(.secondary)
        }.onChange(of: valueJSON) { _, value in if !editing { kind = Kind.infer(value) } }
    }
}

/// Bounded suggestions only. Actual validation and rewriting use the core lexer.
private struct RewriteSampleFields: Sendable {
    struct Table: Sendable { let path: String; let columns: [String] }
    var tables: [Table] = []
    var paths: [String] = []
    init(data: Data) {
        guard data.count <= 1024 * 1024, let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
        func appendKey(_ path: String, _ key: String) -> String {
            if !key.isEmpty, !key.contains(where: { ".[]\"\\".contains($0) }) { return path + "." + key }
            let quoted = (try? JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
            return path + "[" + quoted + "]"
        }
        func visit(_ value: Any, _ path: String, _ depth: Int) {
            guard depth < 32, paths.count < 200 else { return }
            if let array = value as? [Any] {
                if let header = array.first as? [String], !header.isEmpty, array.dropFirst().allSatisfy({ $0 is [Any] }), tables.count < 20 {
                    tables.append(Table(path: path, columns: Array(header.prefix(256))))
                }
                for (index, child) in array.prefix(3).enumerated() { visit(child, path + "[\(index)]", depth + 1) }
            } else if let object = value as? [String: Any] {
                for key in object.keys.sorted() { visit(object[key]!, appendKey(path, key), depth + 1) }
            } else { paths.append(path) }
        }
        visit(root, "$", 0)
    }
}
