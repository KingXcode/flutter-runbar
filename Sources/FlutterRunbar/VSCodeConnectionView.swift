import AppKit
import SwiftUI
import RunbarCore

struct VSCodeConnectionRequest: Identifiable {
    enum Source { case project(UUID), application(UUID) }
    let id = UUID()
    let source: Source
    let sessionID: UUID
    init(projectID: UUID, sessionID: UUID) { source = .project(projectID); self.sessionID = sessionID }
    init(applicationID: UUID, sessionID: UUID) { source = .application(applicationID); self.sessionID = sessionID }
    var applicationID: UUID? { if case .application(let id) = source { return id }; return nil }
}

private struct VSCodeExtensionPackage: Decodable {
    let id: String
    let version: String
    var file: URL { Bundle.main.resourceURL!.appendingPathComponent("VSCodeBridge/runbar-bridge.vsix") }
    static func bundled() throws -> Self {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("VSCodeBridge/metadata.json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data),
              value.id == "kingxcode.runbar-bridge", FileManager.default.isReadableFile(atPath: value.file.path) else {
            throw RunbarError.message("当前 Runbar 缺少扩展安装包，请使用项目的标准 Xcode 工程或打包脚本重新构建。")
        }
        return value
    }
}

/// Run only VS Code's bundled CLI with structured arguments. Never execute a
/// command from logs, a workspace setting or an extension installation result.
private enum VSCodeCLI {
    static func run(app: URL, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            // VS Code's executable name can change across releases (Code /
            // Electron). The bundle declares the actual launcher; do not guess.
            guard let executable = Bundle(url: app)?.executableURL,
                  FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw RunbarError.message("无法定位 VS Code 主程序，请确认当前应用的位置后重新检测。")
            }
            let cli = app.appendingPathComponent("Contents/Resources/app/out/cli.js")
            guard FileManager.default.isReadableFile(atPath: cli.path) else {
                throw RunbarError.message("未找到 VS Code 命令行组件（out/cli.js），暂时无法自动检测扩展。")
            }
            let process = Process(), pipe = Pipe()
            process.executableURL = executable; process.arguments = [cli.path] + arguments
            process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
            // A terminal launched by a sandboxed App can inherit its target's
            // temporary directory. Never pass that path to an editor CLI.
            var environment = ProcessInfo.processInfo.environment
            // Match the official code launcher: Node options are forwarded for
            // VS Code to handle, not interpreted by its Electron CLI helper.
            for key in ["NODE_OPTIONS", "NODE_REPL_EXTERNAL_MODULE"] {
                if let value = environment.removeValue(forKey: key) { environment["VSCODE_" + key] = value }
            }
            environment["ELECTRON_RUN_AS_NODE"] = "1"
            environment["TMPDIR"] = NSTemporaryDirectory()
            process.environment = environment
            try process.run()
            let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            deadline.schedule(deadline: .now() + 90)
            deadline.setEventHandler { if process.isRunning { process.terminate() } }
            deadline.resume()
            defer { deadline.cancel() }
            var output = Data()
            while true {
                let bytes = pipe.fileHandleForReading.readData(ofLength: 4096)
                if bytes.isEmpty { break }
                guard output.count + bytes.count <= 262_144 else {
                    if process.isRunning { process.terminate() }
                    throw RunbarError.message("VS Code 返回的安装信息过多，请使用手动安装入口。")
                }
                output.append(bytes)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw RunbarError.message("VS Code 扩展操作未成功（退出码 \(process.terminationStatus)）。请检查网络、VS Code 版本，或使用下面的手动安装入口。")
            }
            return String(decoding: output, as: UTF8.self)
        }.value
    }
}

@MainActor
private final class VSCodeConnectionModel: ObservableObject {
    enum Phase: Equatable { case checking, ready, needsInstall, missingEditor, installing, waiting, connected, failed }
    @Published var phase: Phase = .checking
    @Published var message = "正在检查 VS Code 与扩展…"
    @Published var bridgeInstalled = false
    @Published var installedBridgeVersion = ""
    @Published var dartInstalled = false
    @Published var manualInstallation = false
    private var app: URL?
    private var package: VSCodeExtensionPackage?
    private var operation: Task<Void, Never>?
    private let server = VSCodeBridgeServer()
    private var closed = false
    var busy: Bool { [.checking, .installing, .waiting].contains(phase) }
    var version: String { package?.version ?? "" }
    var packageAvailable: Bool { package != nil }
    var bridgeNeedsUpdate: Bool { !installedBridgeVersion.isEmpty && !bridgeInstalled }

