import Foundation
import CoreFoundation

public struct NetworkJSONCondition: Codable, Identifiable, Equatable, Sendable {
    public enum Source: String, Codable, CaseIterable, Sendable {
        case request, response
        public var title: String { self == .request ? "请求 JSON" : "响应 JSON" }
    }
    public enum Operation: String, Codable, CaseIterable, Sendable {
        case equals, notEquals, contains, notContains, exists, notExists
        public var title: String {
            switch self {
            case .equals: return "等于"; case .notEquals: return "不等于"
            case .contains: return "包含"; case .notContains: return "不包含"
            case .exists: return "存在"; case .notExists: return "不存在"
            }
        }
        public var needsValue: Bool { self != .exists && self != .notExists }
    }
    public let id: UUID
    public var isExclusion: Bool
    public var source: Source
    public var path: String
    public var operation: Operation
    public var value: String
    public init(source: Source = .response, path: String, operation: Operation = .equals, value: String = "", isExclusion: Bool = false) {
        id = UUID(); self.isExclusion = isExclusion; self.source = source; self.path = path; self.operation = operation; self.value = value
    }
    public func validate() throws { _ = try CompiledJSONCondition(self) }
}

private enum JSONPathPart { case key(String), index(Int), anyIndex }

private struct CompiledJSONCondition {
    let rule: NetworkJSONCondition
    let parts: [JSONPathPart]
    let expected: Any?
    init(_ rule: NetworkJSONCondition) throws {
        guard rule.path.unicodeScalars.count <= 1024, rule.value.unicodeScalars.count <= 1024 else {
            throw RunbarError.message("JSON 字段和值各不能超过 1024 个字符。")
        }
        self.rule = rule; parts = try Self.path(rule.path)
        if rule.operation.needsValue {
            let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw RunbarError.message("请填写比较值；空字符串请写成 \"\"。") }
            let parsed = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)
            if parsed is NSDictionary || parsed is NSArray {
                throw RunbarError.message("请选择具体的 JSON 子字段，与字符串、数字、true、false 或 null 比较。")
            }
            expected = parsed ?? value
        } else { expected = nil }
    }
    private static func path(_ value: String) throws -> [JSONPathPart] {
        let chars = Array(value.trimmingCharacters(in: .whitespacesAndNewlines))
        var index = 0, result: [JSONPathPart] = []
        func invalid() -> RunbarError { .message("字段路径格式不正确，例如 data.connectionid、items[0].id 或 items[*].id。") }
        if chars.first == "$" { index += 1; if index == chars.count { return [] }; if chars[index] == "." { index += 1 } }
        guard index < chars.count else { throw invalid() }
        while index < chars.count {
            if chars[index] == "[" {
                index += 1; let start = index
                if index < chars.count, chars[index] == "\"" {
                    index += 1; var escaped = false, ended = false
                    while index < chars.count {
                        let char = chars[index]; index += 1
                        if escaped { escaped = false }
                        else if char == "\\" { escaped = true }
                        else if char == "\"" { ended = true; break }
                    }
                    guard ended, index < chars.count, chars[index] == "]",
                          let key = try? JSONSerialization.jsonObject(with: Data(String(chars[start..<index]).utf8), options: .fragmentsAllowed) as? String else { throw invalid() }
                    result.append(.key(key))
                } else {
                    while index < chars.count, chars[index] != "]" { index += 1 }
                    guard index < chars.count else { throw invalid() }
                    let token = String(chars[start..<index])
                    if token == "*" { result.append(.anyIndex) }
                    else if !token.isEmpty, token.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(token) { result.append(.index(number)) }
                    else { throw invalid() }
                }
                index += 1
            } else {
                let start = index
                while index < chars.count, ![".", "[", "]"].contains(chars[index]) { index += 1 }
                guard index > start else { throw invalid() }
                result.append(.key(String(chars[start..<index])))
            }
            guard result.count <= 64 else { throw invalid() }
            if index < chars.count, chars[index] == "." {
                index += 1
                guard index < chars.count, chars[index] != "[", chars[index] != "." else { throw invalid() }
            } else if index < chars.count, chars[index] != "[" { throw invalid() }
        }
        return result
    }
    func matches(_ root: Any) throws -> Bool {
        let positive = try visit(root, at: 0)
        switch rule.operation {
        case .notEquals, .notContains, .notExists: return !positive
        default: return positive
        }
    }
    private func visit(_ node: Any, at index: Int) throws -> Bool {
        try Task.checkCancellation()
        if index == parts.count {
            switch rule.operation {
            case .exists, .notExists: return true
            case .equals, .notEquals: return equal(node, expected!)
            case .contains, .notContains: return try contains(node)
            }
        }
        switch parts[index] {
        case .key(let key):
            guard let dictionary = node as? NSDictionary, let child = dictionary[key] else { return false }
            return try visit(child, at: index + 1)
        case .index(let position):
            guard let array = node as? NSArray, position < array.count else { return false }
            return try visit(array[position], at: index + 1)
        case .anyIndex:
            guard let array = node as? NSArray else { return false }
            for child in array { if try visit(child, at: index + 1) { return true } }
            return false
        }
    }
    private func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        if lhs is NSNull { return rhs is NSNull }
        if let a = lhs as? NSNumber, let b = rhs as? NSNumber {
            guard (CFGetTypeID(a) == CFBooleanGetTypeID()) == (CFGetTypeID(b) == CFBooleanGetTypeID()) else { return false }
            return a.compare(b) == .orderedSame
        }
        if let a = lhs as? String, let b = rhs as? String { return a == b }
        return false
    }
    private func contains(_ node: Any) throws -> Bool {
        try Task.checkCancellation()
        let needle = scalarText(expected!)
        func hit(_ text: String) -> Bool { text.range(of: needle, options: [.caseInsensitive, .literal]) != nil }
        if let dictionary = node as? NSDictionary {
            for (key, value) in dictionary {
                if hit(String(describing: key)) { return true }
                if try contains(value) { return true }
            }
            return false
        }
        if let array = node as? NSArray {
            for value in array { if try contains(value) { return true } }
            return false
        }
        return hit(scalarText(node))
    }
    private func scalarText(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return value as? String ?? ""
    }
}

