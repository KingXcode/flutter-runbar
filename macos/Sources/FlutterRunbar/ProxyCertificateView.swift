import SwiftUI
import AppKit
import Security
import SecurityInterface
import RunbarCore

@MainActor
final class ProxyCertificateModel: ObservableObject {
    @Published private(set) var status = ProxyCertificateStatus.missing
    @Published private(set) var working = false
    @Published private(set) var checking = false
    @Published private(set) var error: String?
    private var directory: URL?
    private var readTask: Task<Void, Never>?
    private var readID = UUID()
    var certificateURL: URL? { directory?.appendingPathComponent("mitmproxy-ca-cert.cer") }
    var title: String {
        if working { return "正在打开系统证书窗口…" }
        if checking { return "正在检测本机 SSL 信任…" }
        switch status.state {
        case .missing: return "尚未准备抓包证书"
        case .needsTrust: return "待授权 · 尚未检测到本机 SSL 信任"
        case .trusted: return "本机 SSL 证书已信任"
        case .unreadable: return "证书暂不可用"
        }
    }
    func configure(directory: URL) { self.directory = directory }
    func refresh() {
        guard !working, !checking, let url = certificateURL else { return }
        readTask?.cancel(); readID = UUID(); checking = true
        let id = readID
        readTask = Task { [weak self] in
            let status = await Task.detached(priority: .utility) { ProxyCertificateStatus.read(from: url) }.value
            guard let self, !Task.isCancelled, readID == id else { return }
            self.status = status; checking = false
        }
    }
    private func prepare(_ configuration: ProxyLaunchConfiguration?) async throws -> ProxyCertificate {
        guard let directory, let url = certificateURL else { throw RunbarError.message("本地证书目录不可用。") }
        return try await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: url.path) { return try ProxyCertificate.read(from: url) }
            guard let configuration else { throw RunbarError.message("内置抓包引擎不可用，请重新安装 Runbar，或检查自定义引擎。") }
            let temporary = directory.deletingLastPathComponent().appendingPathComponent("proxy-setup-\(UUID().uuidString)")
            let capture = ProxyCaptureProcess(configuration: configuration, directory: temporary, epoch: UUID())
            defer { capture.stop(); try? FileManager.default.removeItem(at: temporary) }
            _ = try capture.start()
            return try ProxyCertificate.read(from: url)
        }.value
    }
    func openTrustSettings(configuration: ProxyLaunchConfiguration?) {
        perform(configuration) { certificate in
            let trust = try await Task.detached(priority: .utility) {
                let trust = try certificate.makeSSLTrust()
                _ = SecTrustEvaluateWithError(trust, nil)
                return trust
            }.value
            NSApp.activate(ignoringOtherApps: true)
            let shared: SFCertificateTrustPanel? = SFCertificateTrustPanel.shared()
            guard let panel = shared else { throw RunbarError.message("系统证书窗口暂不可用，请使用下方的钥匙串访问入口。") }
            panel.setDefaultButtonTitle("保存信任设置")
            panel.setAlternateButtonTitle("取消")
            panel.setInformativeText("请在“信任”中将“安全套接字层 (SSL)”设为“始终信任”，保存时按 macOS 提示确认。")
            panel.certificateView()?.setDisplayTrust(true)
            panel.certificateView()?.setEditableTrust(true)
            panel.certificateView()?.setPoliciesDisclosed(true)
            panel.certificateView()?.setDisplayDetails(true)
            panel.certificateView()?.setDetailsDisclosed(false)
            // macOS owns this UI and any authentication. Never mark trusted
            // from the return code; re-read the actual system trust afterwards.
            _ = panel.runModal(for: trust, message: "允许 Runbar 解密经过代理的 HTTPS / WSS 流量？")
        }
    }
    func importInKeychain(configuration: ProxyLaunchConfiguration?) {
        perform(configuration) { [weak self] _ in
            guard let self, let url = certificateURL else { return }
            let application = try keychainApplication()
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration)
        }
    }
    func openKeychain() {
        do {
            let application = try keychainApplication()
            if !NSWorkspace.shared.open(application) { throw RunbarError.message("无法自动打开钥匙串访问，请在聚焦中搜索“钥匙串访问”。") }
        } catch { self.error = error.localizedDescription }
    }
    private func keychainApplication() throws -> URL {
        if let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") { return application }
        let fallback = URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Keychain Access.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: fallback.path) else {
            throw RunbarError.message("未找到钥匙串访问，请在聚焦中搜索“钥匙串访问”。")
        }
        return fallback
    }
    private func perform(_ configuration: ProxyLaunchConfiguration?, action: @escaping @MainActor (ProxyCertificate) async throws -> Void) {
        guard !working else { return }
        readTask?.cancel(); readID = UUID(); checking = false; working = true; error = nil
        Task {
            defer { working = false; refresh() }
            do {
                let certificate = try await prepare(configuration)
                try await action(certificate)
            }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct ProxyCertificateSetupView: View {
    @ObservedObject private var certificates: ProxyCertificateModel
    private let model: AppModel
    private let preferredEngine: String
    @Environment(\.dismiss) private var dismiss
    @State private var showingManual = false
    init(model: AppModel, preferredEngine: String? = nil) {
        self.model = model; self.preferredEngine = preferredEngine ?? UserDefaults.standard.string(forKey: "proxyMitmdumpPath") ?? ""
        certificates = model.proxyCertificates
    }
    private var configuration: ProxyLaunchConfiguration? {
        guard let engine = ProxyLaunchConfiguration.findExecutable(preferred: preferredEngine),
              let addon = Bundle.main.url(forResource: "runbar_capture", withExtension: "py", subdirectory: "ProxyCapture"),
              let directory = model.proxyCertificateDirectory else { return nil }
        return ProxyLaunchConfiguration(executable: engine, addon: addon, certificateDirectory: directory, decryptTLS: false)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HTTPS / WSS 证书授权").font(.title2)
            Text("点击下方按钮，直接打开这张抓包证书的系统信任窗口。授权完成后，Runbar 会自动重新检测。")
                .font(.callout).foregroundStyle(.secondary)
            Label(certificates.title, systemImage: certificates.status.state == .trusted ? "checkmark.seal.fill" : "lock.shield")
                .foregroundStyle(certificates.status.state == .trusted ? Color.green : Color.orange).font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                Label("未准备证书时，Runbar 会先自动生成。", systemImage: "1.circle")
                Label("在系统窗口中，把 SSL 设为“始终信任”并保存。", systemImage: "2.circle")
                Label("按系统提示确认，返回这里查看检测结果。", systemImage: "3.circle")
            }.font(.callout)
            Button {
                certificates.openTrustSettings(configuration: configuration)
            } label: {
                Label(certificates.working ? "正在准备…" : certificates.status.state == .trusted ? "查看系统信任设置…" : "打开系统信任设置…", systemImage: "arrow.up.forward.app")
            }.buttonStyle(.borderedProminent).disabled(certificates.working)
            Text("只需允许 SSL；证书信任和密码确认由 macOS 处理。检测只代表本机系统信任，自定义证书库或证书固定仍可能拒绝连接。完成后重新发起请求或重连 WebSocket。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = certificates.error ?? (certificates.status.state == .unreadable ? certificates.status.detail : nil) {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            DisclosureGroup("手动设置 / 查看证书详情", isExpanded: $showingManual) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("导入到钥匙串…") { certificates.importInKeychain(configuration: configuration) }
                        Button("打开钥匙串访问") { certificates.openKeychain() }
                    }.disabled(certificates.working)
                    Text("导入到“登录”钥匙串后，双击刚导入的证书，展开“信任”，将“安全套接字层 (SSL)”设为“始终信任”，关闭窗口并确认。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let certificate = certificates.status.certificate {
                        Text("证书：\(certificate.name)").font(.caption)
                        Text("SHA-256：\(certificate.fingerprint)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                    if let detail = certificates.status.detail {
                        Text("检测信息：\(detail)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Link("Apple 证书信任设置说明", destination: URL(string: "https://support.apple.com/zh-cn/guide/keychain-access/kyca11871/mac")!)
                        .font(.caption)
                }.padding(.top, 8)
            }.font(.caption)
            HStack {
                Button("重新检测") { certificates.refresh() }.disabled(certificates.working || certificates.checking)
                Spacer()
                Button(certificates.status.state == .trusted ? "完成" : "稍后设置") { dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(certificates.working)
            }
        }.padding(24).frame(width: 570).interactiveDismissDisabled(certificates.working)
            .task { certificates.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in certificates.refresh() }
    }
}
