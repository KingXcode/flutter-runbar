import Foundation
import CryptoKit

public struct NetworkLimits: Sendable {
    public var responseBytes = 8 * 1024 * 1024
    public var bodyBytes = 1024 * 1024
    public var bodyBudget = 128 * 1024 * 1024
    public var databasePages = 8192 // 32 MiB at 4096 bytes/page; journal is transient.
    public var requests = 50_000
    public var batchRequests = 2000
    public var bodiesPerPoll = 8
    public init() {}
}

public enum NetworkBodyState: String, Codable, Sendable {
    case pending, saved, omitted, unavailable, failed
    public var title: String {
        switch self {
        case .pending: return "待缓存"
        case .saved: return "已缓存"
        case .omitted: return "超限未缓存"
        case .unavailable: return "未缓存"
        case .failed: return "缓存失败"
        }
    }
}

public struct NetworkRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var epoch: String
    public var isolateID: String
    public var requestID: String
    public var method: String
    public var url: String
    public var startMicros: Int64
    public var endMicros: Int64?
    public var status: Int?
    public var contentType: String
    public var requestBytes: Int64?
    public var responseBytes: Int64?
    public var requestHeaders: String
    public var responseHeaders: String
    public var failure: String?
    /// Version 1 stored the end of sending the request as the full duration.
    /// Missing means that an old cache cannot provide a reliable total time.
    public var timingVersion: Int?
    public var bodyState: NetworkBodyState = .pending
    public var bodyNote = ""
    public var startDate: Date { Date(timeIntervalSince1970: Double(startMicros) / 1_000_000) }
    public var durationMS: Double? { timingVersion == 2 ? endMicros.map { Double(max(0, $0 - startMicros)) / 1000 } : nil }
    public var isComplete: Bool { (timingVersion == 2 && endMicros != nil) || failure != nil }
    public static func identity(epoch: String, isolate: String, request: String) -> String {
        SHA256.hash(data: Data("\(epoch.utf8.count):\(epoch)\(isolate.utf8.count):\(isolate)\(request)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func parse(_ value: [String: Any], epoch: String, isolate: String) throws -> NetworkRecord {
        guard let requestID = value["id"] as? String, requestID.utf8.count <= 1024,
              let url = value["uri"] as? String, url.utf8.count <= 16_384,
              let method = value["method"] as? String, method.utf8.count <= 64,
              let start = value["startTime"] as? NSNumber else { throw RunbarError.message("网络摘要格式不受支持。") }
        let request = value["request"] as? [String: Any] ?? [:]
        let response = value["response"] as? [String: Any] ?? [:]
        let failure = (response["error"] as? String ?? request["error"] as? String).map { String($0.prefix(2048)) }
        // Dart's top-level endTime only finishes the upload; the response can
        // still be arriving. Cache complete bodies after response.endTime.
        let end = (response["endTime"] as? NSNumber)?.int64Value ?? (request["error"] == nil ? nil : (value["endTime"] as? NSNumber)?.int64Value)
        func headers(_ object: Any?) throws -> String {
            guard let object else { return "" }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed])
            guard data.count <= 32_768 else { return "[Headers 超过 32 KB，未缓存]" }
            return String(decoding: data, as: UTF8.self)
        }
        let responseHeaders = response["headers"] as? [String: Any] ?? [:]
        let type = responseHeaders.first { $0.key.lowercased() == "content-type" }?.value
        let contentType = (type as? [String])?.joined(separator: ", ") ?? type as? String ?? ""
        return try NetworkRecord(id: identity(epoch: epoch, isolate: isolate, request: requestID), epoch: epoch,
                                 isolateID: isolate, requestID: requestID, method: method, url: url,
                                 startMicros: start.int64Value, endMicros: end,
                                 status: (response["statusCode"] as? NSNumber)?.intValue, contentType: String(contentType.prefix(512)),
                                 requestBytes: (request["contentLength"] as? NSNumber)?.int64Value,
                                 responseBytes: (response["contentLength"] as? NSNumber)?.int64Value,
                                 requestHeaders: headers(request["headers"]), responseHeaders: headers(response["headers"]),
                                 failure: failure, timingVersion: 2)
    }
}

