import Foundation
import CSQLite

/// Payloads stay on disk. List queries explicitly avoid the payload / header columns.
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
            if !readOnly {
                try execute("PRAGMA journal_mode=WAL")
                try execute("PRAGMA wal_autocheckpoint=256")
                try execute("CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, flow_id TEXT NOT NULL, url TEXT NOT NULL, timestamp INTEGER NOT NULL, kind TEXT NOT NULL, opcode INTEGER NOT NULL, bytes INTEGER NOT NULL, note TEXT NOT NULL, payload BLOB NOT NULL, close_code INTEGER, request_headers TEXT, response_headers TEXT)")
                try execute("CREATE INDEX IF NOT EXISTS events_flow ON events(flow_id,id)")
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
    func append(_ event: ProxyWebSocketEvent) throws {
        guard !readOnly, event.id > 0, event.payload.count <= 1024 * 1024,
              event.url.utf8.count <= 16_384, event.flowID.utf8.count <= 1024,
              (event.requestHeaders?.utf8.count ?? 0) <= 32_768,
              (event.responseHeaders?.utf8.count ?? 0) <= 32_768 else { throw RunbarError.message("WebSocket 事件超过缓存限制。") }
        try NetworkDiskSpace.requireAvailable(at: directory, reserve: 512 * 1024 * 1024,
                                             additional: Int64(event.payload.count) * 3 + 1024 * 1024, operation: "写入 WebSocket 缓存")
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
    }
    func window(url: String, kind: String, around row: Int) throws -> ProxyWebSocketWindow {
        deadline = ProcessInfo.processInfo.systemUptime + 3
        let predicate = " WHERE (?='' OR instr(lower(url),lower(?))>0 OR instr(lower(flow_id),lower(?))>0) AND (?='' OR kind=?)"
        func prepare(_ sql: String) throws -> OpaquePointer {
            let stmt = try statement(sql)
            do {
                try bind(String(url.prefix(1024)), to: stmt, at: 1); try bind(String(url.prefix(1024)), to: stmt, at: 2)
                try bind(String(url.prefix(1024)), to: stmt, at: 3)
                try bind(kind, to: stmt, at: 4); try bind(kind, to: stmt, at: 5)
            } catch { sqlite3_finalize(stmt); throw error }
            return stmt
        }
        let count = try prepare("SELECT count(*) FROM events" + predicate)
        guard sqlite3_step(count) == SQLITE_ROW else { sqlite3_finalize(count); throw failure() }
        let total = Int(clamping: sqlite3_column_int64(count, 0)); sqlite3_finalize(count)
        let capacity = ProxyWebSocketWindow.capacity
        let offset = row == Int.max ? max(0, total - capacity) : min(max(0, row - capacity / 2), max(0, total - capacity))
        // The newest page uses the PK in reverse, without walking the entire cache.
        let latest = offset + capacity >= total
        let stmt = try prepare("SELECT id,flow_id,url,timestamp,kind,opcode,bytes,note FROM events" + predicate +
                               (latest ? " ORDER BY id DESC LIMIT \(min(capacity, max(0, total - offset)))" : " ORDER BY id LIMIT \(capacity) OFFSET \(offset)"))
        defer { sqlite3_finalize(stmt) }
        var rows: [ProxyWebSocketSummary] = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let kind = ProxyWebSocketEvent.Kind(rawValue: text(stmt, 4)) else { throw failure() }
            rows.append(ProxyWebSocketSummary(id: sqlite3_column_int64(stmt, 0), flowID: text(stmt, 1), url: text(stmt, 2),
                timestamp: sqlite3_column_int64(stmt, 3), kind: kind, opcode: Int(sqlite3_column_int(stmt, 5)),
                bytes: sqlite3_column_int64(stmt, 6), note: text(stmt, 7)))
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
    func handshake(_ flowID: String) throws -> (String, String) {
        let stmt = try statement("SELECT request_headers,response_headers FROM events WHERE flow_id=? AND kind='open' ORDER BY id LIMIT 1")
        defer { sqlite3_finalize(stmt) }; try bind(flowID, to: stmt, at: 1)
        return sqlite3_step(stmt) == SQLITE_ROW ? (text(stmt, 0), text(stmt, 1)) : ("", "")
    }
}

public struct ProxyWebSocketDetail: Sendable {
    public let text: String
    public let page: Int
    public let pages: Int
    public let note: String
}

public actor ProxyWebSocketReader {
    public init() {}
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
