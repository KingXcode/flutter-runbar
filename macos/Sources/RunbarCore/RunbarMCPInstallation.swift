import Foundation
import Darwin

public enum RunbarMCPAgent: String, CaseIterable, Sendable {
    case codex, claudeCode, cursor, qoderCLI, qoderCNCLI, workbuddy

    public var title: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .qoderCLI: return "Qoder CLI"
        case .qoderCNCLI: return "Qoder CN CLI"
        case .workbuddy: return "WorkBuddy"
        }
    }

    /// User-level configurations only. Project configurations are deliberately separate.
    public func configurationFile(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        switch self {
        case .codex:
            let root = environment["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } ?? home.appendingPathComponent(".codex")
            return root.appendingPathComponent("config.toml")
        case .claudeCode:
            if let value = environment["CLAUDE_CONFIG_DIR"], value.hasPrefix("/") {
                return URL(fileURLWithPath: value).appendingPathComponent(".claude.json")
            }
            return home.appendingPathComponent(".claude.json")
        case .cursor: return home.appendingPathComponent(".cursor/mcp.json")
        case .qoderCLI, .qoderCNCLI:
            let variable = self == .qoderCLI ? "QODER_CONFIG_DIR" : "QODERCN_CONFIG_DIR"
            let fallback = self == .qoderCLI ? ".qoder" : ".qoder-cn"
            let root = environment[variable].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } ?? home.appendingPathComponent(fallback)
            return root.appendingPathComponent("settings.json")
        case .workbuddy: return home.appendingPathComponent(".workbuddy/mcp.json")
        }
    }
}

public struct RunbarMCPConnection: Sendable {
    public let address: String
    public let token: String
    public init(address: String, token: String) { self.address = address; self.token = token }
}

public struct RunbarMCPInspection: Sendable {
    public enum State: String, Sendable { case missing, installed, needsUpdate, conflict, unavailable }
    public let state: State
    public let message: String
    public var canInstall: Bool { [.missing, .installed, .needsUpdate].contains(state) }
    public var canUninstall: Bool { [.installed, .needsUpdate].contains(state) }
}

public struct RunbarMCPInstallResult: Sendable {
    public let changed: Bool
    public let backup: URL?
}

