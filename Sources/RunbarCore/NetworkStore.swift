import Foundation
import CSQLite

/// Owned by a background actor. A page never materializes the full request
/// history, and bounded payload files do not live in SQLite's page cache.
public final class NetworkStore {
    public let directory: URL
    private var db: OpaquePointer?
    private let limits: NetworkLimits
    private let readOnly: Bool
    private let access: NetworkCacheAccess
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(directory: URL, readOnly: Bool = false, limits: NetworkLimits = NetworkLimits()) throws {
        self.directory = directory; self.limits = limits; self.readOnly = readOnly
        self.access = NetworkCacheAccess.shared(for: directory)
        try acquireAccess(); defer { access.release() }
        let file = directory.appendingPathComponent("requests.sqlite")
        if !readOnly { try FileManager.default.createDirectory(at: directory.appendingPathComponent("bodies"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let opened = sqlite3_open_v2(file.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK else {
            let error = storageError(operation: "打开网络缓存", fallbackCode: opened)
            if let db { sqlite3_close_v2(db) }; db = nil; throw error
        }
        do {
            sqlite3_extended_result_codes(db, 1)
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
                try installSearchRevision()
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
    public func close() {
        access.acquireForClose(); defer { access.release() }
        if let db { sqlite3_close_v2(db) }; db = nil
    }
    deinit { close() }
    private func acquireAccess() throws {
        do { try access.acquire() }
        catch let error as NetworkStorageError {
            if !readOnly { error.saveDiagnostic(in: directory) }
            throw error
        }
    }
    private func execute(_ sql: String) throws {
        let operation = sql == "COMMIT" ? "提交缓存事务" : sql.hasPrefix("BEGIN") ? "开始缓存事务" : "执行缓存语句"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw storageError(operation: operation) }
    }
    private func rollback() {
        // SQLITE_FULL and some I/O errors already roll back automatically. Do
        // not overwrite their diagnostic with "no transaction is active".
        guard sqlite3_get_autocommit(db) == 0 else { return }
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
    }
    private func hasSearchRevision() throws -> Bool {
        try number("SELECT count(*) FROM pragma_table_info('requests') WHERE name='search_revision'") == 1
    }
    private func installSearchRevision() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if try !hasSearchRevision() { try execute("ALTER TABLE requests ADD COLUMN search_revision INTEGER NOT NULL DEFAULT 0") }
            try execute("""
                INSERT OR IGNORE INTO cache_info VALUES ('search_revision',0);
                CREATE INDEX IF NOT EXISTS requests_search_revision ON requests(search_revision);
                CREATE TRIGGER IF NOT EXISTS requests_search_insert AFTER INSERT ON requests BEGIN
                    UPDATE cache_info SET value=value+1 WHERE key='search_revision';
                    UPDATE requests SET search_revision=(SELECT value FROM cache_info WHERE key='search_revision') WHERE id=NEW.id;
                END;
                CREATE TRIGGER IF NOT EXISTS requests_search_update AFTER UPDATE OF metadata,body_state,body_note ON requests
                WHEN OLD.metadata IS NOT NEW.metadata OR OLD.body_state IS NOT NEW.body_state OR OLD.body_note IS NOT NEW.body_note BEGIN
                    UPDATE cache_info SET value=value+1 WHERE key='search_revision';
                    UPDATE requests SET search_revision=(SELECT value FROM cache_info WHERE key='search_revision') WHERE id=NEW.id;
                END;
                """)
            try execute("COMMIT")
        } catch { rollback(); throw error }
    }
    private func storageError(operation: String = "读写网络缓存", fallbackCode: Int32 = SQLITE_MISUSE) -> NetworkStorageError {
        let extended = db.map { sqlite3_extended_errcode($0) } ?? fallbackCode
        let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "缓存连接不可用"
        let error = NetworkStorageError(code: extended & 0xff, extendedCode: extended, operation: operation, detail: detail)
        if !readOnly { error.saveDiagnostic(in: directory) }
        return error
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
        try acquireAccess(); defer { access.release() }
        guard !readOnly, records.count <= limits.batchRequests else { throw RunbarError.message("单批网络请求过多，已暂停接收。") }
        try execute("BEGIN IMMEDIATE")
        do {
            var count = try number("SELECT count(*) FROM requests")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            for record in records {
                try Task.checkCancellation()
                let exists = try number("SELECT count(*) FROM requests WHERE id=?", [record.id]) > 0
                guard exists || count < limits.requests else { throw RunbarError.message("网络记录已达到 \(limits.requests) 条，已暂停接收。") }
                let metadata = try encoder.encode(record)
                guard metadata.count <= 96 * 1024 else { throw RunbarError.message("单条网络摘要过大，已暂停接收。") }
                let stmt = try statement("""
                    INSERT INTO requests(id,epoch,isolate,request_id,started,ended,method,url,status,failed,metadata)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                    started=excluded.started,method=excluded.method,url=excluded.url,
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
        } catch { rollback(); throw error }
    }
    private func record(_ stmt: OpaquePointer) throws -> NetworkRecord {
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard count > 0, count <= 96 * 1024, let pointer = sqlite3_column_blob(stmt, 0) else {
            throw RunbarError.message("网络缓存记录格式异常，原文件已保留。")
        }
        let data = Data(bytes: pointer, count: count)
        var record = try JSONDecoder().decode(NetworkRecord.self, from: data)
        record.bodyState = NetworkBodyState(rawValue: text(stmt, 1)) ?? .unavailable
        record.bodyNote = text(stmt, 2); return record
    }
    private func predicate(for query: NetworkQuery) throws -> (String, [String]) {
        guard !query.needsContentSearch else { throw RunbarError.message("正文筛选需要通过后台网络查询器读取。") }
        var clauses = ["1=1"], values: [String] = []
        for excluding in [false, true] {
            let join = excluding ? " OR " : query.keywordMode.sqlJoin
            let urls = query.effectiveKeywords(in: .url, excluding: excluding)
            let headers = query.effectiveKeywords(in: .headers, excluding: excluding)
            if !urls.isEmpty {
                clauses.append((excluding ? "NOT " : "") + "(" + urls.map { _ in "instr(lower(url),lower(?))>0" }.joined(separator: join) + ")")
                values += urls
            }
            if !headers.isEmpty {
                let clause = "(instr(lower(coalesce(json_extract(CAST(metadata AS TEXT),'$.requestHeaders'),'')),lower(?))>0 OR instr(lower(coalesce(json_extract(CAST(metadata AS TEXT),'$.responseHeaders'),'')),lower(?))>0)"
                clauses.append((excluding ? "NOT " : "") + "(" + headers.map { _ in clause }.joined(separator: join) + ")")
                for word in headers { values += [word, word] }
            }
        }
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
        return (clauses.joined(separator: " AND "), values)
    }
    public func page(query: NetworkQuery = NetworkQuery(), page: Int = 0, latest: Bool = false) throws -> NetworkPage {
        try acquireAccess(); defer { access.release() }
        let (predicate, values) = try predicate(for: query)
        let total = try number("SELECT count(*) FROM requests")
        let matching = try number("SELECT count(*) FROM requests WHERE " + predicate, values)
        let lastPage = max(0, (matching - 1) / NetworkPage.pageSize)
        let page = latest ? lastPage : min(max(0, page), lastPage)
        let stmt = try statement("SELECT metadata,body_state,body_note FROM requests WHERE \(predicate) ORDER BY started ASC,id ASC LIMIT \(NetworkPage.pageSize) OFFSET \(page * NetworkPage.pageSize)", values)
        defer { sqlite3_finalize(stmt) }
        var records: [NetworkRecord] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW { records.append(try record(stmt)); step = sqlite3_step(stmt) }
        guard step == SQLITE_DONE else { throw storageError() }
        return NetworkPage(records: records, total: total, matching: matching, page: page)
    }
    public func listCounts(query: NetworkQuery) throws -> NetworkListCounts {
        try acquireAccess(); defer { access.release() }
        let (predicate, values) = try predicate(for: query)
        try Task.checkCancellation()
        let total = try number("SELECT count(*) FROM requests")
        let matching = values.isEmpty && query.status == .all ? total : try number("SELECT count(*) FROM requests WHERE " + predicate, values)
        return NetworkListCounts(total: total, matching: matching)
    }
    public func listWindow(query: NetworkQuery = NetworkQuery(), around row: Int, counts: NetworkListCounts? = nil) throws -> NetworkListWindow {
        try acquireAccess(); defer { access.release() }
        let counts = try counts ?? listCounts(query: query)
        let anchor = min(max(0, row), max(0, counts.matching - 1))
        let offset = min(max(0, anchor - NetworkListWindow.capacity / 2), max(0, counts.matching - NetworkListWindow.capacity))
        let (predicate, values) = try predicate(for: query)
        // This is the reverse of requests_started(started DESC,id ASC), so the
        // old database index also supports chronological virtual access. Equal
        // timestamps use a stable ID order across windows and point selection.
        let stmt = try statement("""
            SELECT id,method,url,started,ended,status,failed,json_extract(CAST(metadata AS TEXT),'$.timingVersion')
            FROM requests WHERE \(predicate) ORDER BY started ASC,id DESC LIMIT \(NetworkListWindow.capacity) OFFSET \(offset)
            """, values)
        defer { sqlite3_finalize(stmt) }
        var rows: [NetworkRequestSummary] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            try Task.checkCancellation()
            let start = sqlite3_column_int64(stmt, 3)
            let duration = sqlite3_column_int(stmt, 7) == 2 && sqlite3_column_type(stmt, 4) != SQLITE_NULL
                ? Double(max(0, sqlite3_column_int64(stmt, 4) - start)) / 1000 : nil
            rows.append(NetworkRequestSummary(id: text(stmt, 0), method: text(stmt, 1), url: text(stmt, 2), startMicros: start,
                status: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5)),
                failed: sqlite3_column_int(stmt, 6) != 0, durationMS: duration))
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw storageError() }
        return NetworkListWindow(counts: counts, offset: offset, rows: rows)
    }
    public func request(query: NetworkQuery, row: Int) throws -> NetworkRecord? {
        try acquireAccess(); defer { access.release() }
        guard row >= 0 else { return nil }
        let (predicate, values) = try predicate(for: query)
        let stmt = try statement("SELECT metadata,body_state,body_note FROM requests WHERE \(predicate) ORDER BY started ASC,id DESC LIMIT 1 OFFSET \(row)", values)
        defer { sqlite3_finalize(stmt) }
        try Task.checkCancellation()
        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw storageError() }; return try record(stmt)
    }
    public func pendingBodies(epoch: String, isolate: String) throws -> [NetworkRecord] {
        try acquireAccess(); defer { access.release() }
        let stmt = try statement("SELECT metadata,body_state,body_note FROM requests WHERE epoch=? AND isolate=? AND body_state='pending' AND (ended IS NOT NULL OR failed=1) ORDER BY started LIMIT \(limits.bodiesPerPoll)", [epoch, isolate])
        defer { sqlite3_finalize(stmt) }
        var result: [NetworkRecord] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW { result.append(try record(stmt)); step = sqlite3_step(stmt) }
        guard step == SQLITE_DONE else { throw storageError() }; return result
    }
    public func request(_ id: String) throws -> NetworkRecord? {
        try acquireAccess(); defer { access.release() }
        let stmt = try statement("SELECT metadata,body_state,body_note FROM requests WHERE id=?", [id])
        defer { sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw storageError() }
        return try record(stmt)
    }
    public func pendingBodyCount(epoch: String) throws -> Int {
        try acquireAccess(); defer { access.release() }
        return try number("SELECT count(*) FROM requests WHERE epoch=? AND body_state='pending' AND (ended IS NOT NULL OR failed=1)", [epoch])
    }
    public func inProgressBodies(epoch: String, isolate: String, after: String) throws -> [NetworkRecord] {
        try acquireAccess(); defer { access.release() }
        let stmt = try statement("SELECT metadata,body_state,body_note FROM requests WHERE epoch=? AND isolate=? AND body_state='pending' AND ended IS NULL AND failed=0 AND id>? ORDER BY id LIMIT \(limits.bodiesPerPoll)", [epoch, isolate, after])
        defer { sqlite3_finalize(stmt) }
        var records: [NetworkRecord] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW { records.append(try record(stmt)); step = sqlite3_step(stmt) }
        guard step == SQLITE_DONE else { throw storageError() }; return records
    }
    public func finalizePending(epoch: String, isolate: String, note: String) throws {
        try acquireAccess(); defer { access.release() }
        let stmt = try statement("UPDATE requests SET body_state='unavailable',body_note=? WHERE epoch=? AND isolate=? AND body_state='pending'", [note, epoch, isolate])
        defer { sqlite3_finalize(stmt) }; guard sqlite3_step(stmt) == SQLITE_DONE else { throw storageError() }
    }
    public func markBody(_ id: String, state: NetworkBodyState, note: String = "") throws {
        try acquireAccess(); defer { access.release() }
        let stmt = try statement("UPDATE requests SET body_state=?,body_note=? WHERE id=?", [state.rawValue, note, id])
        defer { sqlite3_finalize(stmt) }; guard sqlite3_step(stmt) == SQLITE_DONE else { throw storageError() }
    }
    public func finalizePending(note: String = "采集已断开，正文未缓存") throws {
        try acquireAccess(); defer { access.release() }
        let stmt = try statement("UPDATE requests SET body_state='unavailable',body_note=? WHERE body_state='pending'", [note])
        defer { sqlite3_finalize(stmt) }; guard sqlite3_step(stmt) == SQLITE_DONE else { throw storageError() }
    }
    public func saveBodies(_ id: String, request: Data, response: Data) throws {
        try acquireAccess(); defer { access.release() }
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { throw RunbarError.message("网络请求身份无效。") }
        let state = try statement("SELECT body_state FROM requests WHERE id=?", [id])
        let step = sqlite3_step(state)
        guard step == SQLITE_ROW || step == SQLITE_DONE else {
            let error = storageError(operation: "读取正文缓存状态")
            sqlite3_finalize(state); throw error
        }
        let exists = step == SQLITE_ROW
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
            rollback(); try? FileManager.default.removeItem(at: requestURL); try? FileManager.default.removeItem(at: responseURL)
            if error is NetworkStorageError || error is CancellationError { throw error }
            throw RunbarError.message("网络正文文件保存失败：\(error.localizedDescription)")
        }
    }
    private func bodyURL(_ id: String, response: Bool) -> URL {
        directory.appendingPathComponent("bodies/\(id).\(response ? "response" : "request")")
    }
    public func bodyPage(_ record: NetworkRecord, response: Bool, page: Int, format: NetworkBodyFormat = .raw) throws -> NetworkBodyPage {
        guard record.bodyState == .saved, record.id.count == 64, record.id.allSatisfy({ $0.isHexDigit }) else {
            let pending = record.isComplete ? "正文正在排队缓存，选中后会优先加载。" : "响应尚未接收完成，完成后将缓存正文。"
            return NetworkBodyPage(text: record.bodyNote.isEmpty ? (record.bodyState == .pending ? pending : record.bodyState.title) : record.bodyNote, page: 0, pages: 1, bytes: 0)
        }
        let handle = try FileHandle(forReadingFrom: bodyURL(record.id, response: response)); defer { try? handle.close() }
        let bytes = Int(try handle.seekToEnd()), chunk = 128 * 1024
        if bytes == 0 { return NetworkBodyPage(text: "", page: 0, pages: 1, bytes: 0) }
        if format != .raw {
            guard bytes <= NetworkBodyFormatter.inputLimit else { throw RunbarError.message("正文超过 1 MB，无法格式化。") }
            try handle.seek(toOffset: 0)
            let raw = try handle.read(upToCount: NetworkBodyFormatter.inputLimit + 1) ?? Data()
            let formatted = try NetworkBodyFormatter.format(raw, as: format)
            let display = NetworkBodyFormatter.page(formatted, page: page, chunk: chunk)
            return NetworkBodyPage(text: display.text, page: display.page, pages: display.pages, bytes: bytes)
        }
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

    func searchSnapshot() throws -> NetworkSearchSnapshot {
        try acquireAccess(); defer { access.release() }
        let versioned = try hasSearchRevision()
        let revision = versioned ? Int64(try number("SELECT value FROM cache_info WHERE key='search_revision'")) : nil
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("requests.sqlite").path)
        return NetworkSearchSnapshot(total: try number("SELECT count(*) FROM requests"),
                                     lastRow: Int64(try number("SELECT coalesce(max(rowid),0) FROM requests")), revision: revision,
                                     modified: (attributes[.modificationDate] as? Date) ?? .distantPast)
    }
    func searchCandidates(query: NetworkQuery, afterRow: Int64, throughRow: Int64,
                          afterRevision: Int64? = nil, throughRevision: Int64 = 0) throws -> [NetworkSearchCandidate] {
        try acquireAccess(); defer { access.release() }
        // Changed rows must be seen even when they have stopped matching the
        // metadata conditions, so their old match can be removed from the index.
        // Text conditions are evaluated outside this lock too: a rare header
        // match must not turn one batch into a full JSON scan under the gate.
        var base = NetworkQuery(); base.method = query.method; base.status = query.status
        let (predicate, values) = afterRevision == nil ? try predicate(for: base) : ("1=1", [])
        let revision = try hasSearchRevision() ? "search_revision" : "0"
        let range = afterRevision.map { "search_revision>\($0) AND search_revision<=\(throughRevision)" } ?? "rowid>\(afterRow) AND rowid<=\(throughRow)"
        let order = afterRevision == nil ? "rowid" : "search_revision,rowid"
        let stmt = try statement("SELECT metadata,body_state,body_note,rowid,\(revision),id FROM requests WHERE (\(predicate)) AND \(range) ORDER BY \(order) LIMIT 24", values)
        defer { sqlite3_finalize(stmt) }
        var result: [NetworkSearchCandidate] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            try Task.checkCancellation()
            let record = try autoreleasepool { try self.record(stmt) }
            guard record.id == text(stmt, 5), record.id.count == 64, record.id.allSatisfy(\.isHexDigit) else { throw RunbarError.message("网络缓存记录标识异常。") }
            result.append(NetworkSearchCandidate(record: record, row: sqlite3_column_int64(stmt, 3), revision: sqlite3_column_int64(stmt, 4)))
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw storageError() }
        return result
    }
    func summaries(ids: [String]) throws -> [NetworkRequestSummary] {
        try acquireAccess(); defer { access.release() }
        guard !ids.isEmpty else { return [] }
        guard ids.count <= NetworkListWindow.capacity else { throw RunbarError.message("网络摘要窗口过大。") }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let stmt = try statement("SELECT id,method,url,started,ended,status,failed,json_extract(CAST(metadata AS TEXT),'$.timingVersion') FROM requests WHERE id IN (\(placeholders))", ids)
        defer { sqlite3_finalize(stmt) }
        var result: [String: NetworkRequestSummary] = [:]
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            try Task.checkCancellation()
            let start = sqlite3_column_int64(stmt, 3)
            let duration = sqlite3_column_int(stmt, 7) == 2 && sqlite3_column_type(stmt, 4) != SQLITE_NULL ? Double(max(0, sqlite3_column_int64(stmt, 4) - start)) / 1000 : nil
            let item = NetworkRequestSummary(id: text(stmt, 0), method: text(stmt, 1), url: text(stmt, 2), startMicros: start,
                                             status: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5)),
                                             failed: sqlite3_column_int(stmt, 6) != 0, durationMS: duration)
            result[item.id] = item; step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw storageError() }
        return ids.compactMap { result[$0] }
    }
}

public actor NetworkCacheReader {
    private var countsCache: (URL, NetworkQuery, NetworkListCounts)?
    private var contentIndex: NetworkContentIndex?
    public init() {}
    private func read<Value>(directory: URL, operation: (NetworkStore) throws -> Value) async throws -> Value {
        var failures = 0
        while true {
            do {
                try Task.checkCancellation()
                let store = try NetworkStore(directory: directory, readOnly: true); defer { store.close() }
                let value = try operation(store)
                try Task.checkCancellation()
                return value
            } catch {
                failures += 1
                guard let delay = NetworkStorageRetry.delay(for: error, failure: failures) else { throw error }
                // No SQLite connection, cursor or cache-access lock survives
                // this suspension. A writer can finish before the next retry.
                try await Task.sleep(for: delay)
            }
        }
    }
    public func listWindow(directory: URL, query: NetworkQuery, around row: Int, refreshCounts: Bool = true) async throws -> NetworkListWindow {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("requests.sqlite").path) else {
            countsCache = nil; cancelContentSearch(directory: directory); return .empty
        }
        try Task.checkCancellation()
        if query.needsContentSearch {
            let index = try await indexed(directory: directory, query: query)
            let (counts, offset, ids) = try index.window(around: row)
            let rows = try await read(directory: directory) { try $0.summaries(ids: ids) }
            return NetworkListWindow(counts: counts, offset: offset, rows: rows)
        }
        cancelContentSearch()
        let counts: NetworkListCounts?
        if !refreshCounts, let cached = countsCache, cached.0 == directory, cached.1 == query { counts = cached.2 }
        else { counts = nil }
        let window = try await read(directory: directory) { try $0.listWindow(query: query, around: row, counts: counts) }
        countsCache = (directory, query, window.counts)
        return window
    }
    public func request(directory: URL, query: NetworkQuery, row: Int) async throws -> NetworkRecord? {
        guard row >= 0 else { return nil }
        if query.needsContentSearch {
            let index = try await indexed(directory: directory, query: query)
            guard let id = try index.ids(offset: row, limit: 1).first else { return nil }
            return try await read(directory: directory) { try $0.request(id) }
        }
        return try await read(directory: directory) { try $0.request(query: query, row: row) }
    }
    public func page(directory: URL, query: NetworkQuery, page: Int, latest: Bool = false) async throws -> NetworkPage {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("requests.sqlite").path) else { return .empty }
        if query.needsContentSearch {
            var index = try await indexed(directory: directory, query: query)
            while !index.isComplete {
                try Task.checkCancellation(); await Task.yield()
                index = try await indexed(directory: directory, query: query)
            }
            let count = try index.count(), last = max(0, (count - 1) / NetworkPage.pageSize)
            let current = latest ? last : min(max(0, page), last)
            let ids = try index.ids(offset: current * NetworkPage.pageSize, limit: NetworkPage.pageSize)
            let records = try await read(directory: directory) { store in try ids.compactMap { try store.request($0) } }
            return NetworkPage(records: records, total: index.sourceTotal, matching: count, page: current)
        }
        return try await read(directory: directory) { try $0.page(query: query, page: page, latest: latest) }
    }
    public func request(directory: URL, id: String) async throws -> NetworkRecord? {
        try await read(directory: directory) { try $0.request(id) }
    }
    public func body(directory: URL, record: NetworkRecord, response: Bool, page: Int, format: NetworkBodyFormat = .raw) async throws -> NetworkBodyPage {
        try await read(directory: directory) { try $0.bodyPage(record, response: response, page: page, format: format) }
    }
    public func metadata(record: NetworkRecord, section: NetworkDetailSection, format: NetworkBodyFormat, page: Int) throws -> NetworkBodyPage {
        try NetworkDetailPresentation.page(record: record, section: section, format: format, page: page)
    }
    public func cancelContentSearch(directory: URL? = nil) {
        guard directory == nil || contentIndex?.directory == directory else { return }
        contentIndex?.worker?.cancel(); contentIndex = nil
    }
    private func indexed(directory: URL, query: NetworkQuery) async throws -> NetworkContentIndex {
        try Task.checkCancellation()
        let index: NetworkContentIndex
        if let current = contentIndex, current.directory == directory, current.query == query.bounded { index = current }
        else {
            cancelContentSearch()
            index = try NetworkContentIndex(directory: directory, query: query); contentIndex = index
        }
        if index.worker == nil {
            index.worker = Task { [weak self, weak index] in
                guard let self, let index else { throw CancellationError() }
                defer { index.worker = nil }
                try await self.scanSlice(index)
            }
        }
        if let worker = index.worker { try await worker.value }
        try Task.checkCancellation()
        guard contentIndex === index else { throw CancellationError() }
        return index
    }
    private func scanSlice(_ index: NetworkContentIndex) async throws {
        let source = try await read(directory: index.directory) { try $0.searchSnapshot() }
        try Task.checkCancellation()
        guard contentIndex === index else { throw CancellationError() }
        try index.prepare(source)
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .milliseconds(120))
        while !index.isComplete {
            try Task.checkCancellation()
            let initial = !index.initialDone, row = index.lastRow, revision = index.lastRevision
            let candidates = try await read(directory: index.directory) {
                try $0.searchCandidates(query: index.query, afterRow: row, throughRow: index.baselineRow,
                                        afterRevision: initial ? nil : revision, throughRevision: index.targetRevision)
            }
            try Task.checkCancellation()
            guard contentIndex === index else { throw CancellationError() }
            if candidates.isEmpty { index.finishPass() }
            else {
                var results: [(NetworkSearchCandidate, Bool)] = []
                for candidate in candidates {
                    try Task.checkCancellation()
                    let matches = try autoreleasepool { try index.matcher.matches(candidate.record, directory: index.directory) }
                    results.append((candidate, matches))
                    if clock.now >= deadline { break }
                }
                try index.apply(results)
            }
            if clock.now >= deadline { break }
            await Task.yield()
        }
    }
}
