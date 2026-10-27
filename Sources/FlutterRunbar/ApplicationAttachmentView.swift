import SwiftUI
import AppKit
import RunbarCore

struct ApplicationConnectionState {
    let generation = UUID()
    enum Phase { case connecting, listening, disconnecting, idle }
    var phase = Phase.idle
    var sessionID: UUID?
    var candidate: RunningApplicationCandidate?
    var endpoint: VMServiceEndpoint?
    var devToolsURL: URL?
    var message = "未连接"
    var active: Bool { phase != .idle }
}

struct ApplicationPickerView: View {
    @ObservedObject var model: AppModel
    var preferredApplication: ApplicationTarget?
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [RunningApplicationCandidate] = []
    @State private var selectedPID: Int32?
    @State private var search = ""
    @State private var address = ""
    @State private var endpoint: VMServiceEndpoint?
    @State private var manual = false
    @State private var checking = false
    @State private var connecting = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    private var selected: RunningApplicationCandidate? { candidates.first { $0.processID == selectedPID } }
    private var existing: ApplicationTarget? { selected.flatMap { model.connectedApplication(for: $0) } }
    private var filtered: [RunningApplicationCandidate] {
        candidates.filter { search.isEmpty || $0.application.name.localizedCaseInsensitiveContains(search) || String($0.processID).contains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("连接正在运行的 App").font(.title2)
                    Text("选择要监听的应用，无需选择源码目录。") .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.help("刷新运行中的应用").disabled(connecting)
            }
            TextField("搜索应用名称或 PID", text: $search).textFieldStyle(.roundedBorder).accessibilityLabel("搜索运行中的 App")
            List(selection: $selectedPID) {
                ForEach(filtered) { candidate in
                    HStack(spacing: 9) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.application.bundlePath)).resizable().frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.application.name).font(.system(size: 12, weight: .semibold))
                            Text("\(candidate.flutterDetected ? "Flutter" : "未识别类型") · PID \(candidate.processID)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.connectedApplication(for: candidate) != nil { Text("已连接").font(.caption).foregroundStyle(.secondary) }
                        else if candidate.processID == selectedPID {
                            if checking { ProgressView().controlSize(.mini) }
                            else { Text(endpoint != nil ? "发现调试服务" : "需要连接地址").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, 3).tag(Optional(candidate.processID))
                }
            }.frame(height: 220).disabled(connecting)
            if candidates.isEmpty { Text("没有找到正在运行的应用。先启动 Flutter Debug / Profile App，再刷新。").font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("手动填写连接地址", isExpanded: $manual) {
                VStack(alignment: .leading, spacing: 5) {
                    TextField("粘贴完整的 DevTools 或 VM Service 链接", text: $address)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("DevTools 或 VM Service 地址")
                    Text("自动发现受调试配置影响；可从 IDE 的运行控制台复制。Release 包通常无法连接。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 6)
            }.disabled(connecting)
            if let message { Text(message).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled) }
            Text("从连接时开始缓存日志和网络请求；断开连接不会退出 App。") .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                if connecting { ProgressView().controlSize(.small); Text("正在连接…").font(.caption) }
                Spacer()
                Button("取消") { operation?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "连接" : "查看") { connect() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(connecting || selected == nil || (existing == nil && endpoint == nil && VMServiceEndpoint(address) == nil))
            }
        }.padding(20).frame(width: 540)
            .task { refresh() }
            .onChange(of: selectedPID) { _, _ in detect() }
            .onChange(of: search) { _, _ in
                if !filtered.contains(where: { $0.processID == selectedPID }) { selectedPID = nil }
            }
            .onDisappear { operation?.cancel() }
    }
    private func refresh() {
        operation?.cancel(); candidates = ApplicationDiscovery.running()
        message = preferredApplication.flatMap { preferred in
            candidates.contains(where: { preferred.matches($0.application) }) ? nil : "“\(preferred.name)”当前未运行。启动后刷新，或选择其他 App。"
        }
        if !candidates.contains(where: { $0.processID == selectedPID }) {
            selectedPID = candidates.first { candidate in preferredApplication.map { $0.matches(candidate.application) } == true }?.processID
        }
        else { detect() }
    }
    private func detect() {
        operation?.cancel(); endpoint = nil; message = nil; address = ""; manual = false
        guard let candidate = selected else { checking = false; return }
        guard existing == nil else { checking = false; return }
        checking = true
        let known = model.knownApplicationEndpoints
        operation = Task {
            let ports = await ApplicationDiscovery.listeningPorts(processID: candidate.processID)
            guard !Task.isCancelled else { return }
            do {
                let result = try await ApplicationServiceProbe().discover(processID: candidate.processID, flutterDetected: candidate.flutterDetected, known: known, ports: ports)
                guard !Task.isCancelled, selectedPID == candidate.processID else { return }
                guard ApplicationDiscovery.isCurrent(candidate) else { checking = false; message = "所选 App 已退出，请刷新列表。"; return }
                endpoint = result; manual = result == nil; checking = false
            } catch {
                guard !Task.isCancelled else { return }; checking = false; manual = true
            }
        }
    }
    private func connect() {
        guard let candidate = selected else { return }
        if let existing { model.selectApplication(existing); dismiss(); return }
        guard let endpoint = address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? endpoint : VMServiceEndpoint(address) else {
            message = "请粘贴完整的本机调试链接。"; return
        }
        operation?.cancel(); checking = false; connecting = true; message = nil
        let entered = address
        operation = Task {
            do {
                try await model.connectApplication(candidate, endpoint: endpoint, enteredAddress: entered)
                operation = nil; dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                connecting = false; message = error.localizedDescription
            }
        }
    }
}
