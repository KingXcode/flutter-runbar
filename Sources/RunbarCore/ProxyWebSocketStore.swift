import Foundation
import CSQLite

/// Payloads stay on disk. Message lists read only a bounded preview; full
/// messages and handshake headers are fetched only for the selected row.
final class ProxyWebSocketStore {
    private var db: OpaquePointer?
    private let directory: URL
    private let readOnly: Bool
    private var deadline = TimeInterval.infinity
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL, readOnly: Bool = false) throws {
        self.directory = directory; self.readOnly = readOnly
        if !readOnly { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(directory.appendingPathComponent("websockets.sqlite").path, &db, flags, nil) == SQLITE_OK else {
            let error = failure(); if let db { sqlite3_close_v2(db) }; db = nil; throw error
        }
        do {
            sqlite3_busy_timeout(db, 500)
            if readOnly {
                sqlite3_progress_handler(db, 1000, { context in
                    guard let context else { return 1 }
                    let store = Unmanaged<ProxyWebSocketStore>.fromOpaque(context).takeUnretainedValue()
                    return Task<Never, Never>.isCancelled || ProcessInfo.processInfo.systemUptime >= store.deadline ? 1 : 0
                }, Unmanaged.passUnretained(self).toOpaque())
            }
            try execute("PRAGMA cache_size=-2048")
            try execute("PRAGMA temp_store=FILE")
            if !readOnly {
                try execute("PRAGMA journal_mode=WAL")
                try execute("PRAGMA wal_autocheckpoint=256")
                try execute("CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, flow_id TEXT NOT NULL, url TEXT NOT NULL, timestamp INTEGER NOT NULL, kind TEXT NOT NULL, opcode INTEGER NOT NULL, bytes INTEGER NOT NULL, note TEXT NOT NULL, payload BLOB NOT NULL, close_code INTEGER, request_headers TEXT, response_headers TEXT)")
                try execute("CREATE INDEX IF NOT EXISTS events_flow ON events(flow_id,id)")
                try execute("CREATE INDEX IF NOT EXISTS events_url_order ON events(url,id,kind)")
                if try !hasURLIndex() {
                    // New sessions are empty. Reopening an older writable cache
                    // builds the URL catalogue once, without reading payloads.
                    try execute("BEGIN IMMEDIATE")
                    do {
                        try execute("CREATE TABLE connection_urls (url TEXT PRIMARY KEY, first_id INTEGER NOT NULL, send_count INTEGER NOT NULL, receive_count INTEGER NOT NULL) WITHOUT ROWID")
                        try execute("INSERT INTO connection_urls SELECT url,min(id),sum(kind='send'),sum(kind='receive') FROM events GROUP BY url")
                        try execute("CREATE INDEX connection_urls_order ON connection_urls(first_id DESC)")
                        try execute("COMMIT")
                    } catch { try? execute("ROLLBACK"); throw error }
                }
                if try !hasTable("connection_flows") {
                    try execute("BEGIN IMMEDIATE")
                    do {
                        try execute("CREATE TABLE connection_flows (flow_id TEXT PRIMARY KEY, url TEXT NOT NULL, first_id INTEGER NOT NULL, opened INTEGER NOT NULL, closed INTEGER NOT NULL) WITHOUT ROWID")
                        try execute("INSERT INTO connection_flows SELECT flow_id,min(url),min(id),max(kind='open'),max(kind='close') FROM events GROUP BY flow_id")
                        try execute("CREATE INDEX connection_flows_order ON connection_flows(first_id DESC)")
                        try execute("COMMIT")
                    } catch { try? execute("ROLLBACK"); throw error }
                }
            }
        } catch { close(); throw error }
    }
    deinit { close() }
    func close() { if let db { sqlite3_close_v2(db) }; db = nil }
    private func failure() -> RunbarError {
        .message("WebSocket 缓存读写失败：\(db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库")")
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        try Task.checkCancellation()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        return stmt
    }
    private func bind(_ value: String, to stmt: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(stmt, index, value, -1, transient) == SQLITE_OK else { throw failure() }
    }
    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }
    private func hasURLIndex() throws -> Bool { try hasTable("connection_urls") }
    private func hasTable(_ name: String) throws -> Bool {
        let stmt = try statement("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?")
        defer { sqlite3_finalize(stmt) }
        try bind(name, to: stmt, at: 1)
        let result = sqlite3_step(stmt)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure() }
        return result == SQLITE_ROW
    }
    func append(_ event: ProxyWebSocketEvent) throws {
        guard !readOnly, event.id > 0, event.payload.count <= 1024 * 1024,
              event.url.utf8.count <= 16_384, event.flowID.utf8.count <= 1024,
              (event.requestHeaders?.utf8.count ?? 0) <= 32_768,
              (event.responseHeaders?.utf8.count ?? 0) <= 32_768 else { throw RunbarError.message("WebSocket 事件超过缓存限制。") }
        try NetworkDiskSpace.requireAvailable(at: directory, reserve: 512 * 1024 * 1024,
                                             additional: Int64(event.payload.count) * 3 + 1024 * 1024, operation: "写入 WebSocket 缓存")
        try execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? execute("ROLLBACK") } }
        let stmt = try statement("INSERT INTO events (id,flow_id,url,timestamp,kind,opcode,bytes,note,payload,close_code,request_headers,response_headers) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, event.id)
        try bind(event.flowID, to: stmt, at: 2); try bind(event.url, to: stmt, at: 3)
        sqlite3_bind_int64(stmt, 4, event.timestamp); try bind(event.kind.rawValue, to: stmt, at: 5)
        sqlite3_bind_int(stmt, 6, Int32(clamping: event.opcode)); sqlite3_bind_int64(stmt, 7, event.bytes)
        try bind(String(event.note.prefix(2048)), to: stmt, at: 8)
        if event.payload.isEmpty { sqlite3_bind_zeroblob(stmt, 9, 0) }
        else {
            let result = event.payload.withUnsafeBytes { sqlite3_bind_blob(stmt, 9, $0.baseAddress, Int32($0.count), transient) }
            guard result == SQLITE_OK else { throw failure() }
        }
        if let code = event.closeCode { sqlite3_bind_int64(stmt, 10, Int64(code)) }
        if let value = event.requestHeaders { try bind(value, to: stmt, at: 11) }
        if let value = event.responseHeaders { try bind(value, to: stmt, at: 12) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        let url = try statement("INSERT INTO connection_urls (url,first_id,send_count,receive_count) VALUES (?,?,?,?) ON CONFLICT(url) DO UPDATE SET first_id=min(first_id,excluded.first_id),send_count=send_count+excluded.send_count,receive_count=receive_count+excluded.receive_count")
        defer { sqlite3_finalize(url) }
        try bind(event.url, to: url, at: 1); sqlite3_bind_int64(url, 2, event.id)
        sqlite3_bind_int(url, 3, event.kind == .send ? 1 : 0); sqlite3_bind_int(url, 4, event.kind == .receive ? 1 : 0)
        guard sqlite3_step(url) == SQLITE_DONE else { throw failure() }
        let flow = try statement("INSERT INTO connection_flows VALUES (?,?,?,?,?) ON CONFLICT(flow_id) DO UPDATE SET opened=max(opened,excluded.opened),closed=max(closed,excluded.closed)")
        defer { sqlite3_finalize(flow) }
        try bind(event.flowID, to: flow, at: 1); try bind(event.url, to: flow, at: 2)
        sqlite3_bind_int64(flow, 3, event.id)
        sqlite3_bind_int(flow, 4, event.kind == .open ? 1 : 0)
        sqlite3_bind_int(flow, 5, event.kind == .close ? 1 : 0)
        guard sqlite3_step(flow) == SQLITE_DONE else { throw failure() }
        try execute("COMMIT"); committed = true
    }
    func connections(filter: String, around row: Int) throws -> ProxyWebSocketURLWindow {
        deadline = ProcessInfo.processInfo.systemUptime + 3
        try execute("BEGIN DEFERRED")
        defer { try? execute("ROLLBACK") }
        // Legacy read-only caches use the same bounded result window without
        // modifying or backfilling a historical database.
        let source = try hasURLIndex() ? "connection_urls" : "(SELECT url,min(id) AS first_id FROM events GROUP BY url)"
        let predicate = " WHERE (?='' OR instr(lower(url),lower(?))>0)"
        func prepare(_ sql: String) throws -> OpaquePointer {
            let stmt = try statement(sql)
            do { try bind(String(filter.prefix(1024)), to: stmt, at: 1); try bind(String(filter.prefix(1024)), to: stmt, at: 2) }
            catch { sqlite3_finalize(stmt); throw error }
            return stmt
        }
        let count = try prepare("SELECT count(*) FROM " + source + predicate)
        guard sqlite3_step(count) == SQLITE_ROW else { sqlite3_finalize(count); throw failure() }
        let total = Int(clamping: sqlite3_column_int64(count, 0)); sqlite3_finalize(count)
        let capacity = ProxyWebSocketURLWindow.capacity
        let offset = min(max(0, row - capacity / 2), max(0, total - capacity))
        let stmt = try prepare("SELECT url FROM " + source + predicate + " ORDER BY first_id DESC LIMIT \(capacity) OFFSET \(offset)")
        defer { sqlite3_finalize(stmt) }
        var urls: [String] = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            urls.append(text(stmt, 0))
        }
        return ProxyWebSocketURLWindow(total: total, offset: offset, urls: urls)
    }
    func flows(filter: String, around row: Int, running: Bool, activeIDs: Set<String>?) throws -> ProxyWebSocketFlowWindow {
        deadline = ProcessInfo.processInfo.systemUptime + 3
        try execute("BEGIN DEFERRED")
        defer { try? execute("ROLLBACK") }
        // Legacy read-only caches use the same bounded result window without
        // modifying or backfilling a historical database.
        let source = try hasTable("connection_flows") ? "connection_flows" : "(SELECT flow_id,min(url) AS url,min(id) AS first_id,max(kind='open') AS opened,max(kind='close') AS closed FROM events GROUP BY flow_id)"
        let predicate = " WHERE (?='' OR instr(lower(url),lower(?))>0)"
        func prepare(_ sql: String) throws -> OpaquePointer {
            let stmt = try statement(sql)
            do { try bind(String(filter.prefix(1024)), to: stmt, at: 1); try bind(String(filter.prefix(1024)), to: stmt, at: 2) }
            catch { sqlite3_finalize(stmt); throw error }
            return stmt
        }
        let count = try prepare("SELECT count(*) FROM " + source + predicate)
        guard sqlite3_step(count) == SQLITE_ROW else { sqlite3_finalize(count); throw failure() }
        let total = Int(clamping: sqlite3_column_int64(count, 0)); sqlite3_finalize(count)
        let capacity = ProxyWebSocketURLWindow.capacity
        let offset = min(max(0, row - capacity / 2), max(0, total - capacity))
        let stmt = try prepare("SELECT flow_id,url,opened,closed FROM " + source + predicate + " ORDER BY first_id DESC LIMIT \(capacity) OFFSET \(offset)")
        defer { sqlite3_finalize(stmt) }
        var rows: [ProxyWebSocketFlow] = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            let id = text(stmt, 0)
            let state: ProxyWebSocketFlow.State
            if !running || sqlite3_column_int(stmt, 3) != 0 { state = .closed }
            else if let activeIDs { state = activeIDs.contains(id) ? .connected : .closed }
            else { state = sqlite3_column_int(stmt, 2) != 0 ? .connected : .unknown }
            rows.append(.init(id: id, url: text(stmt, 1), state: state))
        }
        return ProxyWebSocketFlowWindow(total: total, offset: offset, rows: rows)
    }
    func window(url: String, kind: String, around row: Int, exactURL: String? = nil,
                messagesOnly: Bool = false, includePreview: Bool = false, flowID: String? = nil) throws -> ProxyWebSocketWindow {
        deadline = ProcessInfo.processInfo.systemUptime + 3
        try execute("BEGIN DEFERRED")
        defer { try? execute("ROLLBACK") }
        let predicate = " WHERE (?='' OR instr(lower(url),lower(?))>0 OR instr(lower(flow_id),lower(?))>0) AND (?='' OR kind=?)" +
            (exactURL == nil ? "" : " AND url=?6") + (flowID == nil ? "" : " AND flow_id=?7") + (messagesOnly ? " AND kind IN ('send','receive')" : "")
        func prepare(_ sql: String) throws -> OpaquePointer {
            let stmt = try statement(sql)
            do {
                try bind(String(url.prefix(1024)), to: stmt, at: 1); try bind(String(url.prefix(1024)), to: stmt, at: 2)
                try bind(String(url.prefix(1024)), to: stmt, at: 3)
                try bind(kind, to: stmt, at: 4); try bind(kind, to: stmt, at: 5)
                if let exactURL { try bind(exactURL, to: stmt, at: 6) }
                if let flowID { try bind(flowID, to: stmt, at: 7) }
            } catch { sqlite3_finalize(stmt); throw error }
            return stmt
        }
        let count: OpaquePointer
        if let exactURL, flowID == nil, messagesOnly, url.isEmpty, ["", "send", "receive"].contains(kind), try hasURLIndex() {
            let column = kind == "send" ? "send_count" : kind == "receive" ? "receive_count" : "send_count+receive_count"
            count = try statement("SELECT coalesce((SELECT \(column) FROM connection_urls WHERE url=?),0)")
            do { try bind(exactURL, to: count, at: 1) } catch { sqlite3_finalize(count); throw error }
        } else { count = try prepare("SELECT count(*) FROM events" + predicate) }
        guard sqlite3_step(count) == SQLITE_ROW else { sqlite3_finalize(count); throw failure() }
        let total = Int(clamping: sqlite3_column_int64(count, 0)); sqlite3_finalize(count)
        let capacity = ProxyWebSocketWindow.capacity
        let offset = row == Int.max ? max(0, total - capacity) : min(max(0, row - capacity / 2), max(0, total - capacity))
        // The newest page uses the PK in reverse, without walking the entire cache.
        let latest = offset + capacity >= total
        let stmt = try prepare("SELECT id,flow_id,url,timestamp,kind,opcode,bytes,note" +
                               (includePreview ? ",substr(payload,1,512)" : "") + " FROM events" + predicate +
                               (latest ? " ORDER BY id DESC LIMIT \(min(capacity, max(0, total - offset)))" : " ORDER BY id LIMIT \(capacity) OFFSET \(offset)"))
        defer { sqlite3_finalize(stmt) }
        var rows: [ProxyWebSocketSummary] = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let kind = ProxyWebSocketEvent.Kind(rawValue: text(stmt, 4)) else { throw failure() }
            var summary = ProxyWebSocketSummary(id: sqlite3_column_int64(stmt, 0), flowID: text(stmt, 1), url: text(stmt, 2),
                timestamp: sqlite3_column_int64(stmt, 3), kind: kind, opcode: Int(sqlite3_column_int(stmt, 5)),
                bytes: sqlite3_column_int64(stmt, 6), note: text(stmt, 7))
            if includePreview, let pointer = sqlite3_column_blob(stmt, 8) {
                let bytes = Data(bytes: pointer, count: min(512, Int(sqlite3_column_bytes(stmt, 8))))
                summary.preview = summary.opcode == 2 ? "[二进制 / Base64] " + bytes.base64EncodedString() :
                    String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: " ↵ ")
                        .replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\r", with: " ↵ ")
                        .replacingOccurrences(of: "\t", with: " ")
                if summary.bytes > 512 { summary.preview += " …" }
            }
            rows.append(summary)
        }
        if latest { rows.reverse() }
        return ProxyWebSocketWindow(total: total, offset: offset, rows: rows)
    }
    func event(_ id: Int64) throws -> ProxyWebSocketEvent? {
        deadline = ProcessInfo.processInfo.systemUptime + 3
        let stmt = try statement("SELECT id,flow_id,url,timestamp,kind,opcode,bytes,note,payload,close_code,request_headers,response_headers FROM events WHERE id=?")
        defer { sqlite3_finalize(stmt) }; sqlite3_bind_int64(stmt, 1, id)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let kind = ProxyWebSocketEvent.Kind(rawValue: text(stmt, 4)) else { throw failure() }
        let length = Int(sqlite3_column_bytes(stmt, 8))
        guard length <= 1024 * 1024 else { throw RunbarError.message("WebSocket 缓存消息超过 1 MB。") }
        let payload = sqlite3_column_blob(stmt, 8).map { Data(bytes: $0, count: length) } ?? Data()
        return ProxyWebSocketEvent(id: id, flowID: text(stmt, 1), url: text(stmt, 2), timestamp: sqlite3_column_int64(stmt, 3),
            kind: kind, opcode: Int(sqlite3_column_int(stmt, 5)), bytes: sqlite3_column_int64(stmt, 6), payload: payload,
            note: text(stmt, 7), closeCode: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 9)),
            requestHeaders: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : text(stmt, 10),
            responseHeaders: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : text(stmt, 11))
    }
    func searchSnapshot(url: String, kind: String, flowID: String? = nil) throws -> ProxyWebSocketSearchSnapshot {
        deadline = ProcessInfo.processInfo.systemUptime + 3
        let column = kind == "send" ? "send_count" : kind == "receive" ? "receive_count" : "send_count+receive_count"
        let flowPredicate = flowID == nil ? "" : " AND flow_id=?3"
        let countSQL = try flowID == nil && hasURLIndex() ?
            "coalesce((SELECT \(column) FROM connection_urls WHERE url=?1),0)" :
            "(SELECT count(*) FROM events WHERE url=?1 AND kind IN ('send','receive') AND (?2='' OR kind=?2)\(flowPredicate))"
        let stmt = try statement("SELECT \(countSQL),coalesce((SELECT max(id) FROM events WHERE url=?1 AND kind IN ('send','receive') AND (?2='' OR kind=?2)\(flowPredicate)),0)")
        defer { sqlite3_finalize(stmt) }
        try bind(url, to: stmt, at: 1); try bind(kind, to: stmt, at: 2)
        if let flowID { try bind(flowID, to: stmt, at: 3) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return ProxyWebSocketSearchSnapshot(total: Int(clamping: sqlite3_column_int64(stmt, 0)), latest: sqlite3_column_int64(stmt, 1))
    }
    func searchCandidates(url: String, kind: String, after: Int64, through: Int64,
                          newestFirst: Bool, flowID: String? = nil) throws -> [ProxyWebSocketSearchCandidate] {
        let stmt = try statement("SELECT id,opcode,length(payload) FROM events WHERE url=? AND (?='' OR kind=?) AND kind IN ('send','receive') AND id>? AND id<=? \(flowID == nil ? "" : "AND flow_id=?") ORDER BY id \(newestFirst ? "DESC" : "ASC") LIMIT 32")
        defer { sqlite3_finalize(stmt) }
        try bind(url, to: stmt, at: 1); try bind(kind, to: stmt, at: 2); try bind(kind, to: stmt, at: 3)
        sqlite3_bind_int64(stmt, 4, after); sqlite3_bind_int64(stmt, 5, through)
        if let flowID { try bind(flowID, to: stmt, at: 6) }
        var rows: [ProxyWebSocketSearchCandidate] = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            rows.append(.init(id: sqlite3_column_int64(stmt, 0), opcode: Int(sqlite3_column_int(stmt, 1)),
                              storedBytes: Int(sqlite3_column_int64(stmt, 2))))
        }
        return rows
    }
    func matches(_ candidate: ProxyWebSocketSearchCandidate, matcher: ProxyWebSocketMatcher) throws -> Bool {
        var blob: OpaquePointer?
        guard sqlite3_blob_open(db, "main", "events", "payload", candidate.id, 0, &blob) == SQLITE_OK, let blob else { throw failure() }
        defer { sqlite3_blob_close(blob) }
        let length = Int(sqlite3_blob_bytes(blob))
        guard length <= 1024 * 1024 else { throw RunbarError.message("WebSocket 缓存消息超过 1 MB。") }
        var offset = 0, tail = Data(), hits = Set<String>()
        let words = matcher.words
        while offset < length {
            try Task.checkCancellation()
            // A multiple of three keeps Base64 chunks aligned with the full
            // binary detail representation. Text keeps raw UTF-8 overlap.
            let count = min(63 * 1024, length - offset)
            var bytes = Data(count: count)
            let result = bytes.withUnsafeMutableBytes { sqlite3_blob_read(blob, $0.baseAddress, Int32(count), Int32(offset)) }
            guard result == SQLITE_OK else { throw failure() }
            offset += count
            if candidate.opcode == 2 { bytes = Data(bytes.base64EncodedString().utf8) }
            var combined = tail; combined.append(bytes)
            hits.formUnion(matcher.hits(in: String(decoding: combined, as: UTF8.self), words: words.filter { !hits.contains($0) }))
            if !hits.isDisjoint(with: matcher.excludes) { return false }
            if !matcher.needsFullScan, matcher.accepts(hits) { return true }
            tail = Data(combined.suffix(matcher.overlap))
        }
        return matcher.accepts(hits)
    }
    func summaries(ids: [Int64]) throws -> [ProxyWebSocketSummary] {
        guard !ids.isEmpty else { return [] }
        let ids = Array(ids.prefix(ProxyWebSocketWindow.capacity))
        let stmt = try statement("SELECT id,flow_id,url,timestamp,kind,opcode,bytes,note,substr(payload,1,512) FROM events WHERE id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ","))) ORDER BY id")
        defer { sqlite3_finalize(stmt) }
        for (index, id) in ids.enumerated() { sqlite3_bind_int64(stmt, Int32(index + 1), id) }
        var rows: [ProxyWebSocketSummary] = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let kind = ProxyWebSocketEvent.Kind(rawValue: text(stmt, 4)) else { throw failure() }
            var summary = ProxyWebSocketSummary(id: sqlite3_column_int64(stmt, 0), flowID: text(stmt, 1), url: text(stmt, 2),
                timestamp: sqlite3_column_int64(stmt, 3), kind: kind, opcode: Int(sqlite3_column_int(stmt, 5)),
                bytes: sqlite3_column_int64(stmt, 6), note: text(stmt, 7))
            if let pointer = sqlite3_column_blob(stmt, 8) {
                let bytes = Data(bytes: pointer, count: min(512, Int(sqlite3_column_bytes(stmt, 8))))
                summary.preview = summary.opcode == 2 ? "[二进制 / Base64] " + bytes.base64EncodedString() :
                    String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: " ↵ ")
                        .replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\r", with: " ↵ ")
                        .replacingOccurrences(of: "\t", with: " ")
                if summary.bytes > 512 { summary.preview += " …" }
            }
            rows.append(summary)
        }
        return rows
    }
    func handshake(_ flowID: String) throws -> (String, String) {
        let stmt = try statement("SELECT request_headers,response_headers FROM events WHERE flow_id=? AND kind='open' ORDER BY id LIMIT 1")
        defer { sqlite3_finalize(stmt) }; try bind(flowID, to: stmt, at: 1)
        let result = sqlite3_step(stmt)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure() }
        return result == SQLITE_ROW ? (text(stmt, 0), text(stmt, 1)) : ("", "")
    }
    func closure(_ flowID: String) throws -> (date: Date, code: Int?, reason: String)? {
        let stmt = try statement("SELECT timestamp,close_code,note FROM events WHERE flow_id=? AND kind='close' ORDER BY id DESC LIMIT 1")
        defer { sqlite3_finalize(stmt) }; try bind(flowID, to: stmt, at: 1)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure() }
        return (Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 0)) / 1_000_000),
                sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 1)), text(stmt, 2))
    }
}

