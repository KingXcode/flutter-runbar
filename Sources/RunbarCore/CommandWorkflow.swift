import Foundation

public struct CommandVariable: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var defaultValue: String
    public var overrideValue: String?
    public var currentValue: String { overrideValue ?? defaultValue }

    public init(name: String = "", defaultValue: String = "", overrideValue: String? = nil) {
        self.name = name
        self.defaultValue = defaultValue
        self.overrideValue = overrideValue
    }
}

public struct CommandWorkflow: Codable, Equatable, Sendable {
    public var expandVariables: Bool
    public var variables: [CommandVariable]
    public var before: String
    public var after: String

    public init(expandVariables: Bool = true, variables: [CommandVariable] = [], before: String = "", after: String = "") {
        self.expandVariables = expandVariables
        self.variables = variables
        self.before = before
        self.after = after
    }

    public static let systemVariables = ["Date-yyyy/MM/dd HH:mm:ss", "Date-yyyyMMdd", "Timestamp",
                                         "ProjectName", "ProjectPath", "CommandName", "GitBranch", "RunID"]
    static let valueLimit = 4096
    static let variableLimit = 32
    var hasHooks: Bool { !before.isEmpty || !after.isEmpty }

    func validated(command: String) throws -> Self {
        var result = self
        result.before = before.trimmingCharacters(in: .whitespacesAndNewlines)
        result.after = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard variables.count <= Self.variableLimit else { throw RunbarError.message("每条命令最多保存 32 个变量。") }
        var names = Set<String>()
        for index in result.variables.indices {
            let name = result.variables[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil,
                  !Self.systemVariables.contains(name), !name.hasPrefix("Date-"), !name.hasPrefix("Data-") else {
                throw RunbarError.message("变量名须以字母或下划线开头，可含字母、数字、下划线和连字符，且不能与系统变量重名。")
            }
            guard names.insert(name).inserted else { throw RunbarError.message("变量名重复「\(name)」。") }
            result.variables[index].name = name
            try Self.checkValue(result.variables[index].defaultValue)
            if let value = result.variables[index].overrideValue { try Self.checkValue(value) }
        }
        for script in [result.before, result.after] {
            guard script.utf8.count <= 32_768, !script.contains("\0") else { throw RunbarError.message("每段脚本最多 32 KB，不能包含空字节。") }
        }
        if result.expandVariables {
            var compiler = WorkflowCompiler(workflow: result, namespace: "_rb_check_", systemValues: nil)
            _ = try compiler.compile(result.before, hooks: true)
            _ = try compiler.compile(command, hooks: false)
            _ = try compiler.compile(result.after, hooks: true)
        }
        return result
    }

    static func checkValue(_ value: String) throws {
        guard value.utf8.count <= valueLimit, !value.contains("\0") else {
            throw RunbarError.message("每个变量值最多 4 KB，不能包含空字节。")
        }
    }
}

/// Compile only ordinary shell arguments and standalone hook directives. Values
/// enter zsh as data in generated parameters, never as shell source fragments.
private struct WorkflowCompiler {
    let workflow: CommandWorkflow
    let namespace: String
    let systemValues: WorkflowSystemValues?
    private(set) var bindings: [(key: String, value: String)] = []
    private var systemSlots: [String: String] = [:]
    private let token = try! NSRegularExpression(pattern: #"\{\{([^{}\r\n]+)\}\}"#)
    private let directive = try! NSRegularExpression(pattern: #"^\{\{([^{}]+)\}\}[ \t]*(\+\+|--|=)(.*)$"#)

    init(workflow: CommandWorkflow, namespace: String, systemValues: WorkflowSystemValues?) {
        self.workflow = workflow
        self.namespace = namespace
        self.systemValues = systemValues
    }

    func slot(_ index: Int) -> String { "\(namespace)value_\(index)" }

    mutating func compile(_ script: String, hooks: Bool) throws -> String {
        guard workflow.expandVariables, script.contains("{{") else { return script }
        let script = script.replacingOccurrences(of: "\r\n", with: "\n")
        var result = ""
        var quote: Character?
        var lineStart = true
        var wordStart = true
        var i = script.startIndex
        while i < script.endIndex {
            let rest = script[i...]
            let c = script[i]
            let next = script.index(after: i)
            if lineStart, quote == nil {
                let end = rest.firstIndex(of: "\n") ?? script.endIndex
                let line = script[i..<end].trimmingCharacters(in: .whitespaces)
                if let replacement = try compileDirective(line) {
                    guard hooks else { throw RunbarError.message("变量赋值和增减须写在前置或后置脚本中。") }
                    result += replacement
                    i = end
                    lineStart = false
                    continue
                }
            }
            if c == "#", quote == nil, wordStart {
                let end = rest.firstIndex(of: "\n") ?? script.endIndex
                result += script[i..<end]
                i = end
                lineStart = false
                continue
            }
            if c == "\\", quote != "'", next < script.endIndex {
                let end = script.index(after: next)
                result += script[i..<end]
                i = end
                lineStart = false
                wordStart = false
                continue
            }
            if rest.hasPrefix("{{") {
                let end = rest.firstIndex(of: "\n") ?? script.endIndex
                let range = NSRange(i..<end, in: script)
                guard let match = token.firstMatch(in: script, range: range), match.range.location == range.location,
                      let whole = Range(match.range, in: script), let key = Range(match.range(at: 1), in: script) else {
                    throw RunbarError.message("占位符须写成 {{变量名}}。")
                }
                let expression = "${\(try binding(String(script[key])))}"
                if quote == "\"" { result += expression }
                else if quote == "'" { result += "'\"\(expression)\"'" }
                else { result += "\"\(expression)\"" }
                i = whole.upperBound
                lineStart = false
                wordStart = false
                continue
            }
            if quote != "'", rest.hasPrefix("${"), let end = rest.firstIndex(of: "}") {
                let name = String(script[script.index(i, offsetBy: 2)..<end])
                guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { throw unsupportedShell() }
                i = script.index(after: end)
                result += script[rest.startIndex..<i]
                lineStart = false
                wordStart = false
                continue
            }
            if quote != "'", c == "`" || rest.hasPrefix("$(") || rest.hasPrefix("$[") || rest.hasPrefix("${") {
                throw unsupportedShell()
            }
            if quote == nil, rest.hasPrefix("<<") || rest.hasPrefix("((") || rest.hasPrefix("$'") {
                throw unsupportedShell()
            }
            if c == "'" || c == "\"" {
                if quote == c { quote = nil }
                else if quote == nil { quote = c }
            }
            result.append(c)
            lineStart = c == "\n"
            wordStart = quote == nil && (c.isWhitespace || ";|&()<>".contains(c))
            i = next
        }
        guard quote == nil else { throw RunbarError.message("命令或脚本的引号没有闭合。") }
        return result
    }

    private mutating func compileDirective(_ line: String) throws -> String? {
        guard line.hasPrefix("{{"), let match = directive.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let nameRange = Range(match.range(at: 1), in: line), let opRange = Range(match.range(at: 2), in: line),
              let valueRange = Range(match.range(at: 3), in: line) else { return nil }
        let name = String(line[nameRange]).trimmingCharacters(in: .whitespaces)
        guard let index = workflow.variables.firstIndex(where: { $0.name == name }) else {
            throw RunbarError.message("只能修改已定义的自定义变量「\(name)」。")
        }
        let value = String(line[valueRange]).trimmingCharacters(in: .whitespaces)
        if line[opRange] == "=" {
            try CommandWorkflow.checkValue(value)
            var expression = ""
            var start = value.startIndex
            for tokenMatch in token.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                guard let whole = Range(tokenMatch.range, in: value), let key = Range(tokenMatch.range(at: 1), in: value) else { continue }
                expression += shellLiteral(String(value[start..<whole.lowerBound]))
                expression += "\"${\(try binding(String(value[key])))}\""
                start = whole.upperBound
            }
            expression += shellLiteral(String(value[start...]))
            return "\(slot(index))=\(expression)"
        }
        guard value.isEmpty || value.hasPrefix("#") else { throw RunbarError.message("++ 和 -- 须独占一行，可在末尾添加注释。") }
        let delta = line[opRange] == "++" ? "1" : "-1"
        return "\(namespace)step \(slot(index)) \(delta) \(shellLiteral(name))"
    }

    private mutating func binding(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespaces)
        if let index = workflow.variables.firstIndex(where: { $0.name == key }) { return slot(index) }
        if let existing = systemSlots[key] { return existing }
        let value = try WorkflowSystemValues.resolve(key, context: systemValues)
        let name = "\(namespace)system_\(bindings.count)"
        systemSlots[key] = name
        bindings.append((name, value))
        return name
    }