/// Merges only the user-level `runbar` server. No client process or CLI is invoked.
/// Existing configurations are backed up before an atomic replacement.
public actor RunbarMCPInstaller {
    private let backupRoot: URL
    private let files = FileManager.default
    private static let maximumBytes = 4 * 1024 * 1024

    public init(backupRoot: URL) { self.backupRoot = backupRoot.standardizedFileURL }

    public func inspect(agent: RunbarMCPAgent, file: URL, connection: RunbarMCPConnection? = nil) -> RunbarMCPInspection {
        do {
            let original = try read(file)
            let document = try MCPConfigurationDocument(agent: agent, data: original)
            return document.inspection(connection: connection)
        } catch {
            return RunbarMCPInspection(state: .unavailable, message: safeMessage(error))
        }
    }

    public func install(agent: RunbarMCPAgent, file: URL, connection: RunbarMCPConnection) throws -> RunbarMCPInstallResult {
        guard Self.isRunbarAddress(connection.address), !connection.token.isEmpty,
              !connection.token.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw MCPInstallationError("Runbar 连接参数无效，请重新开启 MCP 服务。")
        }
        return try change(agent: agent, file: file, connection: connection)
    }

    public func uninstall(agent: RunbarMCPAgent, file: URL) throws -> RunbarMCPInstallResult {
        try change(agent: agent, file: file, connection: nil)
    }

    private func change(agent: RunbarMCPAgent, file: URL, connection: RunbarMCPConnection?) throws -> RunbarMCPInstallResult {
        do {
            try Task.checkCancellation()
            let original = try read(file)
            let document = try MCPConfigurationDocument(agent: agent, data: original)
            let state = document.inspection(connection: connection)
            guard state.canInstall else { throw MCPInstallationError(state.message) }
            if connection == nil && !state.canUninstall { return RunbarMCPInstallResult(changed: false, backup: nil) }
            if connection != nil && state.state == .installed { return RunbarMCPInstallResult(changed: false, backup: nil) }
            let updated = try document.replacing(connection: connection)
            guard updated != original else { return RunbarMCPInstallResult(changed: false, backup: nil) }
            let parent = file.deletingLastPathComponent().standardizedFileURL
            try checkPath(file)
            guard !backupRoot.path.hasPrefix(file.standardizedFileURL.path + "/"), backupRoot != file.standardizedFileURL else {
                throw MCPInstallationError("备份目录与 Agent 配置文件冲突。")
            }
            try checkPath(backupRoot.appendingPathComponent("probe"))
            try files.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let stage = parent.appendingPathComponent(".runbar-mcp-" + UUID().uuidString, isDirectory: true)
            try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: stage) }
            let staged = stage.appendingPathComponent("configuration")
            try secureWrite(updated, to: staged)
            var backup: URL?
            if let original {
                let folder = backupRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let saved = folder.appendingPathComponent(file.lastPathComponent)
                try secureWrite(original, to: saved)
                backup = saved
            }
            try Task.checkCancellation()
            // Read again immediately before the rename; never overwrite an edit observed
            // since inspection. External editors do not share a locking protocol with us.
            guard try read(file) == original else {
                throw MCPInstallationError("Agent 配置刚刚发生变化，未覆盖。请刷新后重试。")
            }
            guard rename(staged.path, file.path) == 0 else {
                throw MCPInstallationError("无法保存 Agent 配置，请检查目录权限。原配置未替换。")
            }
            return RunbarMCPInstallResult(changed: true, backup: backup)
        } catch is CancellationError { throw CancellationError() }
        catch { throw MCPInstallationError(safeMessage(error)) }
    }

    private func checkPath(_ file: URL) throws {
        guard file.isFileURL, file.path.hasPrefix("/"),
              file.standardizedFileURL.path == file.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw MCPInstallationError("配置路径包含符号链接；请选择实际配置文件。")
        }
        // resolvingSymlinksInPath also handles a missing leaf, but does not reveal
        // a dangling symlink. Inspect the leaf explicitly as well.
        if let attributes = try? files.attributesOfItem(atPath: file.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw MCPInstallationError("配置文件是符号链接；请选择实际配置文件。")
        }
    }

    private func read(_ file: URL) throws -> Data? {
        try checkPath(file)
        guard files.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= Self.maximumBytes else {
            throw MCPInstallationError("配置文件类型不受支持或超过 4 MiB，未修改。")
        }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw MCPInstallationError("配置文件超过 4 MiB，未修改。") }
        return data
    }

    private func secureWrite(_ data: Data, to file: URL) throws {
        guard files.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MCPInstallationError("无法写入配置或备份，请检查目录权限。")
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func safeMessage(_ error: Error) -> String {
        (error as? MCPInstallationError)?.message ?? "无法读写 Agent 配置，请检查文件格式和目录权限。"
    }

    fileprivate static func isRunbarAddress(_ text: String) -> Bool {
        guard let url = URLComponents(string: text), url.scheme == "http", url.path == "/mcp",
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return url.port.map { (1024...65535).contains($0) } ?? false
    }
}

private struct MCPInstallationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct MCPConfigurationDocument {
    let agent: RunbarMCPAgent
    let json: [String: Any]?
    let jsonSyntax: MCPStrictJSON?
    let jsonData: Data?
    let toml: MCPManagedTOML?
    let entry: [String: Any]?

