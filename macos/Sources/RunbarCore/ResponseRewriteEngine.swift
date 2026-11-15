import Foundation

/// JSON is tokenized without converting numbers to Double. The same token
/// ranges drive replacement and highlighting; unrelated bytes stay untouched.
struct RewriteJSONDocument {
    final class Node {
        enum Kind { case object, array, string, number, boolean, null }
        let kind: Kind
        let range: Range<Int>
        var keyRange: Range<Int>?
        let path: String
        var members: [String: Node]
        var elements: [Node]
        let scalar: String
        init(kind: Kind, range: Range<Int>, path: String, scalar: String = "", members: [String: Node] = [:], elements: [Node] = []) {
            self.kind = kind; self.range = range; self.path = path; self.scalar = scalar
            self.members = members; self.elements = elements
        }
    }
    enum PathPart: Equatable { case key(String), index(Int), every }
    let data: Data
    let root: Node
    init(_ data: Data, limit: Int = 1024 * 1024) throws {
        guard data.count <= limit else { throw RunbarError.message("JSON 正文超过 1 MB 改写上限。") }
        guard String(data: data, encoding: .utf8) != nil else { throw RunbarError.message("JSON 正文必须是 UTF-8。") }
        var parser = Parser(bytes: Array(data))
        root = try parser.value(path: "$", depth: 0); parser.space()
        guard parser.offset == data.count else { throw RunbarError.message("JSON 正文末尾有多余内容。") }
        self.data = data
    }
    func raw(_ node: Node) -> String { String(decoding: data[node.range], as: UTF8.self) }
    static func quoted(_ value: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8), as: UTF8.self)
    }
    static func path(_ source: String) throws -> [PathPart] {
        let chars = Array(source.trimmingCharacters(in: .whitespacesAndNewlines)); var i = 0, parts: [PathPart] = []
        func invalid() -> RunbarError { .message("字段路径无效，请使用 $.body.value、items[0].value 或 items[*].value。") }
        guard !chars.isEmpty, chars.count <= 1024 else { throw invalid() }
        if chars.first == "$" { i = 1; if i == chars.count { return [] }; if chars[i] == "." { i += 1 } }
        guard i < chars.count else { throw invalid() }
        while i < chars.count {
            if chars[i] == "[" {
                i += 1; let start = i
                guard i < chars.count else { throw invalid() }
                if chars[i] == "\"" {
                    i += 1; var escaped = false, ended = false
                    while i < chars.count {
                        let char = chars[i]; i += 1
                        if escaped { escaped = false }
                        else if char == "\\" { escaped = true }
                        else if char == "\"" { ended = true; break }
                    }
                    guard ended, i < chars.count, chars[i] == "]",
                          let key = try? JSONSerialization.jsonObject(with: Data(String(chars[start..<i]).utf8), options: .fragmentsAllowed) as? String else { throw invalid() }
                    parts.append(.key(key))
                } else {
                    while i < chars.count && chars[i] != "]" { i += 1 }
                    guard i < chars.count else { throw invalid() }
                    let token = String(chars[start..<i])
                    if token == "*" { parts.append(.every) }
                    else if !token.isEmpty, token.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(token) { parts.append(.index(number)) }
                    else { throw invalid() }
                }
                i += 1
            } else {
                let start = i
                while i < chars.count && ![".", "[", "]"].contains(chars[i]) { i += 1 }
                guard i > start else { throw invalid() }
                parts.append(.key(String(chars[start..<i])))
            }
            guard parts.count <= 64 else { throw invalid() }
            if i < chars.count && chars[i] == "." { i += 1; guard i < chars.count, chars[i] != "[", chars[i] != "." else { throw invalid() } }
            else if i < chars.count && chars[i] != "[" { throw invalid() }
        }
        return parts
    }
    func nodes(at source: String, strict: Bool = true) throws -> [Node] {
        var current = [root]
        for part in try Self.path(source) {
            var next: [Node] = []
            for node in current {
                switch part {
                case .key(let key):
                    if let child = node.members[key], node.kind == .object { next.append(child) }
                    else if strict { throw RunbarError.message("路径不存在：\(source)") }
                case .index(let index):
                    if node.kind == .array && node.elements.indices.contains(index) { next.append(node.elements[index]) }
                    else if strict { throw RunbarError.message("数组位置不存在：\(source)") }
                case .every:
                    if node.kind == .array { next.append(contentsOf: node.elements) }
                    else if strict { throw RunbarError.message("通配符所在位置不是数组：\(source)") }
                }
            }
            current = next
        }
        return current
    }
    static func equal(_ a: Node, _ b: Node) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .object: return a.members.count == b.members.count && a.members.allSatisfy { key, value in b.members[key].map { equal(value, $0) } ?? false }
        case .array: return a.elements.count == b.elements.count && zip(a.elements, b.elements).allSatisfy(equal)
        case .number: return numberKey(a.scalar) == numberKey(b.scalar)
        default: return a.scalar == b.scalar
        }
    }
    static func subset(_ expected: Node, _ value: Node) -> Bool {
        if expected.kind == .object {
            return value.kind == .object && expected.members.allSatisfy { key, child in value.members[key].map { subset(child, $0) } ?? false }
        }
        return equal(expected, value)
    }
    private static func numberKey(_ text: String) -> String {
        var value = text.lowercased(), sign = ""
        if value.first == "-" { sign = "-"; value.removeFirst() }
        let parts = value.split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count <= 2, let exponent = parts.count == 2 ? Int(parts[1]) : 0 else { return text }
        let decimal = String(parts[0]); let fraction = decimal.split(separator: ".", omittingEmptySubsequences: false)
        let bytes = Array(decimal.utf8.filter { $0 != 46 })
        guard let first = bytes.firstIndex(where: { $0 != 48 }) else { return "0" }
        var end = bytes.count
        let subtract = fraction.count > 1 ? fraction[1].count : 0
        let (adjusted, overflow) = exponent.subtractingReportingOverflow(subtract)
        guard !overflow else { return text }
        var scale = adjusted
        while end > first && bytes[end - 1] == 48 { end -= 1; let (next, overflow) = scale.addingReportingOverflow(1); if overflow { return text }; scale = next }
        return sign + String(decoding: bytes[first..<end], as: UTF8.self) + "e" + String(scale)
    }
    private struct Parser {
        let bytes: [UInt8]
        var offset = 0
        var count = 0
        mutating func space() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
        func invalid() -> RunbarError { .message("JSON 格式错误（字节 \(offset)）。") }
        mutating func value(path: String, depth: Int) throws -> Node {
            count += 1
            guard count <= 200_000, depth <= 128 else { throw RunbarError.message("JSON 结构超过处理上限。") }
            if count % 256 == 0 { try Task.checkCancellation() }
            space(); let start = offset
            guard offset < bytes.count else { throw invalid() }
            let byte = bytes[offset]
            if byte == 123 {
                offset += 1; space(); var members: [String: Node] = [:]
                if offset < bytes.count && bytes[offset] == 125 { offset += 1; return Node(kind: .object, range: start..<offset, path: path) }
                while true {
                    space(); guard offset < bytes.count, bytes[offset] == 34 else { throw invalid() }
                    let keyStart = offset, key = try string(), keyEnd = offset
                    space(); guard offset < bytes.count, bytes[offset] == 58 else { throw invalid() }; offset += 1
                    guard members[key] == nil else { throw RunbarError.message("JSON 存在重名字段：\(key)") }
                    let child = try value(path: path + "[" + RewriteJSONDocument.quoted(key) + "]", depth: depth + 1)
                    child.keyRange = keyStart..<keyEnd; members[key] = child
                    space(); guard offset < bytes.count else { throw invalid() }
                    if bytes[offset] == 125 { offset += 1; break }
                    guard bytes[offset] == 44 else { throw invalid() }; offset += 1
                }
                return Node(kind: .object, range: start..<offset, path: path, members: members)
            }
            if byte == 91 {
                offset += 1; space(); var elements: [Node] = []
                if offset < bytes.count && bytes[offset] == 93 { offset += 1; return Node(kind: .array, range: start..<offset, path: path) }
                while true {
                    elements.append(try value(path: path + "[\(elements.count)]", depth: depth + 1)); space()
                    guard offset < bytes.count else { throw invalid() }
                    if bytes[offset] == 93 { offset += 1; break }
                    guard bytes[offset] == 44 else { throw invalid() }; offset += 1
                }
                return Node(kind: .array, range: start..<offset, path: path, elements: elements)
            }
            if byte == 34 { let scalar = try string(); return Node(kind: .string, range: start..<offset, path: path, scalar: scalar) }
            for (literal, kind) in [("true", Node.Kind.boolean), ("false", .boolean), ("null", .null)] {
                let token = Array(literal.utf8)
                if bytes[offset...].starts(with: token) { offset += token.count; return Node(kind: kind, range: start..<offset, path: path, scalar: literal) }
            }
            if byte == 45 { offset += 1 }
            guard offset < bytes.count else { throw invalid() }
            if bytes[offset] == 48 { offset += 1 }
            else {
                guard (49...57).contains(bytes[offset]) else { throw invalid() }
                while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }
            }
            if offset < bytes.count && bytes[offset] == 46 {
                offset += 1; let mark = offset
                while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }
                guard offset > mark else { throw invalid() }
            }
            if offset < bytes.count && [69, 101].contains(bytes[offset]) {
                offset += 1
                if offset < bytes.count && [43, 45].contains(bytes[offset]) { offset += 1 }
                let mark = offset
                while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }
                guard offset > mark else { throw invalid() }
            }
            return Node(kind: .number, range: start..<offset, path: path, scalar: String(decoding: bytes[start..<offset], as: UTF8.self))
        }
        mutating func string() throws -> String {
            let start = offset; offset += 1; var escaped = false
            while offset < bytes.count {
                let byte = bytes[offset]; offset += 1
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 {
                    guard let value = try? JSONSerialization.jsonObject(with: Data(bytes[start..<offset]), options: .fragmentsAllowed) as? String else { throw invalid() }
                    return value
                }
                else if byte < 32 { throw invalid() }
            }
            throw invalid()
        }
    }
}

