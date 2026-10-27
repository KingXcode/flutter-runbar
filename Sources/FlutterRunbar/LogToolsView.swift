import SwiftUI
import RunbarCore

struct LogToolsView<Navigation: View>: View {
    @ObservedObject var model: AppModel
    @ViewBuilder var navigation: Navigation
    @State private var editingFilter = false
    @State private var choosingPreset = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LogToolbarLayout {
                HStack(spacing: 6) { filterButton; presetButton; searchField; searchNavigation }
                navigation
            }
            if model.logQueryBusy {
                HStack(spacing: 8) {
                    ProgressView(value: model.logQueryProgress).frame(maxWidth: 120)
                    Text("正在扫描日志 \(Int(model.logQueryProgress * 100))%")
                    Button("取消搜索与筛选") { model.logSearchText = ""; _ = model.applyLogFilter(LogFilter()) }
                        .buttonStyle(.borderless)
                }.font(.caption).foregroundStyle(.secondary)
            } else if model.logSearchContext && !model.logFilter.isEmpty {
                HStack(spacing: 6) {
                    Text("搜索结果上下文 · 显示全部日志")
                    Button("返回筛选结果") { model.returnToFilteredLog() }.buttonStyle(.borderless)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
    }
    private var filterButton: some View {
        HStack(spacing: 4) {
            Button { editingFilter = true } label: {
                Label(model.logFilter.isEmpty ? "筛选" : "筛选 \(model.logFilter.includes.count + model.logFilter.excludes.count + (model.logFilter.hasTimeRange ? 1 : 0))",
                      systemImage: model.logFilter.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            }.accessibilityLabel("编辑日志筛选").help("关键词回车生效，支持时间段筛选")
                .popover(isPresented: $editingFilter, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    LogFilterPopover(model: model)
                }
            if !model.logFilter.isEmpty {
                Button { _ = model.applyLogFilter(LogFilter()) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("清除当前筛选，保留关键词缓存和方案").accessibilityLabel("清除日志筛选")
            }
        }.fixedSize()
    }
    private var presetButton: some View {
        Button { choosingPreset.toggle() } label: {
            Image(systemName: model.logPreferences.selectedPresetIDs.isEmpty ? "bookmark" : "bookmark.fill")
        }
            .accessibilityLabel("筛选方案").help("多选方案联合使用，点击已选方案可取消；也可保存当前条件")
            .popover(isPresented: $choosingPreset, arrowEdge: .bottom) { LogFilterPresets(model: model) }
    }
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索全部日志（区分大小写）", text: $model.logSearchText)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel("搜索全部日志")
                .onSubmit { model.moveLogSearch(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
            if !model.logSearchText.isEmpty {
                Button { model.logSearchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除日志搜索")
            }
        }.padding(.horizontal, 7).padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
            .frame(minWidth: 80, maxWidth: .infinity)
            .help("搜索完整原始日志，不受筛选条件影响。按 Enter / Shift+Enter 切换下一个 / 上一个结果。")
    }
    private var searchNavigation: some View {
        HStack(spacing: 5) {
            Text(model.logSearchText.isEmpty ? "" : "\(model.logMatchOrdinal) / \(model.logMatchCount)")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityLabel("搜索结果 \(model.logMatchCount) 个，当前第 \(model.logMatchOrdinal) 个")
                .help("当前结果 / 全部结果；按字面匹配，不重复计算重叠的命中")
            Button { model.moveLogSearch(-1) } label: { Image(systemName: "chevron.up") }
                .help("上一个结果（Shift+Enter）").accessibilityLabel("上一个搜索结果")
            Button { model.moveLogSearch(1) } label: { Image(systemName: "chevron.down") }
                .help("下一个结果（Enter）").accessibilityLabel("下一个搜索结果")
        }.disabled(model.logQueryBusy || model.logMatchCount == 0).fixedSize(horizontal: false, vertical: true)
    }
}

/// Measure the controls rather than the window: keep a useful search field on
/// wide panes, and use two rows only when the combined controls no longer fit.
/// A Layout keeps one instance of each control (and its focused popover).
private struct LogToolbarLayout: Layout {
    private let spacing: CGFloat = 8
    private let rowSpacing: CGFloat = 5
    private func metrics(_ proposal: ProposedViewSize, _ views: Subviews) -> (CGFloat, CGSize, CGSize, Bool) {
        let navigation = views[1].sizeThatFits(.unspecified)
        let minimumQuery = views[0].sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
        let width = proposal.width ?? minimumQuery + 100 + spacing + navigation.width
        let single = width >= minimumQuery + 100 + spacing + navigation.width
        let query = views[0].sizeThatFits(ProposedViewSize(width: single ? width - navigation.width - spacing : width, height: nil))
        let controls = views[1].sizeThatFits(ProposedViewSize(width: single ? navigation.width : width, height: nil))
        return (width, query, controls, single)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (width, query, controls, single) = metrics(proposal, subviews)
        return CGSize(width: width, height: single ? max(query.height, controls.height) : query.height + rowSpacing + controls.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (_, query, controls, single) = metrics(ProposedViewSize(width: bounds.width, height: nil), subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (single ? (bounds.height - query.height) / 2 : 0)),
                          proposal: ProposedViewSize(width: single ? bounds.width - controls.width - spacing : bounds.width, height: query.height))
        subviews[1].place(at: CGPoint(x: single ? bounds.maxX - controls.width : bounds.minX,
                                     y: single ? bounds.minY + (bounds.height - controls.height) / 2 : bounds.minY + query.height + rowSpacing),
                          proposal: ProposedViewSize(width: single ? controls.width : bounds.width, height: controls.height))
    }
}

private struct LogFilterPopover: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("筛选").font(.headline)
                Spacer()
                Button("清空") { _ = model.applyLogFilter(LogFilter()) }.disabled(model.logFilter.isEmpty)
                    .buttonStyle(.borderless)
            }
            LogKeywordField(title: "包含", words: Binding(get: { model.logFilter.includes }, set: {
                var filter = model.logFilter; filter.includes = $0; _ = model.applyLogFilter(filter)
            }), model: model)
            LogKeywordField(title: "排除", words: Binding(get: { model.logFilter.excludes }, set: {
                var filter = model.logFilter; filter.excludes = $0; _ = model.applyLogFilter(filter)
            }), model: model)
            Divider()
            Toggle("限定时间段", isOn: Binding(get: { model.logFilter.hasTimeRange }, set: { enabled in
                var filter = model.logFilter
                filter.from = enabled ? second(model.session?.startedAt ?? Date()) : nil
                filter.through = enabled ? max(filter.from!, second(model.session?.endedAt ?? Date())) : nil
                _ = model.applyLogFilter(filter)
            })).toggleStyle(.checkbox)
            if model.logFilter.hasTimeRange {
                HStack {
                    Text("从").foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                    LogDateField(date: dateBinding(start: true)).accessibilityLabel("筛选开始时间")
                }
                HStack {
                    Text("到").foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                    LogDateField(date: dateBinding(start: false)).accessibilityLabel("筛选结束时间")
                }
            }
            Text("回车添加，点 × 移除，自动生效并保存。排除优先，区分大小写。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.logPreferences.selectedPresetIDs.isEmpty {
                Text("正在联合使用方案；手动修改后将转为自定义条件，原方案保持不变。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).frame(width: 410).controlSize(.small)
    }
    private func dateBinding(start: Bool) -> Binding<Date> {
        Binding(get: {
            (start ? model.logFilter.from : model.logFilter.through) ?? model.session?.startedAt ?? Date()
        }, set: { value in
            let date = second(value)
            var filter = model.logFilter
            if start {
                filter.from = date
                if let end = filter.through, end < date { filter.through = date }
            } else {
                filter.through = date
                if let from = filter.from, from > date { filter.from = date }
            }
            _ = model.applyLogFilter(filter)
        })
    }
    private func second(_ value: Date) -> Date { Date(timeIntervalSince1970: floor(value.timeIntervalSince1970)) }
}

private struct LogKeywordField: View {
    let title: String
    @Binding var words: [String]
    @ObservedObject var model: AppModel
    @State private var entry = ""
    @State private var recent = false
    @State private var validation: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(title).frame(width: 34, alignment: .leading).foregroundStyle(.secondary)
                TextField("关键词，回车添加", text: $entry).onSubmit { commit() }
                    .accessibilityLabel("\(title)关键词")
                Button { recent.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(.borderless).help("最近使用的关键词").accessibilityLabel("\(title)最近关键词")
                    .popover(isPresented: $recent) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("最近关键词").font(.headline)
                            if model.logPreferences.keywords.isEmpty { Text("暂无关键词").foregroundStyle(.secondary) }
                            ScrollView {
                                LazyVStack(spacing: 4) {
                                    ForEach(model.logPreferences.keywords, id: \.self) { word in
                                        HStack {
                                            Button { add(word); recent = false } label: {
                                                Text(word).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                            }.buttonStyle(.plain).help(word)
                                            Button { model.deleteLogKeyword(word) } label: { Image(systemName: "xmark") }
                                                .buttonStyle(.borderless).accessibilityLabel("删除缓存关键词 \(word)")
                                        }.padding(.vertical, 4)
                                    }
                                }
                            }.frame(height: min(190, CGFloat(model.logPreferences.keywords.count) * 29))
                        }.padding(12).frame(width: 270)
                    }
            }
            if !words.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(words, id: \.self) { word in
                            HStack(spacing: 4) {
                                Text(word).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180).help(word)
                                Button { words.removeAll { $0 == word } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }
                                    .buttonStyle(.plain).accessibilityLabel("移除\(title)关键词 \(word)")
                            }.font(.caption).padding(.horizontal, 7).padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                        }
                    }
                }.padding(.leading, 41).frame(height: 25)
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
        }
    }
    private func commit() { guard !entry.isEmpty else { return }; if add(entry) { entry = "" } }
    @discardableResult private func add(_ word: String) -> Bool {
        do { words = try LogFilter(includes: words + [word]).validated().includes; validation = nil; return true }
        catch { validation = error.localizedDescription; return false }
    }
}

