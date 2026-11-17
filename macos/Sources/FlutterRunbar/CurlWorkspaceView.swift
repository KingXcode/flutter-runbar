import AppKit
import SwiftUI
import RunbarCore
import UniformTypeIdentifiers

struct CurlProjectSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workspace: CurlWorkspaceModel
    let add: () -> Void
    let rename: (CurlProject) -> Void
    let remove: (CurlProject) -> Void

    var body: some View {
        Section {
            ForEach(workspace.projects) { project in
                let selected = model.selectedCurlProject == project.id
                Button { model.selectCurlProject(project.id) } label: {
                    Label {
                        Text(project.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    } icon: {
                        Image(systemName: "terminal")
                            .foregroundStyle(selected ? Color.accentColor : .secondary).frame(width: 18)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .listRowBackground(selected ? Color.accentColor.opacity(0.12) : Color.clear)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu {
                        Button("重命名…") { rename(project) }
                        Button("移除 cURL 项目…", role: .destructive) { remove(project) }
                            .disabled(workspace.sendingProject == project.id)
                    }
            }
            if workspace.projects.isEmpty {
                Button(action: add) {
                    Label("添加 cURL 项目…", systemImage: "plus").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("cURL 项目")
                Spacer()
                Button(action: add) { Image(systemName: "plus").padding(4) }
                    .buttonStyle(.borderless).accessibilityLabel("新建 cURL 项目").help("新建 cURL 项目")
            }
        }
    }
}

struct CurlProjectNameView: View {
    let title: String
    let action: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    @State private var error: String?

    init(title: String, name: String, action: @escaping (String) throws -> Void) {
        self.title = title; self.action = action
        _name = State(initialValue: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("项目名称", text: $name).textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("保存") {
                    do { try action(name); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
            }
        }.padding(20).frame(width: 350)
    }
}

struct CurlWorkspaceView: View {
    @ObservedObject var workspace: CurlWorkspaceModel
    let projectID: UUID
    let initialRequestOffset: Int?
    let rename: (CurlProject) -> Void

    @State private var parsed = CurlDocument("")
    @State private var parsedText = ""
    @State private var caret = 0
    @State private var jump: CurlTextEditor.Jump?
    @State private var history: [CurlRun] = []
    @State private var selectedRun: CurlRun?
    @State private var loadedResponse: (run: UUID, response: CurlResponse)?
    @State private var loadFailure: (run: UUID, message: String)?
    @State private var viewingHistory = false
    @State private var clearingHistory = false
    @State private var error: String?

    private var project: CurlProject? { workspace.project(projectID) }
    private var text: String { project?.text ?? "" }
    private var block: CurlDocument.Block? { parsedText == text ? parsed.block(at: caret) : nil }
    private var sending: Bool { workspace.sendingProject == projectID }
    private var response: CurlResponse? { loadedResponse?.run == selectedRun?.id ? loadedResponse?.response : nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal").font(.title2).foregroundStyle(.tint)
                Text(project?.name ?? "cURL 项目").font(.headline).lineLimit(1)
                Button {
                    if let project { rename(project) }
                } label: {
                    Image(systemName: "pencil")
                }.buttonStyle(.borderless).accessibilityLabel("重命名 cURL 项目")
                Spacer()
                Menu {
                    Button("导入请求文本…", action: importText)
                    if let request = block?.request {
                        Button("复制为 cURL") { copy(request.curlText) }
                    }
                    if let selectedRun {
                        Button("将所选请求追加到编辑区") { append(selectedRun.request.curlEditorText) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .fixedSize().accessibilityLabel("cURL 项目操作")
            }.padding(.horizontal, 13).padding(.vertical, 10)
            Divider()
            if let issue = error ?? workspace.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(issue).lineLimit(2).help(issue)
                    Spacer()
                    Button {
                        error = nil; workspace.error = nil
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("关闭提示")
                }.font(.caption).padding(8)
                Divider()
            }
            HSplitView {
                editorPane.frame(minWidth: 275, idealWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
                resultPane.frame(minWidth: 275, idealWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(Color(nsColor: .windowBackgroundColor))
            .controlSize(.small)
            .onAppear {
                if let initialRequestOffset {
                    caret = initialRequestOffset
                    jump = .init(offset: caret)
                }
            }
            .task(id: text) {
                let current = text
                do {
                    try await Task.sleep(for: .milliseconds(100))
                    let document = await Task.detached(priority: .userInitiated) { CurlDocument(current) }.value
                    guard !Task.isCancelled else { return }
                    parsed = document; parsedText = current
                } catch {}
            }
            .task(id: workspace.latest?.run.id) { await refreshHistory() }
            .task(id: selectedRun?.id) {
                loadedResponse = nil; loadFailure = nil
                guard let run = selectedRun else { return }
                do {
                    let value = try await workspace.response(run, project: projectID)
                    guard !Task.isCancelled else { return }
                    if let value { loadedResponse = (run.id, value) }
                } catch {
                    guard !Task.isCancelled else { return }
                    loadFailure = (run.id, "无法读取响应：\(error.localizedDescription)")
                }
            }
            .onDisappear { workspace.flush() }
            .confirmationDialog("清除这个项目的发送历史？", isPresented: $clearingHistory, titleVisibility: .visible) {
                Button("移到废纸篓", role: .destructive) {
                    do {
                        try workspace.clearHistory(projectID)
                        history = []; selectedRun = nil; loadedResponse = nil
                    } catch { self.error = error.localizedDescription }
                }
            } message: { Text("编辑区里的请求会保留。") }
    }

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("请求编辑").font(.headline)
                Spacer()
                if parsed.blocks.count > 1, parsedText == text {
                    Menu {
                        ForEach(parsed.blocks) { candidate in
                            Button(title(candidate)) {
                                caret = candidate.range.location
                                jump = .init(offset: caret)
                            }
                        }
                    } label: {
                        Text(block.map(title) ?? "选择请求").lineLimit(1).truncationMode(.middle)
                    }.accessibilityLabel("选择要发送的请求")
                }
            }.frame(height: 24)
            CurlTextEditor(text: Binding(get: { text }, set: { workspace.edit(projectID, text: $0) }),
                           caret: $caret, jump: jump, maximumBytes: CurlDocument.maximumBytes,
                           onLimit: { error = "编辑区最多支持 256 KiB 的文本。" })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("curl 'https://example.com/'")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 14).padding(.vertical, 10).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)).allowsHitTesting(false))
            HStack(spacing: 7) {
                if sending {
                    ProgressView().controlSize(.small)
                    Text("正在发送…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消请求") { workspace.cancel(projectID) }
                } else if let request = block?.request {
                    Text(request.method).font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    Text(request.url.absoluteString).lineLimit(1).truncationMode(.middle)
                        .font(.caption).foregroundStyle(.secondary).help(request.url.absoluteString)
                    Spacer(minLength: 3)
                    Button("发送请求", systemImage: "paperplane.fill", action: sendActiveRequest)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                        .disabled(workspace.sendingProject != nil).help("发送光标所在的请求（⌘↩）")
                } else {
                    Text((parsedText == text ? (block?.error ?? parsed.error) : nil) ??
                         (text.isEmpty ? "粘贴 cURL，或输入 HTTP 请求" : "用 ### 分隔多条请求"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 3)
                    if text.isEmpty { Button("插入示例") { append("curl 'https://example.com/'") } }
                }
            }.frame(minHeight: 27)
            Text("自动保存 · 用 ### 分隔请求，点击请求中的任意一行来切换")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }.padding(11)
    }

    private var resultPane: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("返回结果").font(.headline)
                Spacer()
                Button("历史", systemImage: "clock.arrow.circlepath") { viewingHistory.toggle() }
                    .accessibilityLabel("cURL 发送历史").popover(isPresented: $viewingHistory, arrowEdge: .bottom) { historyPopover }
                if selectedRun != nil {
                    Button("重发", systemImage: "arrow.clockwise", action: resendSelected)
                        .disabled(workspace.sendingProject != nil).help("原样重发右侧所选的历史请求")
                }
                if let response, let run = selectedRun {
                    responseMenu(response, run: run)
                }
            }.frame(height: 24)

            if let response, let run = selectedRun {
                CurlResultView(run: run, response: response).id(run.id)
            } else if let issue = selectedRun?.error ?? (loadFailure?.run == selectedRun?.id ? loadFailure?.message : nil) {
                ContentUnavailableView {
                    Label("请求未完成", systemImage: "exclamationmark.circle")
                } description: {
                    Text(issue).textSelection(.enabled)
                }
            } else if selectedRun?.response != nil || sending {
                ProgressView(sending ? "正在等待响应…" : "正在读取响应…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("等待请求", systemImage: "arrow.left.to.line",
                                       description: Text("在左侧发送请求后，这里显示响应头和正文。"))
            }
        }.padding(11)
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("发送历史").font(.headline)
                Spacer()
                Button("清除历史…") { viewingHistory = false; clearingHistory = true }
                    .disabled(history.isEmpty || sending)
            }
            if history.isEmpty {
                Text("尚未发送请求").foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(history) { run in
                            Button {
                                selectedRun = run; viewingHistory = false
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Text(run.request.method).font(.system(.caption, design: .monospaced).weight(.semibold))
                                        if let status = run.response?.status {
                                            Text(String(status)).foregroundStyle(status >= 400 ? .red : .secondary)
                                        } else { Text(run.error == "已取消请求。" ? "已取消" : "失败").foregroundStyle(.orange) }
                                        Spacer()
                                        Text(run.date.formatted(.dateTime.month().day().hour().minute().second()
                                            .locale(Locale(identifier: "zh_CN"))))
                                            .foregroundStyle(.secondary)
                                    }.font(.caption)
                                    Text(run.request.url.absoluteString).font(.caption).lineLimit(1).truncationMode(.middle)
                                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(run.id == selectedRun?.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 4))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: min(320, CGFloat(history.count) * 43))
            }
        }.padding(12).frame(width: 360)
    }

    private func title(_ block: CurlDocument.Block) -> String {
        if !block.title.isEmpty { return block.title }
        if let req = block.request { return "\(block.id + 1). \(req.method) \(req.url.path.isEmpty ? "/" : req.url.path)" }
        return "请求 \(block.id + 1)"
    }

    private func sendActiveRequest() {
        guard let request = block?.request else { return }
        workspace.send(request, project: projectID)
    }

    private func resendSelected() {
        guard let request = selectedRun?.request else { return }
        workspace.send(request, project: projectID)
    }

    private func append(_ value: String) {
        let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text + "\n\n###\n"
        let next = prefix + value
        guard next.utf8.count <= CurlDocument.maximumBytes else { error = "编辑区最多支持 256 KiB 的文本。"; return }
        workspace.edit(projectID, text: next)
        caret = prefix.utf16.count
        jump = .init(offset: caret)
    }

    private func importText() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "导入 cURL 或 .http 文本到编辑区末尾"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= CurlDocument.maximumBytes,
                      let value = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                    throw RunbarError.message("请选择不超过 256 KiB 的 UTF-8 请求文本。")
                }
                append(value)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func refreshHistory() async {
        do {
            let disk = try await workspace.history(projectID)
            guard !Task.isCancelled else { return }
            if let latest = workspace.latest, latest.project == projectID {
                history = [latest.run] + disk.filter { $0.id != latest.run.id }
                selectedRun = latest.run
            } else {
                history = disk
                if selectedRun == nil || !disk.contains(where: { $0.id == selectedRun?.id }) { selectedRun = disk.first }
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "无法读取请求历史：\(error.localizedDescription)"
            if let latest = workspace.latest, latest.project == projectID { selectedRun = latest.run }
        }
    }

    private func responseMenu(_ response: CurlResponse, run: CurlRun) -> some View {
        Menu {
            Button("复制正文") { copy(String(decoding: response.body, as: UTF8.self)) }
                .disabled(response.body.isEmpty || response.body.count > 1024 * 1024 ||
                          NetworkMediaPreview.Kind(contentType: response.head.contentType,
                                                   filename: response.export(url: run.request.url).filename) != nil)
            Button("复制响应头") { copy(response.head.headers) }
            Button("导出响应正文…") { save(response, url: run.request.url, includeHeaders: false) }
                .disabled(response.body.isEmpty)
            Button("导出响应头和正文…") { save(response, url: run.request.url, includeHeaders: true) }
        } label: { Image(systemName: "square.and.arrow.down") }
            .fixedSize().accessibilityLabel("复制或导出响应")
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func save(_ response: CurlResponse, url: URL, includeHeaders: Bool) {
        let file = response.export(url: url)
        let panel = NSSavePanel()
        panel.title = "导出响应"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = includeHeaders ? "response.http" : file.filename
        panel.begin { result in
            guard result == .OK, let destination = panel.url else { return }
            Task {
                do {
                    try await Task.detached(priority: .utility) {
                        if includeHeaders {
                            var data = Data((response.head.headers.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n").utf8)
                            data.append(response.body)
                            try data.write(to: destination, options: .atomic)
                        } else { try file.write(to: destination) }
                    }.value
                } catch { self.error = "导出失败：\(error.localizedDescription)" }
            }
        }
    }
}

private struct CurlResultView: View {
    enum Tab: String { case body, headers, media }
    let run: CurlRun
    let response: CurlResponse
    @State private var tab: Tab = .body
    @State private var format: NetworkBodyFormat = .raw
    @State private var wraps = true
    @State private var bodyText = ""
    @State private var bodyNote: String?
    private var file: NetworkResponseExport { response.export(url: run.request.url) }
    private var media: NetworkMediaPreview.Kind? { .init(contentType: response.head.contentType, filename: file.filename) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                let status = response.head.status
                let tone: Color = status >= 400 ? .red : status >= 300 ? .orange : .green
                Text(String(status)).font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(tone).padding(.horizontal, 6).padding(.vertical, 4)
                    .background(tone.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
                    .help(response.head.statusLine)
                Text("\(Int(response.head.duration * 1000)) ms").monospacedDigit()
                Text(ByteCountFormatter.string(fromByteCount: Int64(response.head.bytes), countStyle: .file))
                Spacer(minLength: 0)
            }.font(.caption).foregroundStyle(.secondary)
            Picker("响应内容", selection: $tab) {
                Text("正文").tag(Tab.body)
                Text("Headers").tag(Tab.headers)
                if media != nil { Text("预览").tag(Tab.media) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            if tab == .media, let media {
                NetworkMediaPreview(kind: media, requestID: run.id, contentType: response.head.contentType) { file }
            } else {
                if tab == .body {
                    HStack {
                        Picker("正文格式", selection: $format) {
                            ForEach([NetworkBodyFormat.json, .xml, .raw], id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 90)
                        Spacer()
                        Toggle("自动换行", isOn: $wraps).toggleStyle(.checkbox).fixedSize()
                    }
                }
                NetworkTextView(text: tab == .headers ? response.head.headers : bodyText, wrapsLines: wraps)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)).allowsHitTesting(false))
                if tab == .body, let bodyNote {
                    Text(bodyNote).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(bodyNote)
                }
            }
        }.onAppear {
            let mime = response.head.contentType.lowercased()
            if mime.contains("json") { format = .json }
            if mime.contains("xml") { format = .xml }
            if media != nil { tab = .media }
        }.task(id: format) {
            let body = response.body, format = format
            let display = await Task.detached(priority: .utility) { Self.display(body, format: format) }.value
            guard !Task.isCancelled else { return }
            bodyText = display.0; bodyNote = display.1
        }
    }

    nonisolated private static func display(_ body: Data, format: NetworkBodyFormat) -> (String, String?) {
        guard !body.isEmpty else { return ("（正文为空）", nil) }
        var note: String?
        var data = body
        if format != .raw {
            do { data = try NetworkBodyFormatter.format(body, as: format) }
            catch { note = error.localizedDescription }
        }
        let sample = Data(data.prefix(512 * 1024))
        var text = String(data: sample, encoding: .utf8)
        // A text preview can end in the middle of a multibyte character.
        if text == nil, data.count > sample.count {
            for extra in 1...3 {
                if let decoded = String(data: sample.dropLast(extra), encoding: .utf8) { text = decoded; break }
            }
        }
        if let text, !sample.contains(0) {
            if data.count > sample.count { note = [note, "仅预览前 512 KiB，可导出完整正文。"].compactMap { $0 }.joined(separator: " ") }
            return (text, note)
        }
        let hex = body.prefix(1024).enumerated().map { index, byte in
            String(format: "%02x%@", byte, (index + 1).isMultiple(of: 16) ? "\n" : " ")
        }.joined()
        return (hex, "二进制正文，显示前 \(min(1024, body.count)) 字节。可导出完整正文。")
    }
}
