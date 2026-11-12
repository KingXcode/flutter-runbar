import AppKit
import Carbon
import SwiftUI
import RunbarCore
import RunbarProcess

@MainActor
final class GlobalHotKeyController {
    private var registration: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var activeID: UInt32 = 0
    private var nextID: UInt32 = 1
    private var current: GlobalShortcut?
    private var localMonitor: Any?
    private var lastInvocation: TimeInterval = 0
    var action: (() -> Void)?
    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == 0x52554E42 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKeyController>.fromOpaque(context).takeUnretainedValue()
            let identifier = id.id
            Task { @MainActor in owner.invoke(identifier) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        // Accessibility clients can deliver local key events without the
        // WindowServer's global-hotkey routing. Handle those while Runbar owns
        // focus too; recording suspends both paths and invocation is debounced.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let shortcut = self.current else { return event }
            var modifiers: GlobalShortcut.Modifiers = []
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            guard shortcut.keyCode == UInt32(event.keyCode), shortcut.modifiers == modifiers else { return event }
            self.invoke(self.activeID); return nil
        }
    }
    deinit {
        if let registration { UnregisterEventHotKey(registration) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
    private func invoke(_ identifier: UInt32) {
        guard activeID == identifier, identifier != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastInvocation > 0.2 else { return }
        lastInvocation = now; action?()
    }
    func register(_ shortcut: GlobalShortcut?) throws {
        guard current != shortcut else { return }
        guard let shortcut else {
            if let registration { UnregisterEventHotKey(registration) }
            registration = nil; current = nil; activeID = 0; return
        }
        _ = try shortcut.validated()
        guard eventHandler != nil else { throw RunbarError.message("无法安装全局快捷键处理器，请重新启动 Runbar。") }
        var modifiers: UInt32 = 0
        if shortcut.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if shortcut.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if shortcut.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        var candidate: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x52554E42, id: nextID)
        let status = RegisterEventHotKey(shortcut.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr, let candidate else {
            throw RunbarError.message("无法注册 \(shortcut.displayName)（\(status)），可能被系统或其他应用占用，请换一个快捷键。")
        }
        if let registration { UnregisterEventHotKey(registration) }
        registration = candidate; activeID = nextID; nextID &+= 1; current = shortcut
    }
}

struct GlobalShortcutRecorder: NSViewRepresentable {
    var shortcut: GlobalShortcut
    var onChange: (GlobalShortcut) -> Void
    var onRecording: (Bool) -> Void
    func makeNSView(context: Context) -> ShortcutRecordButton {
        let button = ShortcutRecordButton(); button.bezelStyle = .rounded; button.controlSize = .small
        button.setAccessibilityLabel("录制全局快捷键"); return button
    }
    func updateNSView(_ button: ShortcutRecordButton, context: Context) {
        button.shortcut = shortcut; button.changed = onChange; button.recordingChanged = onRecording
        if !button.recording { button.title = shortcut.displayName + "  · 点击修改" }
    }
    static func dismantleNSView(_ button: ShortcutRecordButton, coordinator: ()) { button.stopRecording() }
}

final class ShortcutRecordButton: NSButton {
    var shortcut = GlobalShortcut.f3
    var changed: ((GlobalShortcut) -> Void)?
    var recordingChanged: ((Bool) -> Void)?
    private(set) var recording = false
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); target = self; action = #selector(beginRecording)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func beginRecording() {
        recording = true; title = "请按快捷键…（Esc 取消）"
        recordingChanged?(true); window?.makeFirstResponder(self)
    }
    func stopRecording() {
        guard recording else { return }
        recording = false; title = shortcut.displayName + "  · 点击修改"; recordingChanged?(false)
    }
    override func resignFirstResponder() -> Bool { stopRecording(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        guard event.keyCode != 53 else { stopRecording(); return }
        var modifiers: GlobalShortcut.Modifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        let code = UInt32(event.keyCode)
        let names: [UInt32: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let name = GlobalShortcut.functionKeys[code] ?? names[code] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(code)"
        stopRecording()
        changed?(GlobalShortcut(keyCode: code, modifiers: modifiers, keyName: name))
    }
}

@MainActor
enum ManagedApplicationActivator {
    static func raise(_ processes: [ActiveProjectProcess]) async {
        guard !processes.isEmpty else { return }
        let applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.processIdentifier != getpid() && $0.activationPolicy == .regular
        }
        let candidates = applications.map { ($0.processIdentifier, $0.bundleURL, $0.launchDate) }
        let owned = await Task.detached(priority: .userInitiated) {
            let roots = Set(processes.map(\.processID))
            return Set(candidates.compactMap { pid, bundle, date -> Int32? in
                if ProcessOwnership.belongsToRun(pid, roots: roots, parent: { rb_parent_process($0) }, group: { getpgid($0) }) { return pid }
                return processes.contains { ProcessOwnership.isNewProjectApplication(bundle, launchedAt: date, projectPath: $0.projectPath, startedAt: $0.startedAt) } ? pid : nil
            })
        }.value
        for application in applications where owned.contains(application.processIdentifier) && !application.isTerminated {
            _ = application.activate(options: [.activateAllWindows])
            // Activation is asynchronous. Let the child order its windows
            // before Runbar takes focus again; don't block the main queue.
            for _ in 0..<8 {
                if application.isActive || application.isTerminated { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }
}