    init(agent: RunbarMCPAgent, data: Data?) throws {
        self.agent = agent
        if agent == .codex {
            guard let text = String(data: data ?? Data(), encoding: .utf8) else { throw MCPInstallationError("Codex 配置必须使用 UTF-8，未修改。") }
            let document = try MCPManagedTOML(text: text)
            toml = document; json = nil; jsonSyntax = nil; jsonData = nil; entry = document.entry
        } else {
            let source = data ?? Data("{}".utf8)
            var parser = MCPStrictJSON(data: source)
            try parser.validate()
            let root: [String: Any]
            if let data {
                // Parse twice: the syntax walk rejects duplicate object keys rather
                // than allowing JSONSerialization to silently discard a value.
                guard let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] else {
                    throw MCPInstallationError("Agent 配置不是有效的 JSON 对象，未修改。请保留原文件并检查格式。")
                }
                root = dictionary
            } else { root = [:] }
            if let value = root["mcpServers"], !(value is [String: Any]) { throw MCPInstallationError("mcpServers 不是对象，未修改现有配置。") }
            if let value = (root["mcpServers"] as? [String: Any])?["runbar"], !(value is [String: Any]) {
                throw MCPInstallationError("已有同名 runbar 配置格式不兼容，未修改。")
            }
            json = root; jsonSyntax = parser; jsonData = source; toml = nil; entry = (root["mcpServers"] as? [String: Any])?["runbar"] as? [String: Any]
        }
    }

    func inspection(connection: RunbarMCPConnection?) -> RunbarMCPInspection {
        guard let entry else { return RunbarMCPInspection(state: .missing, message: "未安装") }
        guard let url = entry["url"] as? String, RunbarMCPInstaller.isRunbarAddress(url),
              entry["command"] == nil,
              entry["type"] == nil || (entry["type"] as? String) == "http" else {
            return RunbarMCPInspection(state: .conflict, message: "已有其他来源的同名 runbar 服务，请先在客户端中检查；未覆盖或卸载。")
        }
        if let connection {
            let headers = entry[agent == .codex ? "http_headers" : "headers"] as? [String: Any]
            let authorization = headers?.first { $0.key.lowercased() == "authorization" }?.value as? String
            let disabled = (entry["enabled"] as? Bool) == false || (entry["disabled"] as? Bool) == true
            let dynamicCodexAuth = agent == .codex && (entry["bearer_token_env_var"] != nil || entry["env_http_headers"] != nil)
            let wrongType = agent == .codex ? false : (agent == .cursor || agent == .workbuddy ? entry["type"] != nil : (entry["type"] as? String) != "http")
            let shortTimeout = agent == .codex ? (entry["tool_timeout_sec"] as? Int ?? 0) < 45 : ((agent == .qoderCLI || agent == .qoderCNCLI) && (entry["timeout"] as? Int ?? 0) < 45_000)
            if url != connection.address || authorization != "Bearer " + connection.token || disabled || dynamicCodexAuth || wrongType || shortTimeout {
                return RunbarMCPInspection(state: .needsUpdate, message: "已安装，连接配置需更新")
            }
        }
        return RunbarMCPInspection(state: .installed, message: "已安装")
    }

    func replacing(connection: RunbarMCPConnection?) throws -> Data {
        if let toml { return Data(try toml.replacing(connection: connection).utf8) }
        var replacement: [String: Any]?
        if let connection {
            var value = entry ?? [:]
            value["url"] = connection.address
            var headers = value["headers"] as? [String: Any] ?? [:]
            for key in headers.keys where key.lowercased() == "authorization" { headers.removeValue(forKey: key) }
            headers["Authorization"] = "Bearer " + connection.token
            value["headers"] = headers
            if agent == .cursor || agent == .workbuddy { value.removeValue(forKey: "type") } else { value["type"] = "http" }
            value.removeValue(forKey: "disabled"); value.removeValue(forKey: "enabled")
            if agent == .qoderCLI || agent == .qoderCNCLI { value["timeout"] = 45_000 }
            replacement = value
        }
        guard let syntax = jsonSyntax, let original = jsonData else { throw MCPInstallationError("无法确定 JSON 配置位置，未修改。") }
        return try syntax.replacingRunbar(in: original, value: replacement)
    }
}

/// A conservative TOML statement scanner. It never treats text inside strings,
/// arrays, inline tables, or comments as a table boundary. Unsupported definitions
/// of the managed table are refused rather than guessed at.
private struct MCPManagedTOML {
    private struct Statement { let range: Range<Int>; let text: String }
    let text: String
    let removal: [Range<Int>]
    let entry: [String: Any]?