extension ProxyWebSocketStore {
    /// Read-only catalogues also support older caches without writing a
    /// migration/index into the original database.
    private func mcpURLSource() throws -> String {
        try hasURLIndex() ? "connection_urls" :
            "(SELECT url,min(id) AS first_id,sum(kind='send') AS send_count,sum(kind='receive') AS receive_count FROM events GROUP BY url)"
    }
    func mcpStatistics() throws -> (urls: Int64, messages: Int64, latest: Int64) {
        deadline = ProcessInfo.processInfo.systemUptime + 3
        let stmt = try statement("SELECT count(*),coalesce(sum(send_count+receive_count),0),coalesce((SELECT max(id) FROM events WHERE kind IN ('send','receive')),0) FROM \(try mcpURLSource())")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return (sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1), sqlite3_column_int64(stmt, 2))
    }
    func mcpConnections(filter: String, offset: Int, limit: Int) throws -> (total: Int, rows: [MCPWebSocketURL]) {
        deadline = ProcessInfo.processInfo.systemUptime + 3
        try execute("BEGIN DEFERRED"); defer { try? execute("ROLLBACK") }
        let source = try mcpURLSource(), predicate = " WHERE (?='' OR instr(lower(url),lower(?))>0)"
        func prepare(_ sql: String) throws -> OpaquePointer {
            let stmt = try statement(sql)
            do { try bind(filter, to: stmt, at: 1); try bind(filter, to: stmt, at: 2) }
            catch { sqlite3_finalize(stmt); throw error }
            return stmt
        }
        let count = try prepare("SELECT count(*) FROM \(source)" + predicate)
        guard sqlite3_step(count) == SQLITE_ROW else { sqlite3_finalize(count); throw failure() }
        let total = Int(clamping: sqlite3_column_int64(count, 0)); sqlite3_finalize(count)
        let stmt = try prepare("SELECT url,send_count,receive_count,(SELECT timestamp FROM events WHERE id=first_id) FROM \(source)" +
                               predicate + " ORDER BY first_id DESC LIMIT \(min(100, max(1, limit))) OFFSET \(max(0, offset))")
        defer { sqlite3_finalize(stmt) }
        var rows: [MCPWebSocketURL] = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            rows.append(MCPWebSocketURL(url: text(stmt, 0), sent: sqlite3_column_int64(stmt, 1), received: sqlite3_column_int64(stmt, 2),
                firstSeen: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3)))
        }
        return (total, rows)
    }
    func mcpCandidates(query: MCPWebSocketQuery, cursor: Int64?, through: Int64,
                       limit: Int = 32) throws -> [ProxyWebSocketSearchCandidate] {
        deadline = ProcessInfo.processInfo.systemUptime + 3
        let lower = query.ascending ? cursor ?? 0 : 0
        let upper = query.ascending ? through : min(through, cursor.map { $0 - 1 } ?? through)
        if upper <= lower { return [] }
        let conditions = (query.connectionID.isEmpty ? "" : " AND flow_id=?") + (query.kind.isEmpty ? "" : " AND kind=?")
        let stmt = try statement("SELECT id,opcode,length(payload) FROM events WHERE url=? AND kind IN ('send','receive') AND id>? AND id<=?" + conditions + " ORDER BY id \(query.ascending ? "ASC" : "DESC") LIMIT \(min(32, max(1, limit)))")
        defer { sqlite3_finalize(stmt) }
        try bind(query.url, to: stmt, at: 1)
        sqlite3_bind_int64(stmt, 2, lower); sqlite3_bind_int64(stmt, 3, upper)
        var parameter: Int32 = 4
        if !query.connectionID.isEmpty { try bind(query.connectionID, to: stmt, at: parameter); parameter += 1 }
        if !query.kind.isEmpty { try bind(query.kind, to: stmt, at: parameter) }
        var rows: [ProxyWebSocketSearchCandidate] = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            rows.append(.init(id: sqlite3_column_int64(stmt, 0), opcode: Int(sqlite3_column_int(stmt, 1)),
                              storedBytes: Int(sqlite3_column_int64(stmt, 2))))
        }
        return rows
    }
    func mcpCachedBytes(_ id: Int64) throws -> Int {
        deadline = ProcessInfo.processInfo.systemUptime + 3
        let stmt = try statement("SELECT length(payload) FROM events WHERE id=?")
        defer { sqlite3_finalize(stmt) }; sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        let size = Int(sqlite3_column_int64(stmt, 0))
        guard size <= 1024 * 1024 else { throw RunbarError.message("WebSocket 缓存消息超过 1 MB。") }
        return size
    }
}

