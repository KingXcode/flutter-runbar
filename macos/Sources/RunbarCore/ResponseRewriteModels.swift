import Foundation

public struct ResponseRewriteSettings: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var revision = 0
    public var enabled = false
    public var rules: [ResponseRewriteRule] = []
    public init() {}
}

public enum ResponseRewriteURLMode: String, Codable, CaseIterable, Sendable {
    case full, path, contains
    public var title: String {
        switch self { case .full: return "完整 URL 等于"; case .path: return "路径等于"; case .contains: return "URL 包含" }
    }
}

public struct ResponseRewriteRequestCondition: Codable, Equatable, Identifiable, Sendable {
    public enum Operation: String, Codable, CaseIterable, Sendable {
        case equals, contains
        public var title: String { self == .equals ? "等于" : "包含元素" }
    }
    public var id = UUID()
    public var path = "$.blocks"
    public var operation = Operation.contains
    public var valueJSON = "2000"
    public init() {}
}

public struct ResponseRewriteAction: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case json, table
        public var title: String { self == .json ? "JSON 字段" : "表头 + 数据行" }
    }
    public var id = UUID()
    public var kind = Kind.json
    public var path = "$.body.isClearing"
    public var column = "清盘中"
    /// Zero-based; data rows follow the configured header row.
    public var headerRow = 0
    public var rowConditionsJSON = ""
    public var valueJSON = "true"
    public init() {}
}

public struct ResponseRewriteRule: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name = "新规则"
    public var notes = ""
    public var enabled = true
    public var method = ""
    public var urlMode = ResponseRewriteURLMode.path
    public var urlPattern = ""
    public var requestJSON = ""
    /// Query values are strings, or arrays of strings for repeated keys.
    public var queryJSON = ""
    public var requestConditions: [ResponseRewriteRequestCondition] = []
    public var actions: [ResponseRewriteAction] = [ResponseRewriteAction()]
    public init() {}
}

public struct ResponseRewriteSummary: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case changed, unchanged, skipped }
    public var state: State
    public var count: Int
    public var ruleID: String?
    public var ruleName: String?
    public var revision: Int?
    public var reason: String?
    public var artifactID: String?
    public init(state: State, count: Int = 0, ruleID: String? = nil, ruleName: String? = nil,
                revision: Int? = nil, reason: String? = nil, artifactID: String? = nil) {
        self.state = state; self.count = count; self.ruleID = ruleID; self.ruleName = ruleName
        self.revision = revision; self.reason = reason; self.artifactID = artifactID
    }
    public var title: String {
        switch state { case .changed: return "已改写 · \(count) 处"; case .unchanged: return "命中，未变化"; case .skipped: return "改写跳过" }
    }
    public var detail: String { [ruleName, reason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
}

public struct ResponseRewriteChange: Codable, Equatable, Identifiable, Sendable {
    /// Concrete, escaped JSON path; no wildcard remains in a recorded change.
    public var path: String
    public var originalJSON: String
    public var replacementJSON: String
    public var id: String { path }
    public init(path: String, originalJSON: String, replacementJSON: String) {
        self.path = path; self.originalJSON = originalJSON; self.replacementJSON = replacementJSON
    }
}

public struct ResponseRewriteArtifact: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var ruleID: String
    public var ruleName: String
    public var revision: Int
    /// Base64 in the wire JSON, decoded original UTF-8 JSON bytes in memory.
    public var originalBody: Data
    public var originalHeaders: String
    public var changes: [ResponseRewriteChange]
    public init(ruleID: String, ruleName: String, revision: Int, originalBody: Data,
                originalHeaders: String = "{}", changes: [ResponseRewriteChange]) {
        self.ruleID = ruleID; self.ruleName = ruleName; self.revision = revision
        self.originalBody = originalBody; self.originalHeaders = originalHeaders; self.changes = changes
    }
}

public enum ResponseRewriteBodyVersion: String, CaseIterable, Sendable {
    case client, original, changes
    public var title: String {
        switch self { case .client: return "发给客户端"; case .original: return "服务器原始"; case .changes: return "只看修改" }
    }
}

public struct ResponseRewriteAnnotation: Equatable, Sendable {
    public var range: NSRange
    public var path: String
    public var originalJSON: String
    public var replacementJSON: String
    public var ruleName: String
    public init(range: NSRange, path: String, originalJSON: String, replacementJSON: String, ruleName: String) {
        self.range = range; self.path = path; self.originalJSON = originalJSON
        self.replacementJSON = replacementJSON; self.ruleName = ruleName
    }
    public var tooltip: String { "原始值：\(originalJSON)\n修改后：\(replacementJSON)\n规则：\(ruleName)\n位置：\(path)" }
}

/// A complete JSON node behind a key/value visible on the current text page.
/// The range uses page-local UTF-16 offsets, as required by NSTextView.
public struct ResponseRewriteTarget: Equatable, Sendable {
    public var range: NSRange
    public var action: ResponseRewriteAction
    public var path: String
    public init(range: NSRange, action: ResponseRewriteAction, path: String) {
        self.range = range; self.action = action; self.path = path
    }
}

public struct ResponseRewritePreview: Sendable {
    public var body: Data
    public var summary: ResponseRewriteSummary?
    public var artifact: ResponseRewriteArtifact?
    public var changes: [ResponseRewriteChange] { artifact?.changes ?? [] }
    public init(body: Data, summary: ResponseRewriteSummary? = nil, artifact: ResponseRewriteArtifact? = nil) {
        self.body = body; self.summary = summary; self.artifact = artifact
    }
}

public struct ResponseRewriteSample: Identifiable, Sendable {
    public let id = UUID()
    public var method: String
    public var url: String
    public var requestBody: Data
    public var responseBody: Data
    public init(method: String, url: String, requestBody: Data, responseBody: Data) {
        self.method = method; self.url = url; self.requestBody = requestBody; self.responseBody = responseBody
    }
}