    init(text: String) throws {
        self.text = text
        let statements = try Self.statements(Array(text.utf8))
        var section: [String] = [], owned = false, ranges: [Range<Int>] = [], entry: [String: Any]?
        var baseSeen = false, keys = Set<String>(), sections = Set<String>()
        for statement in statements {
            let cleaned = Self.withoutComment(statement.text).trimmingCharacters(in: .whitespacesAndNewlines)
            // Keep comments and whitespace even when they follow a Runbar table:
            // they may describe the next unrelated table.
            if cleaned.isEmpty { continue }
            if cleaned.hasPrefix("[") {
                let array = cleaned.hasPrefix("[[")
                let count = array ? 2 : 1
                guard cleaned.hasSuffix(array ? "]]" : "]") else { throw Self.unsupported() }
                section = try Self.keyPath(String(cleaned.dropFirst(count).dropLast(count)))
                owned = section.starts(with: ["mcp_servers", "runbar"])
                if owned {
                    guard !array else { throw Self.unsupported() }
                    let sectionKey = section.joined(separator: "\0")
                    guard sections.insert(sectionKey).inserted else { throw Self.unsupported() }
                    if section.count == 2 { guard !baseSeen else { throw Self.unsupported() }; baseSeen = true }
                    if entry == nil { entry = [:] }
                    ranges.append(statement.range)
                }
                continue
            }
            guard let equal = Self.assignmentEqual(cleaned) else { throw Self.unsupported() }
            let path = try Self.keyPath(String(cleaned[..<equal]))
            let effective = section + path
            let raw = String(cleaned[cleaned.index(after: equal)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { throw Self.unsupported() }
            if !owned {
                // A parent inline table or dotted assignment could define runbar.
                // We cannot append a second definition without changing semantics.
                if effective == ["mcp_servers"] || effective.starts(with: ["mcp_servers", "runbar"]) { throw Self.unsupported() }
                continue
            }
            ranges.append(statement.range)
            guard keys.insert(effective.joined(separator: "\0")).inserted else { throw Self.unsupported() }
            if effective.count == 3 {
                let key = effective[2]
                if key == "http_headers" { entry?[key] = Self.inlineStrings(raw) ?? [:] }
                else if let string = Self.string(raw) { entry?[key] = string }
                else if raw == "false" { entry?[key] = false }
                else if raw == "true" { entry?[key] = true }
                else if let integer = Int(raw) { entry?[key] = integer }
                else { entry?[key] = NSNull() }
            } else if effective.count == 4, effective[2] == "http_headers" {
                var headers = entry?["http_headers"] as? [String: Any] ?? [:]
                headers[effective[3]] = Self.string(raw) ?? ""
                entry?["http_headers"] = headers
            }
        }
        removal = ranges; self.entry = entry
    }

    func replacing(connection: RunbarMCPConnection?) throws -> String {
        var bytes = Array(text.utf8)
        for range in removal.reversed() { bytes.removeSubrange(range) }
        var result = String(decoding: bytes, as: UTF8.self)
        if let connection {
            if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
            if !result.isEmpty { result += "\n" }
            result += "[mcp_servers.runbar]\nurl = \(Self.quoted(connection.address))\nhttp_headers = { Authorization = \(Self.quoted("Bearer " + connection.token)) }\ntool_timeout_sec = 45\n"
        }
        return result
    }

    private static func unsupported() -> MCPInstallationError {
        MCPInstallationError("Codex TOML 格式存在歧义或使用了暂不支持的 runbar 定义，未修改。请使用独立的 [mcp_servers.runbar] 配置表。")
    }

    private static func quoted(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func string(_ value: String) -> String? {
        if value.hasPrefix("'"), value.hasSuffix("'"), !value.hasPrefix("'''"), value.count >= 2 { return String(value.dropFirst().dropLast()) }
        guard value.hasPrefix("\""), !value.hasPrefix("\"\"\"") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)) as? String
    }

    private static func inlineStrings(_ value: String) -> [String: String]? {
        guard value.hasPrefix("{"), value.hasSuffix("}") else { return nil }
        let body = String(value.dropFirst().dropLast())
        var parts: [String] = [], start = body.startIndex, quote: Character?, escaped = false
        for index in body.indices {
            let ch = body[index]
            if escaped { escaped = false; continue }
            if quote == "\"", ch == "\\" { escaped = true; continue }
            if let current = quote { if ch == current { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "," { parts.append(String(body[start..<index])); start = body.index(after: index) }
        }
        parts.append(String(body[start...]))
        var result: [String: String] = [:]
        for part in parts where !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let equal = assignmentEqual(part), let key = try? keyPath(String(part[..<equal])), key.count == 1,
                  let value = string(String(part[part.index(after: equal)...]).trimmingCharacters(in: .whitespacesAndNewlines)), result[key[0]] == nil else { return nil }
            result[key[0]] = value
        }
        return result
    }

    private static func keyPath(_ text: String) throws -> [String] {
        let bytes = Array(text.utf8)
        var i = 0, parts: [String] = []
        func space(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 }
        while i < bytes.count {
            while i < bytes.count && space(bytes[i]) { i += 1 }
            guard i < bytes.count else { throw unsupported() }
            let begin = i
            if bytes[i] == 34 || bytes[i] == 39 {
                let quote = bytes[i]; i += 1
                while i < bytes.count {
                    if bytes[i] == 92 && quote == 34 { i += 2; continue }
                    if bytes[i] == quote { break }; i += 1
                }
                guard i < bytes.count else { throw unsupported() }; i += 1
                guard let part = string(String(decoding: bytes[begin..<i], as: UTF8.self)) else { throw unsupported() }
                parts.append(part)
            } else {
                while i < bytes.count, (48...57).contains(bytes[i]) || (65...90).contains(bytes[i]) || (97...122).contains(bytes[i]) || bytes[i] == 95 || bytes[i] == 45 { i += 1 }
                guard i > begin else { throw unsupported() }
                parts.append(String(decoding: bytes[begin..<i], as: UTF8.self))
            }
            while i < bytes.count && space(bytes[i]) { i += 1 }
            if i == bytes.count { break }
            guard bytes[i] == 46 else { throw unsupported() }; i += 1
            guard i < bytes.count else { throw unsupported() }
        }
        guard !parts.isEmpty else { throw unsupported() }; return parts
    }

    private static func assignmentEqual(_ text: String) -> String.Index? {
        var quote: Character?, escaped = false
        for index in text.indices {
            let ch = text[index]
            if escaped { escaped = false; continue }
            if quote == "\"", ch == "\\" { escaped = true; continue }
            if let current = quote { if ch == current { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "=" { return index }
        }
        return nil
    }

    private static func withoutComment(_ text: String) -> String {
        var quote: Character?, escaped = false
        // Multiline values need their original contents. Only strip a trailing
        // comment on ordinary one-line statements.
        if text.contains("\"\"\"") || text.contains("'''") { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        for index in text.indices {
            let ch = text[index]
            if escaped { escaped = false; continue }
            if quote == "\"", ch == "\\" { escaped = true; continue }
            if let current = quote { if ch == current { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "#" { return String(text[..<index]) }
        }
        return text
    }

    private static func statements(_ bytes: [UInt8]) throws -> [Statement] {
        var result: [Statement] = [], start = 0, i = 0, quote: UInt8?, triple = false, brackets: [UInt8] = [], comment = false
        while i < bytes.count {
            let ch = bytes[i]
            if comment {
                if ch == 10 { comment = false; if brackets.isEmpty { result.append(Statement(range: start..<(i + 1), text: String(decoding: bytes[start...i], as: UTF8.self))); start = i + 1 } }
                i += 1; continue
            }
            if let current = quote {
                if current == 34 && ch == 92 { i += 2; continue }
                if ch == current {
                    if triple {
                        if i + 2 < bytes.count, bytes[i + 1] == current, bytes[i + 2] == current { quote = nil; triple = false; i += 3; continue }
                    } else { quote = nil }
                } else if !triple && (ch == 10 || ch == 13) { throw unsupported() }
                i += 1; continue
            }
            if ch == 34 || ch == 39 {
                quote = ch; triple = i + 2 < bytes.count && bytes[i + 1] == ch && bytes[i + 2] == ch
                i += triple ? 3 : 1; continue
            }
            if ch == 35 { comment = true }
            else if ch == 91 || ch == 123 { brackets.append(ch) }
            else if ch == 93 || ch == 125 {
                guard brackets.popLast() == (ch == 93 ? 91 : 123) else { throw unsupported() }
            }
            else if ch == 10 && brackets.isEmpty {
                result.append(Statement(range: start..<(i + 1), text: String(decoding: bytes[start...i], as: UTF8.self))); start = i + 1
            }
            i += 1
        }
        guard quote == nil, brackets.isEmpty else { throw unsupported() }
        if start < bytes.count { result.append(Statement(range: start..<bytes.count, text: String(decoding: bytes[start...], as: UTF8.self))) }
        return result
    }
}

/// JSONSerialization accepts duplicate keys. A syntax-only walk prevents silently
/// throwing away an unrelated setting during a merge. JSONC is refused explicitly.
private struct MCPStrictJSON {
    private struct Member {
        let key: String
        let start: Int
        let value: Range<Int>
        let commaBefore: Int?
        let commaAfter: Int?
    }
    private struct ObjectSpan { let close: Int; let members: [Member] }
    private enum Capture { case none, root, servers }
    let bytes: [UInt8]
    var index = 0
    private var root: ObjectSpan?
    private var servers: ObjectSpan?
    init(data: Data) { bytes = Array(data) }
    mutating func validate() throws {
        guard bytes.count <= 4 * 1024 * 1024 else { throw invalid() }
        try value(depth: 0, capture: .root); whitespace()
        guard index == bytes.count, root != nil else { throw invalid() }
    }

    func replacingRunbar(in original: Data, value: [String: Any]?) throws -> Data {
        guard let root else { throw invalid() }
        var result = Array(original)
        let encoded = try value.map { Array(try JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) }
        if let servers {
            if let member = servers.members.first(where: { $0.key == "runbar" }) {
                if let encoded { result.replaceSubrange(member.value, with: encoded) }
                else {
                    if let after = member.commaAfter { result.removeSubrange(member.start..<(after + 1)) }
                    else {
                        result.removeSubrange(member.start..<member.value.upperBound)
                        if let before = member.commaBefore { result.remove(at: before) }
                    }
                }
            } else if let encoded {
                let prefix = servers.members.isEmpty ? "" : ","
                let insertion = Array((prefix + "\n    \"runbar\": ").utf8) + encoded + Array("\n  ".utf8)
                result.insert(contentsOf: insertion, at: servers.close)
            }
        } else if let encoded {
            let prefix = root.members.isEmpty ? "" : ","
            let insertion = Array((prefix + "\n  \"mcpServers\": {\n    \"runbar\": ").utf8) + encoded + Array("\n  }\n".utf8)
            result.insert(contentsOf: insertion, at: root.close)
        }
        return Data(result)
    }
    private func invalid() -> MCPInstallationError { MCPInstallationError("Agent 配置不是有效的 JSON，或包含重复键 / 注释，未修改。请先在客户端中检查文件格式。") }
    private mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    private mutating func consume(_ byte: UInt8) -> Bool { whitespace(); if index < bytes.count && bytes[index] == byte { index += 1; return true }; return false }
    private mutating func string() throws -> String {
        whitespace(); let start = index
        guard index < bytes.count, bytes[index] == 34 else { throw invalid() }; index += 1
        while index < bytes.count {
            if bytes[index] == 92 { index += 2; continue }
            if bytes[index] == 34 {
                index += 1
                guard let result = (try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed)) as? String else { throw invalid() }
                return result
            }
            index += 1
        }
        throw invalid()
    }
    private mutating func value(depth: Int, capture: Capture = .none) throws {
        guard depth < 128 else { throw invalid() }; whitespace()
        guard index < bytes.count else { throw invalid() }
        if bytes[index] == 123 {
            index += 1; var keys = Set<String>(), members: [Member] = [], commaBefore: Int?
            func captured(_ span: ObjectSpan) {
                if capture == .root { root = span }
                else if capture == .servers { servers = span }
            }
            if consume(125) { captured(ObjectSpan(close: index - 1, members: [])); return }
            repeat {
                whitespace(); let start = index
                let key = try string(); guard keys.insert(key).inserted, consume(58) else { throw invalid() }
                whitespace(); let valueStart = index
                try value(depth: depth + 1, capture: capture == .root && key == "mcpServers" ? .servers : .none)
                let valueEnd = index
                if consume(125) {
                    members.append(Member(key: key, start: start, value: valueStart..<valueEnd, commaBefore: commaBefore, commaAfter: nil))
                    captured(ObjectSpan(close: index - 1, members: members)); return
                }
                guard consume(44) else { throw invalid() }
                members.append(Member(key: key, start: start, value: valueStart..<valueEnd, commaBefore: commaBefore, commaAfter: index - 1))
                commaBefore = index - 1
            } while true
        } else if bytes[index] == 91 {
            index += 1; if consume(93) { return }
            repeat { try value(depth: depth + 1); if consume(93) { return }; guard consume(44) else { throw invalid() } } while true
        } else if bytes[index] == 34 { _ = try string() }
        else {
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start, (try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed)) != nil else { throw invalid() }
        }
    }
}