public enum ResponseRewriteEngine {
    public static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = try? RewriteJSONDocument.path(lhs), let right = try? RewriteJSONDocument.path(rhs) else { return false }
        return left == right
    }
    public static func pathsMatch(_ pattern: String, _ concrete: String) -> Bool {
        guard let left = try? RewriteJSONDocument.path(pattern), let right = try? RewriteJSONDocument.path(concrete),
              left.count == right.count else { return false }
        return zip(left, right).allSatisfy { pattern, concrete in
            switch (pattern, concrete) {
            case (.every, .index): return true
            case (_, .every): return false
            default: return pattern == concrete
            }
        }
    }
    public static let bodyLimit = 1024 * 1024
    public static let maximumChanges = 8192

    public static func validate(settings: ResponseRewriteSettings) throws {
        guard settings.schemaVersion == 1, settings.revision >= 0, settings.rules.count <= 100,
              Set(settings.rules.map(\.id)).count == settings.rules.count else {
            throw RunbarError.message("改写规则版本、数量或标识无效（最多 100 条）。")
        }
        guard try JSONEncoder().encode(settings).count <= bodyLimit else { throw RunbarError.message("改写规则文件超过 1 MB。") }
        for rule in settings.rules { try validate(rule: rule) }
    }
    public static func validate(rule: ResponseRewriteRule) throws {
        guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rule.name.unicodeScalars.count <= 80,
              rule.notes.unicodeScalars.count <= 500 else { throw RunbarError.message("规则名称须为 1–80 字，备注最多 500 字。") }
        guard !rule.urlPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rule.urlPattern.utf8.count <= 16_384,
              rule.method.utf8.count <= 64, !rule.method.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !rule.actions.isEmpty, rule.actions.count <= 32, rule.requestConditions.count <= 32,
              Set(rule.actions.map(\.id)).count == rule.actions.count,
              Set(rule.requestConditions.map(\.id)).count == rule.requestConditions.count else {
            throw RunbarError.message("请填写 URL，且每条规则最多 32 个替换项和请求条件。")
        }
        let pattern = rule.urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.urlMode == .path && !pattern.hasPrefix("/") { throw RunbarError.message("匹配路径必须以 / 开头。") }
        if rule.urlMode == .full {
            guard let scheme = URLComponents(string: pattern)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                throw RunbarError.message("完整 URL 必须以 http:// 或 https:// 开头。")
            }
        }
        _ = try objectCondition(rule.requestJSON)
        let query = try objectCondition(rule.queryJSON)
        if let query {
            guard query.root.members.values.allSatisfy({ $0.kind == .string || ($0.kind == .array && $0.elements.allSatisfy { $0.kind == .string }) }) else {
                throw RunbarError.message("URL 查询参数请填写字符串，重复参数使用字符串数组。")
            }
        }
        for condition in rule.requestConditions {
            _ = try RewriteJSONDocument.path(condition.path)
            _ = try RewriteJSONDocument(Data(condition.valueJSON.utf8))
        }
        for action in rule.actions {
            _ = try RewriteJSONDocument.path(action.path)
            _ = try RewriteJSONDocument(Data(action.valueJSON.utf8))
            if action.kind == .table {
                guard action.headerRow >= 0, action.headerRow <= 100_000, !action.column.isEmpty else { throw RunbarError.message("请填写表头列名和有效的表头行。") }
                _ = try objectCondition(action.rowConditionsJSON)
            }
        }
    }
    private static func objectCondition(_ text: String) throws -> RewriteJSONDocument? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let doc = try RewriteJSONDocument(Data(text.utf8))
        guard doc.root.kind == .object else { throw RunbarError.message("参数和行筛选条件必须是 JSON 对象，或留空。") }
        return doc
    }
    public static func preview(rule: ResponseRewriteRule, method: String, url: String, requestBody: Data?, responseBody: Data) throws -> ResponseRewritePreview {
        var settings = ResponseRewriteSettings(); settings.enabled = true; settings.rules = [rule]
        return try preview(settings: settings, method: method, url: url, requestBody: requestBody, responseBody: responseBody)
    }
    public static func preview(settings: ResponseRewriteSettings, method: String, url: String,
                               requestBody: Data?, responseBody: Data) throws -> ResponseRewritePreview {
        try validate(settings: settings)
        guard settings.enabled else { return ResponseRewritePreview(body: responseBody) }
        for rule in settings.rules where rule.enabled {
            try Task.checkCancellation()
            guard rule.method.isEmpty || rule.method.uppercased() == method.uppercased() else { continue }
            let pattern = rule.urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            let urlMatches: Bool
            switch rule.urlMode {
            case .full: urlMatches = url == pattern
            case .contains: urlMatches = url.contains(pattern)
            case .path: let path = URLComponents(string: url)?.percentEncodedPath ?? ""; urlMatches = (path.isEmpty ? "/" : path) == pattern
            }
            guard urlMatches else { continue }
            do {
                if let expected = try objectCondition(rule.queryJSON) {
                    var parameters: [String: [String]] = [:]
                    let items = URLComponents(string: url.replacingOccurrences(of: "+", with: "%20"))?.queryItems ?? []
                    for item in items { parameters[item.name, default: []].append(item.value ?? "") }
                    let values: [String: Any] = parameters.mapValues { $0.count == 1 ? $0[0] as Any : $0 as Any }
                    let query = try RewriteJSONDocument(JSONSerialization.data(withJSONObject: values))
                    if !RewriteJSONDocument.subset(expected.root, query.root) { continue }
                }
                if !rule.requestJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !rule.requestConditions.isEmpty {
                    guard let requestBody else { throw RunbarError.message("请求正文未完整缓存，不能判断请求条件。") }
                    let request = try RewriteJSONDocument(requestBody)
                    if let expected = try objectCondition(rule.requestJSON), !RewriteJSONDocument.subset(expected.root, request.root) { continue }
                    var allMatch = true
                    for condition in rule.requestConditions {
                        let expected = try RewriteJSONDocument(Data(condition.valueJSON.utf8))
                        let values = try request.nodes(at: condition.path, strict: false)
                        let matches = values.contains { value in
                            if condition.operation == .equals { return RewriteJSONDocument.equal(value, expected.root) }
                            if value.kind == .array { return value.elements.contains { RewriteJSONDocument.equal($0, expected.root) } }
                            return value.kind == .string && expected.root.kind == .string && value.scalar.contains(expected.root.scalar)
                        }
                        if !matches { allMatch = false; break }
                    }
                    if !allMatch { continue }
                }
                let document = try RewriteJSONDocument(responseBody)
                var replacements: [(RewriteJSONDocument.Node, String)] = []
                for action in rule.actions {
                    let replacementDocument = try RewriteJSONDocument(Data(action.valueJSON.utf8))
                    let replacement = replacementDocument.raw(replacementDocument.root)
                    var targets: [RewriteJSONDocument.Node] = []
                    if action.kind == .json { targets = try document.nodes(at: action.path) }
                    else {
                        let tables = try document.nodes(at: action.path)
                        guard tables.count == 1, let table = tables.first, table.kind == .array, table.elements.indices.contains(action.headerRow),
                              table.elements[action.headerRow].kind == .array else { throw RunbarError.message("表格路径未定位到一个带表头的二维数组。") }
                        let header = table.elements[action.headerRow].elements
                        guard header.allSatisfy({ $0.kind == .string }), Set(header.map(\.scalar)).count == header.count else { throw RunbarError.message("表头包含非字符串或重名字段。") }
                        let names = header.map(\.scalar)
                        guard let column = names.firstIndex(of: action.column) else { throw RunbarError.message("找不到表头字段“\(action.column)”。") }
                        let rowCondition = try objectCondition(action.rowConditionsJSON)
                        if let rowCondition, !Set(rowCondition.root.members.keys).isSubset(of: Set(names)) { throw RunbarError.message("行筛选条件中的字段不在表头中。") }
                        for row in table.elements.dropFirst(action.headerRow + 1) {
                            guard row.kind == .array, row.elements.count == header.count else { throw RunbarError.message("数据行长度与表头不一致。") }
                            let matches = rowCondition?.root.members.allSatisfy { key, expected in
                                guard let index = names.firstIndex(of: key) else { return false }
                                return RewriteJSONDocument.subset(expected, row.elements[index])
                            } ?? true
                            if matches { targets.append(row.elements[column]) }
                        }
                    }
                    // Keep even unchanged targets during conflict detection so
                    // a parent replacement cannot hide a conflicting child.
                    for target in targets { replacements.append((target, replacement)) }
                    guard replacements.count <= maximumChanges else { throw RunbarError.message("定位结果超过 8192 个值，未执行改写。") }
                }
                replacements.sort { $0.0.range.lowerBound < $1.0.range.lowerBound }
                for pair in zip(replacements, replacements.dropFirst()) {
                    guard pair.0.0.range.upperBound <= pair.1.0.range.lowerBound else { throw RunbarError.message("多个替换项定位到相同或重叠的字段。") }
                }
                var changes: [ResponseRewriteChange] = [], applied: [(Range<Int>, Data)] = []
                for (node, replacement) in replacements {
                    let next = try RewriteJSONDocument(Data(replacement.utf8))
                    guard !RewriteJSONDocument.equal(node, next.root) else { continue }
                    changes.append(ResponseRewriteChange(path: node.path, originalJSON: document.raw(node), replacementJSON: replacement))
                    applied.append((node.range, Data(replacement.utf8)))
                }
                guard try JSONEncoder().encode(changes).count <= bodyLimit else { throw RunbarError.message("字段修改记录超过 1 MB，未执行改写。") }
                let outputCount = responseBody.count + applied.reduce(0) { $0 + $1.1.count - $1.0.count }
                guard outputCount <= bodyLimit else { throw RunbarError.message("改写后的正文超过 1 MB。") }
                var output = Data(); output.reserveCapacity(outputCount); var cursor = 0
                for (range, bytes) in applied {
                    output.append(responseBody[cursor..<range.lowerBound]); output.append(bytes); cursor = range.upperBound
                }
                output.append(responseBody[cursor..<responseBody.count])
                let summary = ResponseRewriteSummary(state: changes.isEmpty ? .unchanged : .changed, count: changes.count,
                    ruleID: rule.id.uuidString, ruleName: rule.name, revision: settings.revision)
                let artifact = ResponseRewriteArtifact(ruleID: rule.id.uuidString, ruleName: rule.name, revision: settings.revision,
                    originalBody: responseBody, changes: changes)
                return ResponseRewritePreview(body: output, summary: summary, artifact: artifact)
            } catch is CancellationError { throw CancellationError() }
            catch {
                return ResponseRewritePreview(body: responseBody, summary: ResponseRewriteSummary(state: .skipped,
                    ruleID: rule.id.uuidString, ruleName: rule.name, revision: settings.revision, reason: error.localizedDescription))
            }
        }
        return ResponseRewritePreview(body: responseBody)
    }
}
