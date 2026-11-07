import Foundation
import CSQLite

/// Search is literal and case insensitive. The two keyword groups follow the
/// same include-then-exclude rule as the HTTP view, without storing any payload.
public struct ProxyWebSocketFilter: Codable, Equatable, Sendable {
    public var search = ""
    public var includes = ""
    public var excludes = ""
    public var mode = NetworkKeywordMode.all
    public init() {}
    public var isActive: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !includes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !excludes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var conditionCount: Int { (try? Self.words(includes).count + Self.words(excludes).count) ?? 0 }
    public func validate() throws {
        guard search.unicodeScalars.count <= 1024 else {
            throw RunbarError.message("WebSocket 搜索内容最多 1024 个字符。")
        }
        _ = try Self.words(includes); _ = try Self.words(excludes)
    }
    static func words(_ input: String) throws -> [String] {
        guard input.utf8.count <= 128 * 1024 else { throw RunbarError.message("WebSocket 筛选条件过长。") }
        let parts = input.split(maxSplits: 16, omittingEmptySubsequences: true) { ",，;；\n\r".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard parts.count <= 16, parts.allSatisfy({ $0.unicodeScalars.count <= 1024 }) else {
            throw RunbarError.message("包含和排除各最多 16 个关键词，每个最多 1024 个字符。")
        }
        var seen = Set<String>()
        return parts.filter { seen.insert($0.lowercased()).inserted }
    }
}

struct ProxyWebSocketMatcher {
    let includes: [String]
    let excludes: [String]
    let search: String
    let mode: NetworkKeywordMode
    let overlap: Int
    init(_ filter: ProxyWebSocketFilter) throws {
        try filter.validate()
        try self.init(search: filter.search, includes: ProxyWebSocketFilter.words(filter.includes),
                      excludes: ProxyWebSocketFilter.words(filter.excludes), mode: filter.mode)
    }
    /// Array terms remain literal, including commas and semicolons in JSON.
    /// MCP callers must not pass through the UI's delimiter-based text fields.
    init(search: String, includes: [String], excludes: [String], mode: NetworkKeywordMode) throws {
        guard search.unicodeScalars.count <= 1024, includes.count <= 16, excludes.count <= 16,
              (includes + excludes).allSatisfy({ !$0.isEmpty && $0.unicodeScalars.count <= 1024 }) else {
            throw RunbarError.message("WebSocket 关键词超过长度或数量限制。")
        }
        self.includes = includes; self.excludes = excludes
        self.search = search.trimmingCharacters(in: .whitespacesAndNewlines); self.mode = mode
        overlap = min(32 * 1024, ((includes + excludes + [search]).map { $0.utf8.count }.max() ?? 0) * 4 + 16)
    }
    func hits(in text: String, words: [String]) -> Set<String> {
        Set(words.filter { text.range(of: $0, options: [.caseInsensitive, .literal]) != nil })
    }
    var words: [String] { Array(Set(includes + excludes + (search.isEmpty ? [] : [search]))) }
    func accepts(_ hits: Set<String>) -> Bool {
        (search.isEmpty || hits.contains(search)) && mode.matches(includes, hits: hits) && hits.isDisjoint(with: excludes)
    }
    var needsFullScan: Bool { !excludes.isEmpty }
}

struct ProxyWebSocketSearchSnapshot { let total: Int; let latest: Int64 }
struct ProxyWebSocketSearchCandidate { let id: Int64; let opcode: Int; let storedBytes: Int }

/// One ephemeral, disk-backed index per reader. Only matching IDs are retained.
/// Historical messages are scanned newest first, then only appended messages
/// need to be examined on capture updates. Neither the match list nor payloads
/// grow in memory with the size of the recording.
final class ProxyWebSocketSearchIndex {
    let directory: URL
    let url: String
    let kind: String
    let filter: ProxyWebSocketFilter
    let matcher: ProxyWebSocketMatcher
    private var db: OpaquePointer?
    private var initialized = false
    private var olderThrough: Int64 = 0
    private var newerAfter: Int64 = 0
    private var target: Int64 = 0
    private var preferNewer = true
    private(set) var sourceTotal = 0
    private(set) var scannedMessages = 0
    var isComplete: Bool { initialized && olderThrough == 0 && newerAfter >= target }