/// Parse at most one capped body at a time, on the cache reader actor. No JSON
/// graph survives a record; the temporary search index only retains matching IDs.
struct NetworkJSONMatcher {
    private let request: [CompiledJSONCondition]
    private let response: [CompiledJSONCondition]
    init(_ conditions: [NetworkJSONCondition]) throws {
        guard conditions.count <= 16 else { throw RunbarError.message("最多添加 16 条 JSON 字段条件。") }
        let compiled = try conditions.map(CompiledJSONCondition.init)
        request = compiled.filter { $0.rule.source == .request }; response = compiled.filter { $0.rule.source == .response }
    }
    func matches(_ record: NetworkRecord, directory: URL) throws -> Bool {
        for (rules, suffix) in [(request, "request"), (response, "response")] where !rules.isEmpty {
            let missingResult = !rules.contains { !$0.rule.isExclusion }
            guard record.bodyState == .saved, record.id.count == 64, record.id.allSatisfy(\.isHexDigit) else {
                if missingResult { continue }; return false
            }
            let file = directory.appendingPathComponent("bodies/\(record.id).\(suffix)")
            let matches = try autoreleasepool {
                guard let handle = try? FileHandle(forReadingFrom: file) else { return missingResult }
                defer { try? handle.close() }
                let bytes = try handle.read(upToCount: NetworkBodyFormatter.inputLimit + 1) ?? Data()
                do { try NetworkBodyFormatter.validateJSONInput(bytes) }
                catch is CancellationError { throw CancellationError() }
                catch { return missingResult }
                guard let root = try? JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed) else { return missingResult }
                for rule in rules {
                    let hit = try rule.matches(root)
                    if rule.rule.isExclusion ? hit : !hit { return false }
                }
                return true
            }
            if !matches { return false }
        }
        return true
    }
}
