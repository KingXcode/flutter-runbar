import Foundation

public enum FlutterRunAction: String, CaseIterable, Sendable {
    case hotReload = "r", hotRestart = "R", detach = "d", help = "h"
    public var title: String {
        switch self {
        case .hotReload: return "热重载"
        case .hotRestart: return "热重启"
        case .detach: return "分离运行"
        case .help: return "显示运行帮助"
        }
    }
}

public struct FlutterRunControls: Equatable, Sendable {
    public var actions = Set<FlutterRunAction>()
    public var isSending = false
    public var isDetaching = false
    public var workingAction: FlutterRunAction?
    public var isReady: Bool { !actions.isEmpty }
    public init() {}
    public func canSend(_ action: FlutterRunAction) -> Bool {
        actions.contains(action) && !isSending && !isDetaching && workingAction == nil
    }
}

/// Opt in only for direct Flutter resident commands. Other commands retain
/// /dev/null stdin. This never rewrites or executes the user's shell command.
enum FlutterRunInput {
    static func enabled(project: Project, preset: CommandPreset) -> Bool {
        guard project.kind == .flutter, preset.builtInAction == nil,
              let words = words(preset.command), !words.isEmpty else { return false }
        var index = 0
        if words[index] == "exec" { index += 1 }
        if index < words.count, URL(fileURLWithPath: words[index]).lastPathComponent == "env" { index += 1 }
        while index < words.count, words[index].range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil { index += 1 }
        guard index < words.count else { return false }
        if URL(fileURLWithPath: words[index]).lastPathComponent == "fvm" {
            index += 1
            if index < words.count, words[index] == "exec" { index += 1 }
        }
        guard index < words.count, URL(fileURLWithPath: words[index]).lastPathComponent == "flutter" else { return false }
        index += 1
        while index < words.count, ["-v", "--verbose", "--suppress-analytics", "--no-version-check"].contains(words[index]) { index += 1 }
        guard index < words.count, ["run", "attach"].contains(words[index]) else { return false }
        return !words.dropFirst(index + 1).contains {
            ["--machine", "--no-resident", "--resident=false", "--help", "-h"].contains($0) || $0.hasPrefix("--machine=")
        }
    }

    // A deliberately small shell-word reader. Compound commands, redirections
    // and substitutions are excluded: their stdin may belong to another tool.
    private static func words(_ command: String) -> [String]? {
        guard command.utf8.count <= 32_768 else { return nil }
        var result: [String] = [], word = "", quote: Character?, escaped = false, started = false
        for character in command {
            if escaped { word.append(character); started = true; escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; started = true; continue }
            if let current = quote {
                if character == current { quote = nil }
                else {
                    if current == "\"", character == "`" || character == "$" { return nil }
                    word.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" { quote = character; started = true; continue }
            if "\n\r;|&<>()`$#".contains(character) { return nil }
            if character.isWhitespace {
                if started { result.append(word); word = ""; started = false }
            } else { word.append(character); started = true }
        }
        guard quote == nil, !escaped else { return nil }
        if started { result.append(word) }
        return result
    }
}

/// Capabilities come from the live Flutter CLI help, not the saved command's
/// build mode or old log files. Keep only one short partial output line.
struct FlutterRunOutput {
    private var line = ""
    private var readingHelp = false
    private var finished = false
    private var previousCR = false
    private(set) var actions = Set<FlutterRunAction>()
    mutating func consume(_ text: String) {
        guard !finished else { return }
        for character in text.unicodeScalars {
            if character == "\n", previousCR { previousCR = false; continue }
            if character == "\n" || character == "\r" {
                previousCR = character == "\r"
                inspect(line); line = ""
                if finished { return }
            } else {
                previousCR = false; line.unicodeScalars.append(character)
                if line.utf8.count > 8192 { line = ""; readingHelp = false }
            }
        }
    }
    private mutating func inspect(_ line: String) {
        let line = line.trimmingCharacters(in: .whitespaces)
        // Verbose Flutter output can prepend a timing field such as [ +12 ms].
        if line.contains("Flutter run key commands.") || line.contains("Flutter attach key commands.") {
            readingHelp = true; return
        }
        guard readingHelp else { return }
        if line.isEmpty { return }
        for (action, description) in [(FlutterRunAction.hotReload, "Hot reload."), (.hotRestart, "Hot restart."),
                                      (.detach, "Detach"), (.help, "List all available interactive commands.")] {
            let pattern = "(?:^|\\]\\s*)" + action.rawValue + "\\s+" + NSRegularExpression.escapedPattern(for: description)
            if line.range(of: pattern, options: .regularExpression) != nil { actions.insert(action) }
        }
        if line.range(of: "(?:^|\\]\\s*)q\\s+Quit", options: .regularExpression) != nil { finished = true; readingHelp = false }
    }
}
