import Foundation

/// Only explicit filter terms are stored. Never serialize network records,
/// response bodies, VM endpoints, temporary indexes or the selected request.
extension NetworkQuery: Codable {
    private struct Group: Codable {
        let scope: NetworkKeywordScope
        let includes: [String]
        let excludes: [String]
    }
    private enum CodingKeys: String, CodingKey { case groups, keywordMode, jsonConditions, method, status }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let groups = try values.decodeIfPresent([Group].self, forKey: .groups) ?? []
        guard groups.count <= NetworkKeywordScope.allCases.count, Set(groups.map(\.scope)).count == groups.count else {
            throw RunbarError.message("已保存的网络筛选分组格式异常。")
        }
        for group in groups {
            guard group.includes.count <= NetworkKeywords.limit, group.excludes.count <= NetworkKeywords.limit,
                  (group.includes + group.excludes).allSatisfy({ $0.unicodeScalars.count <= 1024 }) else {
                throw RunbarError.message("已保存的网络关键词超过长度或数量限制。")
            }
            setKeywords(group.includes, in: group.scope)
            setKeywords(group.excludes, in: group.scope, excluding: true)
        }
        keywordMode = try values.decodeIfPresent(NetworkKeywordMode.self, forKey: .keywordMode) ?? .all
        jsonConditions = try values.decodeIfPresent([NetworkJSONCondition].self, forKey: .jsonConditions) ?? []
        method = try values.decodeIfPresent(String.self, forKey: .method) ?? ""
        status = try values.decodeIfPresent(Status.self, forKey: .status) ?? .all
        self = try savedSnapshot()
    }
    public func encode(to encoder: Encoder) throws {
        let query = try savedSnapshot()
        var values = encoder.container(keyedBy: CodingKeys.self)
        let groups = NetworkKeywordScope.allCases.map {
            Group(scope: $0, includes: query.keywords(in: $0), excludes: query.keywords(in: $0, excluding: true))
        }.filter { !$0.includes.isEmpty || !$0.excludes.isEmpty }
        try values.encode(groups, forKey: .groups)
        try values.encode(query.keywordMode, forKey: .keywordMode)
        try values.encode(query.jsonConditions, forKey: .jsonConditions)
        try values.encode(query.method, forKey: .method)
        try values.encode(query.status, forKey: .status)
    }
    public var isEmpty: Bool {
        method.isEmpty && status == .all && jsonConditions.isEmpty && NetworkKeywordScope.allCases.allSatisfy {
            effectiveKeywords(in: $0).isEmpty && effectiveKeywords(in: $0, excluding: true).isEmpty
        }
    }
    /// Commit live keyword drafts as tags without changing their meaning. Check
    /// limits before saving so a scheme can never silently lose extra conditions.
    public func savedSnapshot() throws -> Self {
        var query = self
        for scope in NetworkKeywordScope.allCases {
            try query.commitKeywords(in: scope)
            try query.commitKeywords(in: scope, excluding: true)
        }
        guard method.utf8.count <= 64, !method.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              jsonConditions.count <= 16, Set(jsonConditions.map(\.id)).count == jsonConditions.count else {
            throw RunbarError.message("筛选方法或 JSON 条件超过限制，无法保存。")
        }
        for rule in jsonConditions { try rule.validate() }
        return query
    }
}

public struct NetworkFilterPreset: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var query: NetworkQuery
    public init(name: String, query: NetworkQuery) { self.name = name; self.query = query }
}

public struct NetworkFilterPreferences: Codable, Equatable, Sendable {
    public static let byteLimit = 1024 * 1024
    public private(set) var query = NetworkQuery()
    public private(set) var presets: [NetworkFilterPreset] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, query, presets }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decodeIfPresent(Int.self, forKey: .version) ?? 1 == 1 else {
            throw RunbarError.message("网络筛选设置版本不受支持。")
        }
        query = try values.decodeIfPresent(NetworkQuery.self, forKey: .query) ?? NetworkQuery()
        presets = try values.decodeIfPresent([NetworkFilterPreset].self, forKey: .presets) ?? []
        guard presets.count <= 32, Set(presets.map(\.id)).count == presets.count,
              Set(presets.map { $0.name.lowercased() }).count == presets.count,
              presets.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 80 }) else {
            throw RunbarError.message("已保存的网络筛选方案格式异常或超过数量限制。")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encode(query, forKey: .query)
        try values.encode(presets, forKey: .presets)
    }
    public static func load(_ data: Data) throws -> Self {
        guard data.count <= byteLimit else { throw RunbarError.message("网络筛选设置超过 1 MB，无法读取。") }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func data() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.byteLimit else { throw RunbarError.message("网络筛选设置超过 1 MB，请删除不用的方案或缩短关键词。") }
        return data
    }
    public mutating func remember(_ query: NetworkQuery) throws { self.query = try query.savedSnapshot() }
    public mutating func savePreset(name: String, query: NetworkQuery) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw RunbarError.message("请填写 1–80 个字符的方案名称。") }
        let query = try query.savedSnapshot()
        var next = self
        next.query = query
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            next.presets[index].name = name; next.presets[index].query = query
        } else {
            guard presets.count < 32 else { throw RunbarError.message("最多保存 32 个网络筛选方案，请先删除不用的方案。") }
            next.presets.append(NetworkFilterPreset(name: name, query: query))
        }
        _ = try next.data(); self = next
    }
    public mutating func usePreset(_ id: UUID) throws {
        guard let preset = presets.first(where: { $0.id == id }) else { throw RunbarError.message("该网络筛选方案已不存在。") }
        query = try preset.query.savedSnapshot()
    }
    public mutating func removePreset(_ id: UUID) { presets.removeAll { $0.id == id } }
}
