import Foundation
import CSQLite

/// Owned by a background actor. A page never materializes the full request
/// history, and bounded payload files do not live in SQLite's page cache.
public final class NetworkStore {
    public let directory: URL
    private var db: OpaquePointer?
    private let limits: NetworkLimits
    private let readOnly: Bool
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(directory: URL, readOnly: Bool = false, limits: NetworkLimits = NetworkLimits()) throws {
        self.directory = directory; self.limits = limits; self.readOnly = readOnly
        let file = directory.appendingPathComponent("requests.sqlite")
        if !readOnly { try FileManager.default.createDirectory(at: directory.appendingPathComponent("bodies"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(file.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil; throw RunbarError.message("无法打开网络缓存。")
        }
        do {
            sqlite3_busy_timeout(db, 1000)
            try execute("PRAGMA cache_size=-1024")
            if !readOnly {
                try execute("PRAGMA page_size=4096; PRAGMA journal_mode=DELETE; PRAGMA max_page_count=\(max(32, limits.databasePages));")
                try execute("""
                    CREATE TABLE IF NOT EXISTS requests (
                    id TEXT PRIMARY KEY, epoch TEXT NOT NULL, isolate TEXT NOT NULL, request_id TEXT NOT NULL,
                    started INTEGER NOT NULL, ended INTEGER, method TEXT NOT NULL, url TEXT NOT NULL,
                    status INTEGER, failed INTEGER NOT NULL, metadata BLOB NOT NULL,
                    body_state TEXT NOT NULL DEFAULT 'pending', body_note TEXT NOT NULL DEFAULT '');
                    CREATE INDEX IF NOT EXISTS requests_started ON requests(started DESC,id);
                    CREATE INDEX IF NOT EXISTS requests_pending ON requests(epoch,isolate,body_state,ended);
                    CREATE TABLE IF NOT EXISTS cache_info (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
                    INSERT OR IGNORE INTO cache_info VALUES ('body_bytes',0);
                    """)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                // Recover an interrupted body save. No partial file is labelled saved.
                try execute("UPDATE requests SET body_state='unavailable',body_note='上次采集已断开，正文未缓存' WHERE body_state='pending'")
                // Account for payloads written just before a prior crash, too.
                let enumerator = FileManager.default.enumerator(at: directory.appendingPathComponent("bodies"), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
                var bytes = 0
                while let url = enumerator?.nextObject() as? URL {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
                }
                try execute("UPDATE cache_info SET value=\(bytes) WHERE key='body_bytes'")
            }
        } catch { close(); throw error }
    }
    public func close() { if let db { sqlite3_close(db) }; db = nil }
    deinit { close() }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw storageError() }
    }
    private func storageError() -> RunbarError {
        RunbarError.message(sqlite3_errcode(db) == SQLITE_FULL ? "网络摘要缓存已达容量上限，已暂停接收。" : "网络缓存读写失败，请检查磁盘空间与权限。")
    }
    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw storageError() }
        for (i, value) in values.enumerated() { sqlite3_bind_text(result, Int32(i + 1), value, -1, transient) }
        return result
    }
    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    private func number(_ sql: String, _ values: [String] = []) throws -> Int {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw storageError() }
        return Int(sqlite3_column_int64(stmt, 0))
    }
    public func upsert(_ records: [NetworkRecord]) throws {
        guard !readOnly, records.count <= limits.batchRequests else { throw RunbarError.message("单批网络请求过多，已暂停接收。") }
        try execute("BEGIN IMMEDIATE")
        do {
            var count = try number("SELECT count(*) FROM requests")
            for record in records {
                try Task.checkCancellation()
                let exists = try number("SELECT count(*) FROM requests WHERE id=?", [record.id]) > 0
                guard exists || count < limits.requests else { throw RunbarError.message("网络记录已达到 \(limits.requests) 条，已暂停接收。") }
                let metadata = try JSONEncoder().encode(record)
                guard metadata.count <= 96 * 1024 else { throw RunbarError.message("单条网络摘要过大，已暂停接收。") }
                let stmt = try statement("""
                    INSERT INTO requests(id,epoch,isolate,request_id,started,ended,method,url,status,failed,metadata)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                    ended=excluded.ended,status=excluded.status,failed=excluded.failed,metadata=excluded.metadata
                    """)
                defer { sqlite3_finalize(stmt) }
                for (index, value) in [record.id, record.epoch, record.isolateID, record.requestID].enumerated() {
                    sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient)
                }
                sqlite3_bind_int64(stmt, 5, record.startMicros)
                if let end = record.endMicros { sqlite3_bind_int64(stmt, 6, end) }
                sqlite3_bind_text(stmt, 7, record.method, -1, transient); sqlite3_bind_text(stmt, 8, record.url, -1, transient)
                if let status = record.status { sqlite3_bind_int(stmt, 9, Int32(clamping: status)) }
                sqlite3_bind_int(stmt, 10, record.failure == nil ? 0 : 1)
                _ = metadata.withUnsafeBytes { sqlite3_bind_blob(stmt, 11, $0.baseAddress, Int32(metadata.count), transient) }
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw storageError() }
                if !exists { count += 1 }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func record(_ stmt: OpaquePointer) throws -> NetworkRecord {
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard count > 0, count <= 96 * 1024, let pointer = sqlite3_column_blob(stmt, 0) else { throw storageError() }
        let data = Data(bytes: pointer, count: count)
        var record = try JSONDecoder().decode(NetworkRecord.self, from: data)
        record.bodyState = NetworkBodyState(rawValue: text(stmt, 1)) ?? .unavailable
        record.bodyNote = text(stmt, 2); return record
    }
    public func page(query: NetworkQuery = NetworkQuery(), page: Int = 0) throws -> NetworkPage {
        var clauses = ["1=1"], values: [String] = []
        if !query.text.isEmpty { clauses.append("instr(lower(url),lower(?))>0"); values.append(String(query.text.prefix(1024))) }
        if !query.method.isEmpty { clauses.append("method=?"); values.append(query.method) }
        switch query.status {
        case .all: break
        case .pending: clauses.append("ended IS NULL AND failed=0")
        case .success: clauses.append("status BETWEEN 200 AND 299")
        case .redirect: clauses.append("status BETWEEN 300 AND 399")
        case .clientError: clauses.append("status BETWEEN 400 AND 499")
        case .serverError: clauses.append("status BETWEEN 500 AND 599")
        case .failed: clauses.append("failed=1")
        }
        let predicate = clauses.joined(separator: " AND ")
        let total = try number("SELECT count(*) FROM requests")
        let matching = try number("SELECT count(*) FROM requests WHERE " + predicate, values)
        let page = min(max(0, page), max(0, (matching - 1) / NetworkPage.pageSize))
        let stmt = try statement("SELECT metadata,body_state,body_note FROM requests WHERE \(predicate) ORDER BY started DESC,id LIMIT \(NetworkPage.pageSize) OFFSET \(page * NetworkPage.pageSize)", values)
        defer { sqlite3_finalize(stmt) }
        var records: [NetworkRecord] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW { records.append(try record(stmt)); step = sqlite3_step(stmt) }
        guard step == SQLITE_DONE else { throw storageError() }
        return NetworkPage(records: records, total: total, matching: matching, page: page)
    }
    public func pendingBodies(epoch: String, isolate: String) throws -> [NetworkRecord] {
        let stmt = try statement("SELECT metadata,body_state,body_note FROM requests WHERE epoch=? AND isolate=? AND body_state='pending' AND (ended IS NOT NULL OR failed=1) ORDER BY started LIMIT \(limits.bodiesPerPoll)", [epoch, isolate])
        defer { sqlite3_finalize(stmt) }
        var result: [NetworkRecord] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW { result.append(try record(stmt)); step = sqlite3_step(stmt) }
        guard step == SQLITE_DONE else { throw storageError() }; return result
    }
    public func markBody(_ id: String, state: NetworkBodyState, note: String = "") throws {
        let stmt = try statement("UPDATE requests SET body_state=?,body_note=? WHERE id=?", [state.rawValue, note, id])
        defer { sqlite3_finalize(stmt) }; guard sqlite3_step(stmt) == SQLITE_DONE else { throw storageError() }
    }
    public func finalizePending(note: String = "采集已断开，正文未缓存") throws {
        let stmt = try statement("UPDATE requests SET body_state='unavailable',body_note=? WHERE body_state='pending'", [note])
        defer { sqlite3_finalize(stmt) }; guard sqlite3_step(stmt) == SQLITE_DONE else { throw storageError() }
    }
    public func saveBodies(_ id: String, request: Data, response: Data) throws {
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { throw RunbarError.message("网络请求身份无效。") }
        let state = try statement("SELECT body_state FROM requests WHERE id=?", [id])
        let exists = sqlite3_step(state) == SQLITE_ROW
        let saved = exists && text(state, 0) == NetworkBodyState.saved.rawValue
        sqlite3_finalize(state)
        guard exists else { throw RunbarError.message("网络请求已不存在。") }
        if saved { return }
        guard request.count <= limits.bodyBytes, response.count <= limits.bodyBytes else {
            try markBody(id, state: .omitted, note: "请求或响应正文超过 1 MB 限制"); return
        }
        let used = try number("SELECT value FROM cache_info WHERE key='body_bytes'")
        let added = request.count + response.count
        guard used + added <= limits.bodyBudget else {
            try markBody(id, state: .omitted, note: "本次运行的正文缓存已达容量上限"); return
        }
        let requestURL = bodyURL(id, response: false), responseURL = bodyURL(id, response: true)
        do {
            try request.write(to: requestURL, options: .atomic)
            try response.write(to: responseURL, options: .atomic)
            for url in [requestURL, responseURL] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            try execute("BEGIN IMMEDIATE")
            try markBody(id, state: .saved)
            let stmt = try statement("UPDATE cache_info SET value=value+? WHERE key='body_bytes'", [String(added)])
            defer { sqlite3_finalize(stmt) }; guard sqlite3_step(stmt) == SQLITE_DONE else { throw storageError() }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK"); try? FileManager.default.removeItem(at: requestURL); try? FileManager.default.removeItem(at: responseURL)
            throw error
        }
    }
    private func bodyURL(_ id: String, response: Bool) -> URL {
        directory.appendingPathComponent("bodies/\(id).\(response ? "response" : "request")")
    }
    public func bodyPage(_ record: NetworkRecord, response: Bool, page: Int) throws -> NetworkBodyPage {
        guard record.bodyState == .saved, record.id.count == 64, record.id.allSatisfy({ $0.isHexDigit }) else {
            return NetworkBodyPage(text: record.bodyNote.isEmpty ? record.bodyState.title : record.bodyNote, page: 0, pages: 1, bytes: 0)
        }
        let handle = try FileHandle(forReadingFrom: bodyURL(record.id, response: response)); defer { try? handle.close() }
        let bytes = Int(try handle.seekToEnd()), chunk = 128 * 1024
        let pages = max(1, (bytes + chunk - 1) / chunk), page = min(max(0, page), pages - 1)
        let offset = page * chunk, start = max(0, offset - 3)
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.read(upToCount: min(chunk + 6, bytes - start)) ?? Data()
        var lower = offset - start, upper = min(data.count, offset - start + chunk)
        while lower > 0 && lower < data.count && data[lower] & 0xC0 == 0x80 { lower -= 1 }
        while upper < data.count && data[upper] & 0xC0 == 0x80 { upper += 1 }
        let slice = Data(data[lower..<upper])
        let text: String
        if let string = String(data: slice, encoding: .utf8), !slice.contains(0) { text = string.isEmpty ? "（正文为空）" : string }
        else { text = "二进制内容，显示本页前 4096 字节的十六进制：\n" + slice.prefix(4096).map { String(format: "%02x", $0) }.joined(separator: " ") }
        return NetworkBodyPage(text: text, page: page, pages: pages, bytes: bytes)
    }
}

public actor NetworkCacheReader {
    public init() {}
    public func page(directory: URL, query: NetworkQuery, page: Int) throws -> NetworkPage {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("requests.sqlite").path) else { return .empty }
        let store = try NetworkStore(directory: directory, readOnly: true); defer { store.close() }
        return try store.page(query: query, page: page)
    }
    public func body(directory: URL, record: NetworkRecord, response: Bool, page: Int) throws -> NetworkBodyPage {
        let store = try NetworkStore(directory: directory, readOnly: true); defer { store.close() }
        return try store.bodyPage(record, response: response, page: page)
    }
}
