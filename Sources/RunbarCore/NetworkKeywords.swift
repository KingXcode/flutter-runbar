import Foundation

public enum NetworkKeywordScope: String, Codable, CaseIterable, Hashable, Sendable {
    case everywhere, url, headers, request, response
}
public enum NetworkKeywordMode: String, Codable, CaseIterable, Sendable {
    case all, any
    public var title: String { self == .all ? "全部满足" : "满足任一" }
    var sqlJoin: String { self == .all ? " AND " : " OR " }
    func matches(_ words: [String], hits: Set<String>) -> Bool {
        words.isEmpty || (self == .all ? words.allSatisfy(hits.contains) : words.contains(where: hits.contains))
    }
}

enum NetworkKeywords {
    static let limit = 16
    static func word(_ value: String) -> String {
        var result = ""
        result.unicodeScalars.append(contentsOf: value.unicodeScalars.prefix(1024))
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func split(_ value: String) -> [String] {
        value.split(maxSplits: limit, omittingEmptySubsequences: true) { ",，;；\n\r".contains($0) }
            .prefix(limit + 1).map { word(String($0)) }.filter { !$0.isEmpty }
    }
    static func combined(_ saved: [String], draft: String) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for term in Array(saved.prefix(limit + 1)) + split(draft) {
            let value = word(term)
            if !value.isEmpty && seen.insert(value.lowercased()).inserted { result.append(value) }
            if result.count > limit { break }
        }
        return result
    }
}