    func prepare() async {
        guard !closed else { return }
        phase = .checking; message = "正在检查 VS Code 与扩展…"
        do {
            package = try VSCodeExtensionPackage.bundled()
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
                phase = .missingEditor; message = "请先安装 Visual Studio Code，再回到这里重新检测。"; return
            }
            self.app = app
            let list = try await VSCodeCLI.run(app: app, arguments: ["--list-extensions", "--show-versions"])
            guard !closed, !Task.isCancelled else { return }
            var versions: [String: String] = [:]
            for row in list.split(whereSeparator: \.isNewline) {
                let parts = row.split(separator: "@", maxSplits: 1)
                if parts.count == 2 { versions[String(parts[0]).lowercased()] = String(parts[1]) }
            }
            if let required = package {
                installedBridgeVersion = versions[required.id] ?? ""
                bridgeInstalled = versions[required.id].map { $0.compare(required.version, options: .numeric) != .orderedAscending } == true
            }
            dartInstalled = versions["dart-code.dart-code"].map { $0.compare("3.144.0", options: .numeric) != .orderedAscending } == true && versions["dart-code.flutter"] != nil
            phase = bridgeInstalled && dartInstalled ? .ready : .needsInstall
            message = phase == .ready ? "扩展已安装。连接后即可在 VS Code 中设置 Dart 断点。" : "需要安装 Runbar Bridge，以及官方 Dart / Flutter 扩展。Runbar 已附带 Bridge 安装包；官方扩展的安装或更新需要联网。"
            if bridgeNeedsUpdate, let package {
                message = "已安装 Runbar Bridge \(installedBridgeVersion)，需要更新到 \(package.version) 以支持关联 App 调试。点击更新；若 VS Code 提示重新加载窗口，请完成后再连接。"
            }
        } catch {
            guard !closed else { return }
            phase = .failed; message = error.localizedDescription; manualInstallation = true
        }
    }
    func installThenConnect(target: (() throws -> VSCodeDebugTarget)?) {
        guard !busy, let app, let package else { return }
        phase = .installing; message = "正在安装扩展，请稍候…"
        operation = Task {
            do {
                _ = try await VSCodeCLI.run(app: app, arguments: ["--install-extension", package.file.path, "--force"])
                guard !closed, !Task.isCancelled else { return }
                // Update Dart-Code even if an older dependency was already present.
                if !dartInstalled {
                    _ = try await VSCodeCLI.run(app: app, arguments: ["--install-extension", "Dart-Code.flutter", "--install-extension", "Dart-Code.dart-code", "--force"])
                }
                guard !closed, !Task.isCancelled else { return }
                await prepare()
                if phase == .ready, let target { await connect(target: target) }
            } catch {
                guard !closed else { return }
                phase = .failed; message = error.localizedDescription; manualInstallation = true
            }
        }
    }
    func connect(target: @escaping () throws -> VSCodeDebugTarget) async {
        guard phase == .ready || phase == .failed, !closed else { return }
        phase = .waiting; message = "正在打开项目并附加调试。首次连接时，请在 VS Code 中允许打开链接，并确认信任项目目录。"
        do {
            _ = try target()
            let url = try await server.link(target: target) { [weak self] error in
                guard let self, !self.closed else { return }
                self.phase = error == nil ? .connected : .failed
                self.message = error ?? "已连接。现在可以在 VS Code 中设置断点；Runbar 继续负责运行、热重载与热重启。"
            }
            guard !closed, let app else { server.close(); throw CancellationError() }
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            server.close()
            guard !closed else { return }
            phase = .failed; message = error.localizedDescription; manualInstallation = true
        }
    }
    func savePackage() {
        guard let package else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "runbar-bridge-\(package.version).vsix"
        panel.title = "保存 VS Code 扩展安装包"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try Data(contentsOf: package.file).write(to: destination, options: .atomic) }
        catch { message = "保存安装包失败：\(error.localizedDescription)" }
    }
    func openEditor() {
        if let app { NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) }
        else { NSWorkspace.shared.open(URL(string: "https://code.visualstudio.com/download")!) }
    }
    func close() { closed = true; operation?.cancel(); server.close() }
}

