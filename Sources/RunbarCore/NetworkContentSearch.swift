import Foundation
import CSQLite

struct NetworkSearchSnapshot {
    let total: Int
    let lastRow: Int64
    let revision: Int64?
    let modified: Date
}
struct NetworkSearchCandidate {
    let record: NetworkRecord
    let row: Int64
    let revision: Int64
}

/// Literal, case-insensitive matching. Bodies are scanned in 64 KiB chunks,
/// with a bounded overlap so matches may span reads and UTF-8 boundaries.
struct NetworkContentMatcher {
    let query: NetworkQuery
    private let json: NetworkJSONMatcher
    init(query: NetworkQuery) throws {
        self.query = query.bounded; json = try NetworkJSONMatcher(query.jsonConditions)
    }
    private func contains(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: [.caseInsensitive, .literal]) != nil
    }
    private func hits(_ words: [String], in texts: [String]) -> Set<String> {
        Set(words.filter { word in texts.contains { contains($0, word) } })
    }
    func matches(_ record: NetworkRecord, directory: URL) throws -> Bool {
        try Task.checkCancellation()
        let mode = query.keywordMode
        let all = query.globalKeywords, request = query.requestKeywords, response = query.responseKeywords
        let excludedAll = query.effectiveKeywords(in: .everywhere, excluding: true)
        let excludedRequest = query.effectiveKeywords(in: .request, excluding: true)
        let excludedResponse = query.effectiveKeywords(in: .response, excluding: true)
        if !mode.matches(query.urlKeywords, hits: hits(query.urlKeywords, in: [record.url])) { return false }
        if !mode.matches(query.headerKeywords, hits: hits(query.headerKeywords, in: [record.requestHeaders, record.responseHeaders])) { return false }
        if !hits(query.effectiveKeywords(in: .url, excluding: true), in: [record.url]).isEmpty ||
            !hits(query.effectiveKeywords(in: .headers, excluding: true), in: [record.requestHeaders, record.responseHeaders]).isEmpty { return false }
        if !query.method.isEmpty && record.method != query.method { return false }
        switch query.status {
        case .all: break
        case .pending: if record.endMicros != nil || record.failure != nil { return false }
        case .success: if !(200...299).contains(record.status ?? 0) { return false }
        case .redirect: if !(300...399).contains(record.status ?? 0) { return false }
        case .clientError: if !(400...499).contains(record.status ?? 0) { return false }
        case .serverError: if !(500...599).contains(record.status ?? 0) { return false }
        case .failed: if record.failure == nil { return false }
        }
        let encodedParameters = URLComponents(string: record.url)?.percentEncodedQuery ?? ""
        let parameters = String(decoding: decodeForm(Data(encodedParameters.utf8)), as: UTF8.self)
        let literalParameters = encodedParameters.removingPercentEncoding ?? encodedParameters
        let metadata = [record.url, record.url.removingPercentEncoding ?? record.url, parameters, literalParameters, record.requestHeaders, record.responseHeaders]
        if !hits(excludedAll, in: metadata).isEmpty || !hits(excludedRequest, in: [parameters, literalParameters]).isEmpty { return false }
        var globalHits = hits(all, in: metadata)
        var requestHits = hits(request, in: [parameters, literalParameters]), responseHits = Set<String>()
        func missing(_ words: [String], _ found: Set<String>) -> [String] {
            mode.matches(words, hits: found) ? [] : words.filter { !found.contains($0) }
        }
        if record.bodyState == .saved {
            let requestWords = Array(Set(missing(all, globalHits) + missing(request, requestHits) + excludedAll + excludedRequest))
            let found = try scan(directory: directory, id: record.id, response: false, words: requestWords,
                                 form: record.requestHeaders.range(of: "application/x-www-form-urlencoded", options: .caseInsensitive) != nil)
            if !found.isDisjoint(with: excludedAll + excludedRequest) { return false }
            globalHits.formUnion(found); requestHits.formUnion(found)
            if !mode.matches(request, hits: requestHits) { return false }
            let responseWords = Array(Set(missing(all, globalHits) + missing(response, responseHits) + excludedAll + excludedResponse))
            let responseFound = try scan(directory: directory, id: record.id, response: true, words: responseWords, form: false)
            if !responseFound.isDisjoint(with: excludedAll + excludedResponse) { return false }
            globalHits.formUnion(responseFound); responseHits.formUnion(responseFound)
        }
        guard mode.matches(all, hits: globalHits), mode.matches(request, hits: requestHits), mode.matches(response, hits: responseHits) else { return false }
        return try json.matches(record, directory: directory)
    }
    private func scan(directory: URL, id: String, response: Bool, words: [String], form: Bool) throws -> Set<String> {
        guard !words.isEmpty, id.count == 64, id.allSatisfy(\.isHexDigit) else { return [] }
        let file = directory.appendingPathComponent("bodies/\(id).\(response ? "response" : "request")")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let overlap = min(32 * 1024, (words.map { $0.utf8.count }.max() ?? 0) * (form ? 12 : 4) + 16)
        var tail = Data(), hits = Set<String>(), read = 0
        while read <= NetworkBodyFormatter.inputLimit {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(64 * 1024, NetworkBodyFormatter.inputLimit + 1 - read)) ?? Data()
            guard !chunk.isEmpty else { break }
            read += chunk.count
            guard read <= NetworkBodyFormatter.inputLimit else { break }
            var bytes = tail; bytes.append(chunk)
            let text = String(decoding: bytes, as: UTF8.self)
            let decoded = form ? String(decoding: decodeForm(bytes), as: UTF8.self) : ""
            for word in words where !hits.contains(word) {
                if contains(text, word) || (form && contains(decoded, word)) { hits.insert(word) }
            }
            if words.allSatisfy({ hits.contains($0) }) { break }
            tail = Data(bytes.suffix(overlap))
        }
        return hits
    }
    private func decodeForm(_ data: Data) -> Data {
        func digit(_ value: UInt8) -> UInt8? {
            switch value { case 48...57: return value - 48; case 65...70: return value - 55; case 97...102: return value - 87; default: return nil }
        }
        var result = Data(); result.reserveCapacity(data.count)
        var i = 0
        while i < data.count {
            if data[i] == 37, i + 2 < data.count, let high = digit(data[i + 1]), let low = digit(data[i + 2]) {
                result.append(high * 16 + low); i += 3
            } else { result.append(data[i] == 43 ? 32 : data[i]); i += 1 }
        }
        return result
    }
}