    init(directory: URL, url: String, kind: String, filter: ProxyWebSocketFilter) throws {
        self.directory = directory; self.url = url; self.kind = kind; self.filter = filter
        matcher = try ProxyWebSocketMatcher(filter)
        try NetworkDiskSpace.requireAvailable(at: FileManager.default.temporaryDirectory,
            reserve: NetworkLimits().minimumFreeDiskBytes, additional: 1024 * 1024, operation: "创建 WebSocket 筛选索引")
        guard sqlite3_open_v2("", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure(); if let db { sqlite3_close_v2(db) }; db = nil; throw error
        }
        do {
            try execute("PRAGMA cache_size=-256; PRAGMA temp_store=FILE; PRAGMA mmap_size=0; PRAGMA synchronous=OFF")
            try execute("CREATE TABLE matches(id INTEGER PRIMARY KEY)")
            sqlite3_progress_handler(db, 1000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
        } catch { if let db { sqlite3_close_v2(db) }; db = nil; throw error }
    }
    deinit { if let db { sqlite3_close_v2(db) } }
    private func failure() -> RunbarError {
        .message("WebSocket 筛选索引读写失败：\(db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法创建临时数据库")")
    }
    private func execute(_ sql: String) throws {
        try Task.checkCancellation()
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        try Task.checkCancellation()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        return stmt
    }
    func scanSlice(_ store: ProxyWebSocketStore) throws {
        let snapshot = try store.searchSnapshot(url: url, kind: kind)
        if !initialized || snapshot.latest < target || snapshot.total < sourceTotal {
            try execute("DELETE FROM matches")
            olderThrough = snapshot.latest; newerAfter = snapshot.latest; initialized = true; scannedMessages = 0
        }
        target = snapshot.latest; sourceTotal = snapshot.total
        guard !isComplete else { return }
        try NetworkDiskSpace.requireAvailable(at: FileManager.default.temporaryDirectory,
            reserve: NetworkLimits().minimumFreeDiskBytes, additional: 256 * 1024, operation: "更新 WebSocket 筛选索引")
        let stop = ProcessInfo.processInfo.systemUptime + 0.08
        var processed = 0, bytes = 0
        let insert = try statement("INSERT OR IGNORE INTO matches(id) VALUES(?)")
        defer { sqlite3_finalize(insert) }
        // Alternate which pass goes first so a constant stream of expensive
        // new messages cannot prevent the historical scan from progressing.
        let passes = preferNewer ? [true, false] : [false, true]
        preferNewer.toggle()
        repeat {
            for newer in passes {
                if newer ? newerAfter >= target : olderThrough == 0 { continue }
                let candidates = try store.searchCandidates(url: url, kind: kind,
                    after: newer ? newerAfter : 0, through: newer ? target : olderThrough, newestFirst: !newer)
                for candidate in candidates {
                    try Task.checkCancellation()
                    if processed > 0, bytes + candidate.storedBytes > 4 * 1024 * 1024 { return }
                    let matches = try autoreleasepool { try store.matches(candidate, matcher: matcher) }
                    if matches {
                        sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                        sqlite3_bind_int64(insert, 1, candidate.id)
                        guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
                    }
                    // Advance only after the match has been committed. Cancellation
                    // can safely rescan the last candidate without missing a row.
                    if newer { newerAfter = candidate.id } else { olderThrough = candidate.id - 1 }
                    processed += 1; scannedMessages += 1; bytes += candidate.storedBytes
                    if ProcessInfo.processInfo.systemUptime >= stop || processed >= 512 || bytes >= 4 * 1024 * 1024 { return }
                }
                if candidates.count < 32 {
                    if newer { newerAfter = target } else { olderThrough = 0 }
                }
            }
        } while !isComplete
    }
    private func count(before id: Int64? = nil) throws -> Int {
        let stmt = try statement("SELECT count(*) FROM matches" + (id == nil ? "" : " WHERE id<?"))
        defer { sqlite3_finalize(stmt) }
        if let id { sqlite3_bind_int64(stmt, 1, id) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return Int(clamping: sqlite3_column_int64(stmt, 0))
    }
    private func row(of id: Int64) throws -> Int? {
        let stmt = try statement("SELECT 1 FROM matches WHERE id=?")
        defer { sqlite3_finalize(stmt) }; sqlite3_bind_int64(stmt, 1, id)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure() }
        return try count(before: id)
    }
    func window(around row: Int, anchorID: Int64?) throws -> (total: Int, offset: Int, ids: [Int64], anchor: Int?) {
        let total = try count(), anchor = try anchorID.flatMap { try self.row(of: $0) }
        let capacity = ProxyWebSocketWindow.capacity
        let position = max(0, min(anchor ?? row, max(0, total - 1)))
        let offset = min(max(0, position - capacity / 2), max(0, total - capacity))
        let latest = offset + capacity >= total
        let stmt = try statement("SELECT id FROM matches ORDER BY id \(latest ? "DESC" : "ASC") LIMIT \(capacity) OFFSET \(latest ? 0 : offset)")
        defer { sqlite3_finalize(stmt) }
        var ids: [Int64] = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        if latest { ids.reverse() }
        return (total, offset, ids, anchor)
    }
}
