import SwiftUI
import RunbarCore

struct LogToolsView: View {
    @ObservedObject var model: AppModel
    @State private var editingFilter = false
    @State private var choosingPreset = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) { filterButton; presetButton; searchField; searchNavigation }
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
        .popover(isPresented: $editingFilter, arrowEdge: .bottom) { LogFilterPopover(model: model) }
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
            if !model.logFilter.isEmpty {
                Button { _ = model.applyLogFilter(LogFilter()) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("清除当前筛选，保留关键词缓存和方案").accessibilityLabel("清除日志筛选")
            }
        }.fixedSize()
    }
    private var presetButton: some View {
        Button { choosingPreset.toggle() } label: { Image(systemName: "bookmark") }
            .accessibilityLabel("筛选方案").help("一键使用或保存筛选方案")
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
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("筛选方案").font(.headline)
            if model.logPreferences.presets.isEmpty { Text("保存当前条件，下次一键使用").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(model.logPreferences.presets) { preset in
                        HStack {
                            Button {
                                if model.applyLogFilter(preset.filter) { dismiss() }
                            } label: {
                                HStack {
                                    Text(preset.name).lineLimit(1)
                                    Spacer()
                                    if preset.filter == model.logFilter { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("使用筛选方案 \(preset.name)")
                            Button { model.deleteLogFilterPreset(preset.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).accessibilityLabel("删除方案 \(preset.name)")
                        }.padding(.vertical, 4)
                    }
                }
            }.frame(height: min(190, CGFloat(model.logPreferences.presets.count) * 29))
            Divider()
            HStack {
                TextField("新方案名称", text: $name).onSubmit { save() }.accessibilityLabel("筛选方案名称")
                Button("保存") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(14).frame(width: 300).controlSize(.small)
    }
    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.saveLogFilterPreset(name); name = ""
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