private struct LogFilterPresets: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var validation: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("筛选方案").font(.headline)
            Text("可多选，包含 / 排除词分别合并，时间取交集。")
                .font(.caption).foregroundStyle(.secondary)
            if model.logPreferences.presets.isEmpty { Text("保存当前条件，下次一键使用").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(model.logPreferences.presets) { preset in
                        HStack {
                            Button {
                                validation = model.toggleLogFilterPreset(preset.id)
                            } label: {
                                HStack {
                                    Image(systemName: model.logPreferences.selectedPresetIDs.contains(preset.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(model.logPreferences.selectedPresetIDs.contains(preset.id) ? Color.accentColor : .secondary)
                                    Text(preset.name).lineLimit(1)
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("使用筛选方案 \(preset.name)")
                                .accessibilityValue(model.logPreferences.selectedPresetIDs.contains(preset.id) ? "已选中" : "未选中")
                            Button { model.deleteLogFilterPreset(preset.id); validation = nil } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).accessibilityLabel("删除方案 \(preset.name)")
                        }.padding(.vertical, 4)
                    }
                }
            }.frame(height: min(190, CGFloat(model.logPreferences.presets.count) * 29))
            if let validation { Text(validation).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                TextField("新方案名称", text: $name).onSubmit { save() }.accessibilityLabel("筛选方案名称")
                Button("保存") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(14).frame(width: 300).controlSize(.small)
    }
    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if model.saveLogFilterPreset(name) { name = ""; validation = nil }
    }
}

private struct LogDateField: NSViewRepresentable {
    @Binding var date: Date
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker(); picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]; picker.controlSize = .small
        picker.target = context.coordinator; picker.action = #selector(Coordinator.changed(_:))
        return picker
    }
    func updateNSView(_ picker: NSDatePicker, context: Context) { context.coordinator.parent = self; picker.dateValue = date }
    final class Coordinator: NSObject {
        var parent: LogDateField
        init(_ parent: LogDateField) { self.parent = parent }
        @objc func changed(_ picker: NSDatePicker) { parent.date = picker.dateValue }
    }
}
