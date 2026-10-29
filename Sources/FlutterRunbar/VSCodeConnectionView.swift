import AppKit
import SwiftUI
import RunbarCore

struct VSCodeConnectionRequest: Identifiable {
    let id = UUID()
    let projectID: UUID
    let sessionID: UUID
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
            let executable = app.appendingPathComponent("Contents/MacOS/Electron")
            let cli = app.appendingPathComponent("Contents/Resources/app/out/cli.js")
            guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.isReadableFile(atPath: cli.path) else {
                throw RunbarError.message("VS Code 安装不完整，请重新安装后重试。")
            }
            let process = Process(), pipe = Pipe()
            process.executableURL = executable; process.arguments = [cli.path] + arguments
            process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
            // A terminal launched by a sandboxed App can inherit its target's
            // temporary directory. Never pass that path to an editor CLI.
            var environment = ProcessInfo.processInfo.environment
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
                bridgeInstalled = versions[required.id].map { $0.compare(required.version, options: .numeric) != .orderedAscending } == true
            }
            dartInstalled = versions["dart-code.dart-code"].map { $0.compare("3.144.0", options: .numeric) != .orderedAscending } == true && versions["dart-code.flutter"] != nil
            phase = bridgeInstalled && dartInstalled ? .ready : .needsInstall
            message = phase == .ready ? "扩展已安装。连接后即可在 VS Code 中设置 Dart 断点。" : "需要安装 Runbar Bridge，以及官方 Dart / Flutter 扩展。Runbar 已附带 Bridge 安装包；官方扩展的安装或更新需要联网。"
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
    @Environment(\.dismiss) private var dismiss
    private var target: (() throws -> VSCodeDebugTarget)? {
        guard let request else { return nil }
        return { try model.vsCodeTarget(projectID: request.projectID, sessionID: request.sessionID) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request == nil ? "VS Code 扩展" : "连接 VS Code").font(.title2)
            if let request, let project = model.config.projects.first(where: { $0.id == request.projectID }) {
                Text(project.name).font(.headline)
                Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Label("Runbar Bridge \(connection.version)", systemImage: connection.bridgeInstalled ? "checkmark.circle.fill" : "puzzlepiece.extension")
            Label("官方 Dart / Flutter 支持", systemImage: connection.dartInstalled ? "checkmark.circle.fill" : "puzzlepiece.extension")
            HStack(alignment: .top, spacing: 10) {
                if connection.busy { ProgressView().controlSize(.small) }
                Text(connection.message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("仅连接本机 Debug 运行。不需要修改 Flutter 源码或 launch.json。打开其他项目时使用新窗口；首次使用需确认工作区信任。")
                .font(.caption).foregroundStyle(.secondary)
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
                } else if !connection.busy && (!connection.bridgeInstalled || !connection.dartInstalled) {
                    Button(request == nil ? "安装扩展" : "安装并连接") { connection.installThenConnect(target: target) }
                        .disabled(!connection.packageAvailable).buttonStyle(.borderedProminent)
                } else if let target, !connection.busy && connection.phase != .connected {
                    Button("连接") { Task { await connection.connect(target: target) } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 530)
            .task {
                await connection.prepare()
                if connection.phase == .ready, let target { await connection.connect(target: target) }
            }
            .onDisappear { connection.close() }
    }
}
