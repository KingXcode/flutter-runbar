import Foundation

public struct GlobalShortcut: Codable, Equatable, Sendable {
    public struct Modifiers: OptionSet, Codable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let control = Self(rawValue: 1)
        public static let option = Self(rawValue: 2)
        public static let shift = Self(rawValue: 4)
        public static let command = Self(rawValue: 8)
    }
    public var keyCode: UInt32
    public var modifiers: Modifiers
    public var keyName: String
    public static let f3 = GlobalShortcut(keyCode: 99, modifiers: [], keyName: "F3")
    public static let functionKeys: [UInt32: String] = [122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
    public init(keyCode: UInt32, modifiers: Modifiers, keyName: String) { self.keyCode = keyCode; self.modifiers = modifiers; self.keyName = keyName }
    public var displayName: String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") +
        (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + (Self.functionKeys[keyCode] ?? keyName)
    }
    public func validated() throws -> Self {
        guard keyCode < 128, keyCode != 53, !keyName.isEmpty, keyName.count <= 24, modifiers.rawValue & ~15 == 0 else {
            throw RunbarError.message("这个按键不能用作全局快捷键，请重新录制。")
        }
        guard Self.functionKeys[keyCode] != nil || !modifiers.intersection([.control, .option, .command]).isEmpty else {
            throw RunbarError.message("普通按键请搭配 ⌘、⌥ 或 ⌃，也可以直接使用 F1–F20。")
        }
        return self
    }
}

public struct GlobalShortcutPreferences: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var shortcut: GlobalShortcut
    public init(enabled: Bool = true, shortcut: GlobalShortcut = .f3) { self.enabled = enabled; self.shortcut = shortcut }
}

public struct ActiveProjectProcess: Sendable {
    public let projectID: UUID
    public let sessionID: UUID
    public let projectPath: String
    public let startedAt: Date
    public let processID: Int32
}