public struct NetworkQuery: Equatable, Sendable {
    public enum Status: String, CaseIterable, Sendable { case all, pending, success, redirect, clientError, serverError, failed }
    public var text = ""
    public var search = ""
    public var headers = ""
    public var requestBody = ""
    public var responseBody = ""
    public var globalKeywords: [String] = []
    public var urlKeywords: [String] = []
    public var headerKeywords: [String] = []
    public var requestKeywords: [String] = []
    public var responseKeywords: [String] = []
    private var exclusionWords: [NetworkKeywordScope: [String]] = [:]
    private var exclusionDrafts: [NetworkKeywordScope: String] = [:]
    public var keywordMode = NetworkKeywordMode.all
    public var jsonConditions: [NetworkJSONCondition] = []
    public var method = ""
    public var status = Status.all
    public init() {}
    public var fieldFilterCount: Int {
        [NetworkKeywordScope.url, .headers, .request, .response].filter {
            !effectiveKeywords(in: $0).isEmpty || !effectiveKeywords(in: $0, excluding: true).isEmpty
        }.count + jsonConditions.count
    }
    var needsContentSearch: Bool {
        [.everywhere, .request, .response].contains { !effectiveKeywords(in: $0).isEmpty || !effectiveKeywords(in: $0, excluding: true).isEmpty } || !jsonConditions.isEmpty
    }
    public func draft(in scope: NetworkKeywordScope, excluding: Bool = false) -> String {
        if excluding { return exclusionDrafts[scope] ?? "" }
        switch scope { case .everywhere: return search; case .url: return text; case .headers: return headers; case .request: return requestBody; case .response: return responseBody }
    }
    public func keywords(in scope: NetworkKeywordScope, excluding: Bool = false) -> [String] {
        if excluding { return exclusionWords[scope] ?? [] }
        switch scope { case .everywhere: return globalKeywords; case .url: return urlKeywords; case .headers: return headerKeywords; case .request: return requestKeywords; case .response: return responseKeywords }
    }
    public mutating func setDraft(_ value: String, in scope: NetworkKeywordScope, excluding: Bool = false) {
        let value = String(value.prefix(16_384))
        if excluding { exclusionDrafts[scope] = value.isEmpty ? nil : value; return }
        switch scope { case .everywhere: search = value; case .url: text = value; case .headers: headers = value; case .request: requestBody = value; case .response: responseBody = value }
    }
    private mutating func setKeywords(_ words: [String], in scope: NetworkKeywordScope, excluding: Bool = false) {
        if excluding { exclusionWords[scope] = words.isEmpty ? nil : words; return }
        switch scope { case .everywhere: globalKeywords = words; case .url: urlKeywords = words; case .headers: headerKeywords = words; case .request: requestKeywords = words; case .response: responseKeywords = words }
    }
    func effectiveKeywords(in scope: NetworkKeywordScope, excluding: Bool = false) -> [String] {
        Array(NetworkKeywords.combined(keywords(in: scope, excluding: excluding), draft: draft(in: scope, excluding: excluding)).prefix(NetworkKeywords.limit))
    }
    public mutating func commitKeywords(in scope: NetworkKeywordScope, excluding: Bool = false) throws {
        let words = NetworkKeywords.combined(keywords(in: scope, excluding: excluding), draft: draft(in: scope, excluding: excluding))
        guard words.count <= NetworkKeywords.limit else { throw RunbarError.message("每组包含 / 排除各最多添加 16 个关键词。") }
        setKeywords(words, in: scope, excluding: excluding); setDraft("", in: scope, excluding: excluding)
    }
    public mutating func removeKeyword(_ word: String, in scope: NetworkKeywordScope, excluding: Bool = false) {
        setKeywords(keywords(in: scope, excluding: excluding).filter { $0 != word }, in: scope, excluding: excluding)
    }
    public mutating func clearFieldFilters() {
        for scope in [NetworkKeywordScope.url, .headers, .request, .response] {
            for excluding in [false, true] { setDraft("", in: scope, excluding: excluding); setKeywords([], in: scope, excluding: excluding) }
        }
        jsonConditions = []
    }
    public func hasSameConditions(as other: Self) -> Bool { bounded == other.bounded }
    var bounded: Self {
        var value = self
        for scope in NetworkKeywordScope.allCases {
            for excluding in [false, true] {
                value.setKeywords(effectiveKeywords(in: scope, excluding: excluding), in: scope, excluding: excluding)
                value.setDraft("", in: scope, excluding: excluding)
            }
        }
        value.jsonConditions = Array(jsonConditions.prefix(16))
        return value
    }
    var metadataOnly: Self {
        var value = bounded
        for scope in [NetworkKeywordScope.everywhere, .request, .response] {
            for excluding in [false, true] { value.setDraft("", in: scope, excluding: excluding); value.setKeywords([], in: scope, excluding: excluding) }
        }
        value.jsonConditions = []; return value
    }
}