struct VSCodeConnectionView: View {
    @ObservedObject var model: AppModel
    var request: VSCodeConnectionRequest?
    @StateObject private var connection = VSCodeConnectionModel()
    @State private var sourcePath = ""
    @State private var sourceError: String?
    @Environment(\.dismiss) private var dismiss
    private var target: (() throws -> VSCodeDebugTarget)? {
        guard let request else { return nil }
        switch request.source {
        case .project(let id): return { try model.vsCodeTarget(projectID: id, sessionID: request.sessionID) }
        case .application(let id):
            let path = sourcePath
            return { try model.vsCodeTarget(applicationID: id, sessionID: request.sessionID, sourcePath: path) }
        }
    }
    private var sourceReady: Bool { request?.applicationID == nil || !sourcePath.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request == nil ? "VS Code 扩展" : "连接 VS Code").font(.title2)
            if let request {
                switch request.source {
                case .project(let id):
                    if let project = model.config.projects.first(where: { $0.id == id }) {
                        Text(project.name).font(.headline)
                        Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                case .application(let id): applicationSource(id)
                }
            }
            Label("Runbar Bridge \(connection.version)" + (connection.bridgeNeedsUpdate ? "（当前 \(connection.installedBridgeVersion)，需更新）" : ""),
                  systemImage: connection.bridgeInstalled ? "checkmark.circle.fill" : "puzzlepiece.extension")
            Label("官方 Dart / Flutter 支持", systemImage: connection.dartInstalled ? "checkmark.circle.fill" : "puzzlepiece.extension")
            HStack(alignment: .top, spacing: 10) {
                if connection.busy { ProgressView().controlSize(.small) }
                Text(connection.message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("仅连接本机 Debug 运行。不需要修改 Flutter 源码或 launch.json。打开其他项目时使用新窗口；首次使用需确认工作区信任。")
                .font(.caption).foregroundStyle(.secondary)
            if let sourceError { Text(sourceError).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            DisclosureGroup("手动安装", isExpanded: $connection.manualInstallation) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. 保存随 Runbar 附带的 .vsix 安装包。\n2. 在 VS Code 扩展页面点击 ⋯ → 从 VSIX 安装。\n3. 确认 Runbar Bridge 与官方 Dart / Flutter 扩展已启用，再回到此处重新检测。")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("保存扩展安装包…", action: connection.savePackage).disabled(!connection.packageAvailable)
                        Button("打开 VS Code", action: connection.openEditor)
                    }
                }.padding(.top, 6)
            }
            HStack {
                if !connection.busy { Button("重新检测") { Task { await connection.prepare() } } }
                Spacer()
                Button(connection.phase == .connected ? "完成" : "关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if connection.phase == .missingEditor {
                    Button("下载 VS Code", action: connection.openEditor).buttonStyle(.borderedProminent)
                } else if connection.phase == .needsInstall {
                    Button(connection.bridgeNeedsUpdate ? (request == nil ? "更新扩展" : "更新并连接") : (request == nil ? "安装扩展" : "安装并连接")) { connect(installing: true) }
                        .disabled(!connection.packageAvailable || !sourceReady).buttonStyle(.borderedProminent)
                } else if target != nil, connection.bridgeInstalled && connection.dartInstalled,
                          !connection.busy && connection.phase != .connected {
                    Button("连接") { connect() }
                        .disabled(!sourceReady).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 530)
            .task {
                let autoConnect: Bool
                if let id = request?.applicationID {
                    sourcePath = model.suggestedApplicationSourcePath(id) ?? ""
                    autoConnect = model.applications.first(where: { $0.id == id })?.sourceProjectPath != nil
                } else { autoConnect = true }
                await connection.prepare()
                if !Task.isCancelled, connection.phase == .ready, request != nil, autoConnect { connect() }
            }
            .onDisappear { connection.close() }
    }
    private func applicationSource(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.applications.first(where: { $0.id == id })?.name ?? "关联的 Flutter App").font(.headline)
            HStack {
                Text("源码目录").font(.subheadline)
                Spacer()
                Menu(sourcePath.isEmpty ? "选择源码…" : "更换…") {
                    ForEach(model.config.projects.filter { $0.kind == .flutter }) { project in
                        Button(project.name) { sourcePath = project.path; sourceError = nil }
                    }
                    Divider()
                    Button("选择本地目录…") { chooseSourceDirectory() }
                }.fixedSize().disabled(connection.busy || connection.phase == .connected)
            }
            Text(sourcePath.isEmpty ? "选择正在运行的 App 对应的 Flutter 源码目录。" : sourcePath)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            Text("首次选择后记住此 App 的目录。源码需与运行中的版本一致；仅建立调试关联，不新增运行项目。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func chooseSourceDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.title = "选择 Flutter 源码目录"
        panel.message = "选择当前 App 对应的 Flutter 项目根目录（包含 pubspec.yaml）。"
        if !sourcePath.isEmpty { panel.directoryURL = URL(fileURLWithPath: sourcePath) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourcePath = url.standardizedFileURL.resolvingSymlinksInPath().path; sourceError = nil
    }
    private func connect(installing: Bool = false) {
        do {
            if let request, let id = request.applicationID {
                sourcePath = try model.setApplicationSourcePath(sourcePath, applicationID: id, sessionID: request.sessionID)
            }
            sourceError = nil
            if installing { connection.installThenConnect(target: target) }
            else if let target { Task { await connection.connect(target: target) } }
        } catch { sourceError = error.localizedDescription }
    }
}
