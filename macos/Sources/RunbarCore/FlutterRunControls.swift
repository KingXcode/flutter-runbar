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

public enum FlutterMacOSLaunch {
    /// Only explicit macOS launches. Attach, builds, mobile targets and compound
    /// shell commands must not prompt to quit an unrelated desktop app.
    public static func isRequested(by command: String) -> Bool {
        runArguments(command).flatMap(deviceID) == "macos"
    }

    public static func canRevealBuild(for session: RunSession) -> Bool {
        guard session.attachment == nil, let arguments = runArguments(session.command) else { return false }
        let device = deviceID(arguments)
        return device == nil || device == "macos" || device == "all"
    }

    private static func runArguments(_ command: String) -> [String]? {
        guard let invocation = FlutterRunInput.invocation(command), invocation.verb == "run" else { return nil }
        let arguments = Array(invocation.arguments.prefix { $0 != "--" })
        guard !arguments.contains(where: { ["--help", "-h", "--version"].contains($0) }) else { return nil }
        return arguments
    }

    private static func deviceID(_ arguments: [String]) -> String? {
        var device: String?
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--device-id=") { device = String(argument.dropFirst("--device-id=".count)) }
            else if argument.hasPrefix("-d"), !argument.hasPrefix("--"), argument.count > 2 { device = String(argument.dropFirst(2)) }
            else if ["-d", "--device-id"].contains(argument), arguments.indices.contains(index + 1) { device = arguments[index + 1] }
        }
        return device
    }

    private static let buildLine = try! NSRegularExpression(
        pattern: #"^\s*(?:\[\s*(?:[+-]?\d+\s*ms)?\]\s*)?(?:[✓✔]\s*)?Built\s+(.+\.app)(?:\s+\([^)]*\))?\s*$"#)

    /// Resolve Flutter's build message in this run's own log. The path can
    /// point to a custom build directory or a flavored Xcode configuration.
    public static func buildProduct(for session: RunSession, log: URL) throws -> URL {
        let input = try FileHandle(forReadingFrom: log)
        defer { try? input.close() }
        var remaining = try input.seekToEnd()
        try input.seek(toOffset: 0)
        let project = URL(fileURLWithPath: session.projectPath, isDirectory: true)
        var parser = OutputParser()
        var line = "", skippedLongLine = false

        func product(in line: String) throws -> URL? {
            guard line.contains("Built "),
                  let match = buildLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let path = Range(match.range(at: 1), in: line) else { return nil }
            let app = URL(fileURLWithPath: String(line[path]), isDirectory: true, relativeTo: project).standardizedFileURL
            let components = app.pathComponents.suffix(5)
            guard components.count == 5, Array(components.prefix(3)) == ["macos", "Build", "Products"] else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else {
                throw RunbarError.message("这次运行的构建产物已不存在：\n\(app.path)")
            }
            return app
        }

        // Read a snapshot so a running app can keep appending without
        // extending the search. Match complete lines across read boundaries.
        while remaining > 0 {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: Int(min(remaining, 32_768))), !bytes.isEmpty else { break }
            remaining -= UInt64(bytes.count)
            let text = parser.consume(bytes, final: remaining == 0, detectURLs: false).text
            for scalar in text.unicodeScalars {
                if scalar == "\r" || scalar == "\n" {
                    if !skippedLongLine, let app = try product(in: line) { return app }
                    line = ""; skippedLongLine = false
                } else if !skippedLongLine {
                    line.unicodeScalars.append(scalar)
                    if line.utf8.count > 32_768 { line = ""; skippedLongLine = true }
                }
            }
        }
        if session.status != .running, !skippedLongLine, let app = try product(in: line) { return app }
        let message = session.status == .running ? "尚未记录 macOS 构建产物路径。请等构建完成后再试。"
            : "这次运行的日志中没有 macOS 构建产物路径。"
        throw RunbarError.message(message)
    }
}

/// Opt in only for direct Flutter resident commands. Other commands retain
/// /dev/null stdin. This never rewrites or executes the user's shell command.
enum FlutterRunInput {
    static func enabled(project: Project, preset: CommandPreset) -> Bool {
        guard project.kind == .flutter, preset.builtInAction == nil,
              let invocation = invocation(preset.command), ["run", "attach"].contains(invocation.verb) else { return false }
        return !invocation.arguments.contains {
            ["--machine", "--no-resident", "--resident=false", "--help", "-h"].contains($0) || $0.hasPrefix("--machine=")
        }
    }
    static func invocation(_ command: String) -> (verb: String, arguments: [String])? {
        guard let words = words(command), !words.isEmpty else { return nil }
        var index = 0
        if words[index] == "exec" { index += 1 }
        if index < words.count, URL(fileURLWithPath: words[index]).lastPathComponent == "env" { index += 1 }
        while index < words.count, words[index].range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil { index += 1 }
        guard index < words.count else { return nil }
        if URL(fileURLWithPath: words[index]).lastPathComponent == "fvm" {
            index += 1
            if index < words.count, words[index] == "exec" { index += 1 }
        }
        guard index < words.count, URL(fileURLWithPath: words[index]).lastPathComponent == "flutter" else { return nil }
        index += 1
        while index < words.count, ["-v", "--verbose", "--suppress-analytics", "--no-version-check"].contains(words[index]) { index += 1 }
        guard index < words.count else { return nil }
        return (words[index], Array(words.dropFirst(index + 1)))
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