    private func unsupportedShell() -> RunbarError {
        .message("含占位符的脚本支持普通参数和引号。请将命令替换、算术、复杂参数展开或 here 文档移到独立脚本，再通过参数传入变量。")
    }
}

private func shellLiteral(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private struct WorkflowSystemValues {
    let project: Project
    let preset: CommandPreset
    let session: RunSession

    static func resolve(_ key: String, context: Self?) throws -> String {
        if key.hasPrefix("Date-") || key.hasPrefix("Data-") {
            let format = String(key.dropFirst(5))
            guard !format.isEmpty, format.utf8.count <= 128, !format.contains("\0") else { throw RunbarError.message("日期格式须为 1 至 128 字节。") }
            guard let context else { return "" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            return formatter.string(from: context.session.startedAt)
        }
        switch key {
        case "ProjectName": return context?.project.name ?? ""
        case "ProjectPath": return context?.project.path ?? ""
        case "CommandName": return context?.preset.name ?? ""
        case "RunID": return context?.session.id.uuidString ?? ""
        case "Timestamp": return context.map { String(Int64($0.session.startedAt.timeIntervalSince1970)) } ?? ""
        case "GitBranch":
            guard let context else { return "" }
            guard let head = ProjectGitReader.head(at: context.project.path) else { throw RunbarError.message("当前项目没有可读取的 Git HEAD。") }
            switch head {
            case .branch(let name): return name
            case .detached(let revision): return String(revision.prefix(7))
            }
        default: throw RunbarError.message("未定义变量「\(key)」，请在命令编辑器中添加。")
        }
    }
}

/// Private files carry structured results. Output is always ordinary log text.
struct CommandWorkflowExecution {
    let presetID: UUID
    let directory: URL
    let variables: [CommandVariable]
    var resultFile: URL { directory.appendingPathComponent("result") }
    var skipFile: URL { directory.appendingPathComponent("skip") }
    var command: String { "builtin source \(shellLiteral(directory.appendingPathComponent("run.zsh").path))" }

    static func prepare(project: Project, preset: CommandPreset, session: RunSession, sessionDirectory: URL) throws -> Self? {
        guard let options = preset.workflow, options.hasHooks || options.expandVariables && preset.command.contains("{{") else { return nil }
        let workflow = try options.validated(command: preset.command)
        let directory = sessionDirectory.appendingPathComponent("workflow-\(UUID().uuidString)", isDirectory: true)
        let execution = Self(presetID: preset.id, directory: directory, variables: workflow.variables)
        let namespace = "_rb_\(session.id.uuidString.replacingOccurrences(of: "-", with: ""))_"
        let systemValues = WorkflowSystemValues(project: project, preset: preset, session: session)
        var compiler = WorkflowCompiler(workflow: workflow, namespace: namespace, systemValues: systemValues)
        let before = try compiler.compile(workflow.before, hooks: true)
        let body = try compiler.compile(preset.command, hooks: false)
        let after = try compiler.compile(workflow.after, hooks: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var script = "builtin emulate -L zsh\n"
            for (index, variable) in workflow.variables.enumerated() { script += "\(compiler.slot(index))=\(shellLiteral(variable.currentValue))\n" }
            for binding in compiler.bindings { script += "\(binding.key)=\(shellLiteral(binding.value))\n" }
            if !workflow.variables.isEmpty { script += counterFunction(namespace: namespace) }
            let sections = [("before", "前置脚本", before), ("main", "主命令", body), ("after", "后置脚本", after)]
            for (name, label, source) in sections where !source.isEmpty {
                let file = directory.appendingPathComponent(name + ".zsh")
                try Data(source.utf8).write(to: file, options: .atomic)
                script += "[[ ! -e \(shellLiteral(execution.skipFile.path)) ]] || exit 0\n"
                script += "builtin printf '%s\\n' \(shellLiteral("[Runbar] \(label)"))\n"
                let sourceCommand = "builtin source \(shellLiteral(file.path))"
                script += name == "main" ? "( \(sourceCommand) )\n" : "\(sourceCommand)\n"
                script += "\(namespace)status=$?\n"
                script += "(( \(namespace)status == 0 )) || exit \"$\(namespace)status\"\n"
            }
            script += "[[ ! -e \(shellLiteral(execution.skipFile.path)) ]] || exit 0\n"
            let values = workflow.variables.indices.map { "\"${\(compiler.slot($0))}\"" }.joined(separator: " ")
            script += "( umask 077; builtin printf '%s\\000' 'Runbar1' \(values) > \(shellLiteral(execution.resultFile.path)) )\n"
            try Data(script.utf8).write(to: directory.appendingPathComponent("run.zsh"), options: .atomic)
            return execution
        } catch {
            execution.removeFiles()
            throw error
        }
    }

    func skipRemaining() throws { try Data().write(to: skipFile, options: .atomic) }
    func resumeAfterRejectedDetach() { try? FileManager.default.removeItem(at: skipFile) }
    func removeFiles() { try? FileManager.default.removeItem(at: directory) }

    func finalValues() throws -> [CommandVariable] {
        let failure = RunbarError.message("命令流程提前结束或未能保存变量，当前值保留。")
        let metadata = try? resultFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard metadata?.isRegularFile == true, metadata?.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: resultFile) else { throw failure }
        defer { try? handle.close() }
        let limit = 8 + variables.count * (CommandWorkflow.valueLimit + 1)
        guard let data = try handle.read(upToCount: limit + 1), data.count <= limit, data.last == 0 else { throw failure }
        let pieces = data.dropLast().split(separator: 0, omittingEmptySubsequences: false)
        guard pieces.count == variables.count + 1, pieces.first == Data("Runbar1".utf8) else { throw failure }
        return try zip(variables, pieces.dropFirst()).map { original, bytes in
            guard let value = String(data: bytes, encoding: .utf8) else { throw failure }
            try CommandWorkflow.checkValue(value)
            var variable = original
            if value != original.currentValue { variable.overrideValue = value == original.defaultValue ? nil : value }
            return variable
        }
    }

    private static func counterFunction(namespace: String) -> String {
        #"""
        \#(namespace)step() {
          local key=$1 delta=$2 label=$3 value digits limit number
          value=${(P)key}
          if [[ ! $value =~ '^-?[0-9]+$' ]]; then
            builtin printf '[Runbar] 跳过变量「%s」的增减（当前值不是整数）\n' "$label"
            return 0
          fi
          digits=${value#-}
          while [[ $digits == 0* && ${#digits} -gt 1 ]]; do digits=${digits#0}; done
          limit=9223372036854775807
          if [[ $value == -* ]]; then limit=9223372036854775808; fi
          if [[ ${#digits} -gt 19 || ( ${#digits} -eq 19 && $digits > $limit ) ||
                ( $delta == 1 && $value != -* && $digits == 9223372036854775807 ) ||
                ( $delta == -1 && $value == -* && $digits == 9223372036854775808 ) ]]; then
            builtin printf '[Runbar] 跳过变量「%s」的增减（超过整数范围）\n' "$label"
            return 0
          fi
          if [[ $value == -* && $digits == 9223372036854775808 ]]; then
            typeset -g "$key=-9223372036854775807"
            return
          fi
          number=$((10#${digits}))
          if [[ $value == -* ]]; then number=$((-number)); fi
          typeset -g "$key=$((number + delta))"
        }

        """#
    }
}
