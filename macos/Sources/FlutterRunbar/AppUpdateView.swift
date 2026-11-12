import AppKit
import SwiftUI
import RunbarCore

@MainActor
final class AppUpdateModel: ObservableObject {
    enum InstallationPhase: Equatable {
        case downloading(Double)
        case verifying
        case opening
    }

    @Published private(set) var checking = false
    @Published private(set) var release: AppUpdateRelease?
    @Published private(set) var message = "可手动检查 GitHub 上的最新正式版本。"
    @Published private(set) var lastChecked: Date?
    @Published private(set) var installationPhase: InstallationPhase?
    @Published private(set) var downloadedInstaller: URL?
    @Published private(set) var readyToQuit = false
    @Published var automatic = UserDefaults.standard.object(forKey: "appUpdateAutomatic") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automatic, forKey: "appUpdateAutomatic")
            if automatic { Task { await check(manual: false) } }
        }
    }
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    let build = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    private var timer: Task<Void, Never>?
    private var manualTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var downloadID: UUID?
    var installing: Bool { installationPhase != nil }
    var canCancelDownload: Bool { installing && installationPhase != .opening }
    var hasUpdate: Bool {
        guard let current = try? AppReleaseVersion(version: version, build: build) else { return false }
        return release?.isNewer(than: current) == true
    }
    var download: AppUpdateRelease.Asset? {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return release?.compatibleAsset(architecture: architecture, operatingSystem: ProcessInfo.processInfo.operatingSystemVersion)
    }
    init() {
        lastChecked = UserDefaults.standard.object(forKey: "appUpdateLastChecked") as? Date
        if let cached = UserDefaults.standard.data(forKey: "appUpdateReleaseCache") {
            release = try? AppUpdateRelease.parse(cached)
            if release != nil { message = hasUpdate ? "发现新版本，可查看更新说明并下载。" : "当前已是最新正式版本。" }
        }
    }
    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(manual: false)
                do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
            }
        }
    }
    func stop() {
        timer?.cancel(); timer = nil
        manualTask?.cancel(); manualTask = nil
        downloadTask?.cancel()
    }
    func checkManually() {
        guard !checking, !installing else { return }
        manualTask = Task { [weak self] in await self?.check(manual: true) }
    }
    private func check(manual: Bool) async {
        guard !checking, !installing else { return }
        let now = Date(), defaults = UserDefaults.standard
        if !manual {
            guard automatic, AppUpdateSchedule.shouldCheck(lastAutomaticAttempt: defaults.object(forKey: "appUpdateAutomaticAttempt") as? Date, now: now) else { return }
            // Mark before the request, including failed attempts. Restarting or
            // losing network must not cause repeated automatic checks that day.
            defaults.set(now, forKey: "appUpdateAutomaticAttempt")
        }
        checking = true; message = "正在检查 GitHub 最新正式版本…"
        defer { checking = false }
        do {
            let bytes = try await GitHubAppUpdates.latest()
            try Task.checkCancellation()
            let value = try bytes.map(AppUpdateRelease.parse)
            if release != value {
                downloadedInstaller = nil
                readyToQuit = false
            }
            release = value; lastChecked = now
            defaults.set(now, forKey: "appUpdateLastChecked")
            if let bytes { defaults.set(bytes, forKey: "appUpdateReleaseCache") }
            else { defaults.removeObject(forKey: "appUpdateReleaseCache") }
            message = value == nil ? "GitHub 上暂未发布可下载版本。" : hasUpdate ? "发现新版本，可查看完整更新说明后下载。" : "当前已是最新正式版本。"
        } catch is CancellationError {} catch {
            message = "检查更新未成功：\(error.localizedDescription) 可稍后手动重试。"
        }
    }
    func openDownload() {
        guard !checking, !installing, hasUpdate, let asset = download else { return }
        guard asset.supportsInAppDownload else {
            NSWorkspace.shared.open(asset.url)
            return
        }
        let id = UUID()
        downloadID = id
        installationPhase = .downloading(0)
        downloadedInstaller = nil
        readyToQuit = false
        message = "正在下载安装包…"
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.downloadID = nil
                self.downloadTask = nil
                self.installationPhase = nil
            }
            do {
                let file = try await GitHubAppUpdates.downloadDiskImage(asset, progress: { [weak self] bytes in
                    Task { @MainActor in
                        guard let self, self.downloadID == id,
                              case .downloading(let previous) = self.installationPhase else { return }
                        let fraction = (100 * Double(bytes) / Double(asset.bytes)).rounded(.down) / 100
                        if fraction > previous { self.installationPhase = .downloading(fraction) }
                    }
                }, verifying: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.downloadID == id, case .downloading = self.installationPhase else { return }
                        self.installationPhase = .verifying
                        self.message = "正在校验安装包…"
                    }
                })
                self.downloadedInstaller = file
                try Task.checkCancellation()
                self.installationPhase = .opening
                self.message = "正在打开安装包…"
                let volume = try await Self.mountDiskImage(file)
                try Task.checkCancellation()
                guard NSWorkspace.shared.open(volume) else {
                    throw RunbarError.message("Finder 未能打开安装盘，请从「下载」文件夹打开 DMG。")
                }
                self.readyToQuit = true
                self.message = "安装盘已打开。退出 Runbar 后，将新版拖到「应用程序」。"
                NSApp.terminate(nil)
            } catch where Task.isCancelled {
                self.message = "已取消更新。"
            } catch {
                self.message = error.localizedDescription
            }
        }
    }
    func cancelDownload() { if canCancelDownload { downloadTask?.cancel() } }
    func revealInstaller() {
        if let downloadedInstaller { NSWorkspace.shared.activateFileViewerSelecting([downloadedInstaller]) }
    }
    func quitForInstallation() { NSApp.terminate(nil) }
    func openReleasePage() { NSWorkspace.shared.open(release?.page ?? AppUpdateRelease.releasesPage) }

    private nonisolated static func mountDiskImage(_ file: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    let output = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    process.arguments = ["attach", "-readonly", "-noautoopen", "-plist", file.path]
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let failure = RunbarError.message("安装盘未能打开，请从「下载」文件夹打开 DMG。")
                    guard process.terminationStatus == 0,
                          let result = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                          let entities = result["system-entities"] as? [[String: Any]],
                          let mount = entities.compactMap({ $0["mount-point"] as? String }).first,
                          mount.hasPrefix("/") else { throw failure }
                    continuation.resume(returning: URL(fileURLWithPath: mount, isDirectory: true))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

struct AppUpdateView: View {
    @ObservedObject var updater: AppUpdateModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "arrow.down.app").font(.system(size: 28)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Runbar 软件更新").font(.title2)
                    Text("当前版本 \(updater.version)（\(updater.build)）").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .downloading(let progress) = updater.installationPhase {
                    ProgressView(value: progress) {
                        Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption)
                    }.frame(width: 100).accessibilityLabel("下载进度")
                } else if updater.checking || updater.installing {
                    ProgressView().controlSize(.small)
                }
            }
            Text(updater.message).font(.callout).textSelection(.enabled)
            if let date = updater.lastChecked { Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            Toggle("每天自动检查一次", isOn: $updater.automatic)
            if let release = updater.release {
                Divider()
                Text("\(updater.hasUpdate ? "新版本" : "最新发布") \(release.version)（\(release.build)）").font(.headline)
                ScrollView {
                    Text(release.notes).font(.system(size: 12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.frame(minHeight: 230).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                if updater.hasUpdate, updater.download == nil {
                    Text("此版本尚未提供适用于本机系统或架构的安装包，可在发布页查看要求。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else { Spacer(minLength: 20) }
            Text(updater.download?.supportsInAppDownload == true
                 ? "Runbar 会下载并打开 DMG，再请求退出。打开安装盘后，将新版拖到「应用程序」。"
                 : "也可从 GitHub 发布页获取安装包，退出 Runbar 后手动替换。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("GitHub 发布页", action: updater.openReleasePage)
                if updater.downloadedInstaller != nil {
                    Button("在 Finder 中显示", action: updater.revealInstaller)
                }
                Spacer()
                Button("检查更新", action: updater.checkManually).disabled(updater.checking || updater.installing)
                if updater.canCancelDownload {
                    Button("取消更新", action: updater.cancelDownload)
                } else if updater.readyToQuit {
                    Button("退出 Runbar", action: updater.quitForInstallation).buttonStyle(.borderedProminent)
                } else if updater.hasUpdate, let asset = updater.download {
                    let title = asset.supportsInAppDownload ? "下载更新" : "浏览器下载"
                    Button("\(title)（\(ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file))）", action: updater.openDownload)
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.checking || updater.installing)
                }
            }
        }.padding(20).frame(width: 560, height: 550)
    }
}

struct UpdateSettingsSection: View {
    @ObservedObject var updater: AppUpdateModel
    let onOpen: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("软件更新").font(.headline)
                Spacer()
                Text("\(updater.version)（\(updater.build)）").font(.caption).foregroundStyle(.secondary)
                Button("检查更新…", action: onOpen).disabled(updater.checking)
            }
            Toggle("每天自动检查一次", isOn: $updater.automatic)
            if updater.hasUpdate { Label("发现新版本 \(updater.release?.version ?? "")，点击检查更新查看说明和下载。", systemImage: "arrow.down.circle.fill").font(.caption).foregroundStyle(.tint) }
        }
    }
}

struct UpdateMenuEntry: View {
    @ObservedObject var updater: AppUpdateModel
    let onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            Label(updater.hasUpdate ? "发现新版本 \(updater.release?.version ?? "")…" : "检查更新…", systemImage: updater.hasUpdate ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
        }.buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 7)
    }
}
