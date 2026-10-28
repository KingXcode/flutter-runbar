import AppKit

/// An explanation after a real denied container access, never a permission
/// probe or an automatic retry of the destructive action.
@MainActor
enum SandboxResetPermissionAlert {
    static func present(containerPath: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要允许 Runbar 访问 App 沙盒"
        alert.informativeText = """
            macOS 拒绝了沙盒访问，本次未清理数据。

            在“隐私与安全性 → 完全磁盘访问权限”中开启 Runbar；列表中没有时，点“+”添加下方的 App。

            授权后请退出并重新打开 Runbar，再重新执行清理。如果已授权仍失败，请检查该容器的文件权限。
            """
        let paths = NSTextField(wrappingLabelWithString: "当前 Runbar：\n\(Bundle.main.bundleURL.path)\n\n目标沙盒：\n\(containerPath)")
        paths.isSelectable = true
        paths.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        paths.preferredMaxLayoutWidth = 420
        paths.frame = NSRect(x: 0, y: 0, width: 420, height: paths.sizeThatFits(NSSize(width: 420, height: CGFloat.greatestFiniteMagnitude)).height)
        alert.accessoryView = paths
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // This URL is documented in the macOS SDK's EndpointSecurity/ESClient.h
        // for macOS 13 and later. Opening it does not grant access.
        let destination = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
        if NSWorkspace.shared.open(destination) { return }
        if let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences"),
           NSWorkspace.shared.open(settings) { return }
        let failure = NSAlert()
        failure.messageText = "无法自动打开系统设置"
        failure.informativeText = "请从苹果菜单打开“系统设置 → 隐私与安全性 → 完全磁盘访问权限”，添加并开启当前 Runbar，然后退出并重新打开 Runbar。"
        failure.addButton(withTitle: "知道了")
        failure.runModal()
    }
}