public struct NetworkPage: Sendable {
    public var records: [NetworkRecord]
    public var total: Int
    public var matching: Int
    public var page: Int
    public static let pageSize = 100
    public static let empty = NetworkPage(records: [], total: 0, matching: 0, page: 0)
}

/// Virtual rows omit headers and bodies. Even a long history only retains one
/// bounded summary window plus the separately selected request's full details.
public struct NetworkRequestSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let method: String
    public let url: String
    public let startMicros: Int64
    public let status: Int?
    public let failed: Bool
    public let durationMS: Double?
    public var startDate: Date { Date(timeIntervalSince1970: Double(startMicros) / 1_000_000) }
}
public struct NetworkListCounts: Equatable, Sendable {
    public let total: Int
    public let matching: Int
    public let isComplete: Bool
    public init(total: Int, matching: Int, isComplete: Bool = true) {
        self.total = total; self.matching = matching; self.isComplete = isComplete
    }
}
public struct NetworkListWindow: Equatable, Sendable {
    public static let capacity = 256
    public let counts: NetworkListCounts
    public let offset: Int
    public let rows: [NetworkRequestSummary]
    public var total: Int { counts.total }
    public var matching: Int { counts.matching }
    public func row(at index: Int) -> NetworkRequestSummary? {
        let local = index - offset
        return rows.indices.contains(local) ? rows[local] : nil
    }
    public static let empty = NetworkListWindow(counts: NetworkListCounts(total: 0, matching: 0), offset: 0, rows: [])
}
public struct NetworkBodyPage: Sendable {
    public let text: String
    public let page: Int
    public let pages: Int
    public let bytes: Int
}

/// Authentication stays in this ephemeral URL. Never encode it into the cache,
/// diagnostics, errors, request identities, or a separate configuration field.
public struct VMServiceEndpoint: Equatable, Sendable {
    public let url: URL
    public init?(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 16_384, var parts = URLComponents(string: value) else { return nil }
        if let nested = parts.queryItems?.first(where: { $0.name == "uri" })?.value {
            guard let parsed = URLComponents(string: nested) else { return nil }; parts = parsed
        }
        guard let host = parts.host?.lowercased(), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil,
              ["http", "https", "ws", "wss"].contains(parts.scheme?.lowercased() ?? ""),
              !parts.path.lowercased().contains("devtools") else { return nil }
        parts.scheme = ["https", "wss"].contains(parts.scheme!.lowercased()) ? "https" : "http"
        if parts.path.hasSuffix("/ws") { parts.path.removeLast(3) }
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        guard let url = parts.url else { return nil }; self.url = url
    }
}

/// Only explicit VM Service / DevTools announcements are eligible. Arbitrary
/// URLs printed by the user's app are never treated as a service connection.
public struct VMServiceDiscovery {
    private var line = ""
    public init() {}
    public mutating func consume(_ text: String, final: Bool = false) -> [VMServiceEndpoint] {
        var result: [VMServiceEndpoint] = []
        func parse(_ line: String) -> [VMServiceEndpoint] {
            let lower = line.lowercased()
            guard lower.contains("vm service") || lower.contains("devtools") || lower.hasPrefix("vm_endpoint=") else { return [] }
            guard let regex = try? NSRegularExpression(pattern: "(?:https?|wss?)://[^\\s<>\\\"\\x{001B}]+") else { return [] }
            return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
                guard let range = Range(match.range, in: line) else { return nil }
                let candidate = String(line[range]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;"))
                // A DevTools URL requires a nested service URI.
                if lower.contains("devtools"), !(candidate.contains("uri=")), !lower.contains("vm service") { return nil }
                return VMServiceEndpoint(candidate)
            }
        }
        for character in text {
            if character == "\n" || character == "\r" { result += parse(line); line = "" }
            else { line.append(character); if line.utf8.count > 32_768 { line = String(line.suffix(16_384)) } }
        }
        if final { result += parse(line); line = "" }
        return result
    }
}