public struct ProxyWebSocketDetail: Sendable {
    public let text: String
    public let page: Int
    public let pages: Int
    public let note: String
}

public struct ProxyWebSocketFlow: Equatable, Identifiable, Sendable {
    public enum State: String, Sendable {
        case connected = "已连接", closed = "已断开", unknown = "未知"
    }
    public let id: String
    public let url: String
    public let state: State
}

public struct ProxyWebSocketFlowWindow: Equatable, Sendable {
    public let total: Int
    public let offset: Int
    public let rows: [ProxyWebSocketFlow]
    public static let empty = Self(total: 0, offset: 0, rows: [])
    public func row(at index: Int) -> ProxyWebSocketFlow? {
        let local = index - offset
        return rows.indices.contains(local) ? rows[local] : nil
    }
}

public actor ProxyWebSocketReader {
    private var searchIndex: ProxyWebSocketSearchIndex?
    public init() {}
    public func connections(directory: URL, filter: String, around row: Int) throws -> ProxyWebSocketURLWindow {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("websockets.sqlite").path) else { return .empty }
        let store = try ProxyWebSocketStore(directory: directory, readOnly: true)
        defer { store.close() }
        return try store.connections(filter: filter, around: row)
    }
    public func flows(directory: URL, filter: String, around row: Int, running: Bool) throws -> ProxyWebSocketFlowWindow {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("websockets.sqlite").path) else { return .empty }
        let store = try ProxyWebSocketStore(directory: directory, readOnly: true)
        defer { store.close() }
        let active = running ? (try? ProxyWebSocketSender.connections(directory: directory)).map { Set($0.map(\.id)) } : nil
        return try store.flows(filter: filter, around: row, running: running, activeIDs: active)
    }
    public func messages(directory: URL, url: String, kind: String, around row: Int,
                         filter: ProxyWebSocketFilter = ProxyWebSocketFilter(), anchorID: Int64? = nil, flowID: String? = nil) throws -> ProxyWebSocketWindow {
        try filter.validate()
        guard ["", "send", "receive"].contains(kind) else { throw RunbarError.message("未知的 WebSocket 消息方向。") }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("websockets.sqlite").path) else {
            searchIndex = nil; return .empty
        }
        let store = try ProxyWebSocketStore(directory: directory, readOnly: true)
        defer { store.close() }
        if filter.isActive {
            let index: ProxyWebSocketSearchIndex
            if let current = searchIndex, current.directory == directory, current.url == url,
               current.kind == kind, current.filter == filter, current.flowID == flowID { index = current }
            else {
                searchIndex = nil
                index = try ProxyWebSocketSearchIndex(directory: directory, url: url, kind: kind, filter: filter, flowID: flowID)
                searchIndex = index
            }
            try index.scanSlice(store)
            let result = try index.window(around: row, anchorID: anchorID)
            return ProxyWebSocketWindow(total: result.total, offset: result.offset, rows: try store.summaries(ids: result.ids),
                sourceTotal: index.sourceTotal, isComplete: index.isComplete, anchorRow: result.anchor)
        }
        searchIndex = nil
        return try store.window(url: "", kind: kind, around: row, exactURL: url, messagesOnly: true, includePreview: true, flowID: flowID)
    }
    public func cancelSearch(directory: URL) {
        if searchIndex?.directory == directory { searchIndex = nil }
    }
    public func window(directory: URL, url: String, kind: String, around row: Int) throws -> ProxyWebSocketWindow {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("websockets.sqlite").path) else { return .empty }
        let store = try ProxyWebSocketStore(directory: directory, readOnly: true)
        defer { store.close() }
        return try store.window(url: url, kind: kind, around: row)
    }
    public func detail(directory: URL, id: Int64, metadata: Bool, format: NetworkBodyFormat, page: Int) throws -> ProxyWebSocketDetail {
        let store = try ProxyWebSocketStore(directory: directory, readOnly: true)
        defer { store.close() }
        guard let event = try store.event(id) else { throw RunbarError.message("该 WebSocket 事件已不存在。") }
        var bytes: Data
        var note = event.note
        if metadata || event.kind == .open || event.kind == .close {
            let headers = try store.handshake(event.flowID)
            func header(_ value: String) -> Any {
                (try? JSONSerialization.jsonObject(with: Data(value.utf8))) ?? value
            }
            var info: [String: Any] = ["连接": event.url, "连接 ID": event.flowID, "事件": event.kind.title,
                "时间": event.date.formatted(.iso8601), "原始字节数": event.bytes, "说明": event.note,
                "请求头": header(headers.0), "响应头": header(headers.1)]
            if let code = event.closeCode { info["关闭码"] = code }
            if let closed = try store.closure(event.flowID) {
                info["连接状态"] = "已记录关闭"; info["关闭时间"] = closed.date.formatted(.iso8601)
                info["关闭原因"] = closed.reason
                if let code = closed.code { info["关闭码"] = code }
            } else { info["连接状态"] = "未采集到关闭事件" }
            bytes = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        } else if event.opcode == 2 {
            bytes = Data(event.payload.base64EncodedString().utf8)
            note = "二进制消息按 Base64 显示；不解析业务协议。 " + note
        } else { bytes = event.payload }
        if !metadata && event.opcode != 2 && !bytes.isEmpty {
            do { bytes = try NetworkBodyFormatter.format(bytes, as: format) }
            catch { note += " " + error.localizedDescription + " 当前显示原始内容。" }
        }
        let result = NetworkBodyFormatter.page(bytes, page: page, chunk: 32 * 1024)
        return ProxyWebSocketDetail(text: result.text, page: result.page, pages: result.pages, note: note)
    }
}