/// A private, automatically deleted SQLite temporary database stores *only*
/// matching IDs and sort keys. No full body or unbounded match array is retained.
/// Its page cache is 256 KiB and its file is capped at 16 MiB.
final class NetworkContentIndex {
    let directory: URL
    let query: NetworkQuery
    let matcher: NetworkContentMatcher
    var worker: Task<Void, Error>?
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private(set) var sourceTotal = 0
    private(set) var initialDone = false
    private(set) var lastRow: Int64 = 0
    private(set) var baselineRow: Int64 = 0
    private(set) var lastRevision: Int64 = 0
    private(set) var targetRevision: Int64 = 0
    private var baselineRevision: Int64 = 0
    private var initialized = false
    private var versioned = false
    private var modified = Date.distantPast
    var isComplete: Bool { initialized && initialDone && (!versioned || lastRevision >= targetRevision) }

    init(directory: URL, query: NetworkQuery) throws {
        self.directory = directory; self.query = query.bounded; self.matcher = try NetworkContentMatcher(query: query)
        guard sqlite3_open_v2("", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close_v2(db) }; db = nil
            throw RunbarError.message("无法创建网络筛选临时索引。")
        }
        do {
            try execute("PRAGMA page_size=4096; PRAGMA cache_size=-256; PRAGMA temp_store=FILE; PRAGMA mmap_size=0; PRAGMA max_page_count=4096; PRAGMA synchronous=OFF;")
            try execute("CREATE TABLE matches(id TEXT PRIMARY KEY,started INTEGER NOT NULL) WITHOUT ROWID; CREATE INDEX matches_started ON matches(started,id DESC);")
        } catch { close(); throw error }
    }
    private func close() { if let db { sqlite3_close_v2(db) }; db = nil }
    deinit { close() }
    func prepare(_ source: NetworkSearchSnapshot) throws {
        let shouldReset = !initialized || versioned != (source.revision != nil) || source.total < sourceTotal ||
            (source.revision.map { $0 < lastRevision } ?? false) ||
            (!versioned && initialDone && modified != source.modified)
        if shouldReset {
            try execute("DELETE FROM matches")
            initialized = true; initialDone = false; lastRow = 0; baselineRow = source.lastRow
            baselineRevision = source.revision ?? 0; lastRevision = baselineRevision
            versioned = source.revision != nil; modified = source.modified
        }
        sourceTotal = source.total; targetRevision = source.revision ?? 0
    }
    func apply(_ candidates: [(NetworkSearchCandidate, Bool)]) throws {
        guard !candidates.isEmpty else { return }
        try execute("BEGIN")
        do {
            for (candidate, matches) in candidates {
                try Task.checkCancellation()
                let sql = matches ? "INSERT INTO matches(id,started) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET started=excluded.started" : "DELETE FROM matches WHERE id=?"
                let stmt = try statement(sql); defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, candidate.record.id, -1, transient)
                if matches { sqlite3_bind_int64(stmt, 2, candidate.record.startMicros) }
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
            }
            try execute("COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error
        }
        if initialDone { lastRevision = candidates.last!.0.revision }
        else { lastRow = candidates.last!.0.row }
    }
    func finishPass() {
        if !initialDone { initialDone = true; lastRevision = baselineRevision }
        else { lastRevision = targetRevision }
    }
    func window(around row: Int) throws -> (NetworkListCounts, Int, [String]) {
        let count = try count()
        let anchor = min(max(0, row), max(0, count - 1))
        let offset = min(max(0, anchor - NetworkListWindow.capacity / 2), max(0, count - NetworkListWindow.capacity))
        return (NetworkListCounts(total: sourceTotal, matching: count, isComplete: isComplete), offset,
                try ids(offset: offset, limit: NetworkListWindow.capacity))
    }
    func count() throws -> Int {
        let stmt = try statement("SELECT count(*) FROM matches"); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw error() }
        return Int(sqlite3_column_int64(stmt, 0))
    }
    func ids(offset: Int, limit: Int) throws -> [String] {
        let stmt = try statement("SELECT id FROM matches ORDER BY started ASC,id DESC LIMIT \(min(max(0, limit), NetworkListWindow.capacity)) OFFSET \(max(0, offset))")
        defer { sqlite3_finalize(stmt) }
        var result: [String] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) { result.append(String(cString: text)) }
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw error() }
        return result
    }
    private func error() -> Error {
        let code = sqlite3_extended_errcode(db)
        return NetworkStorageError(code: code & 0xff, extendedCode: code, operation: "读写筛选临时索引", detail: String(cString: sqlite3_errmsg(db)))
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }
}
