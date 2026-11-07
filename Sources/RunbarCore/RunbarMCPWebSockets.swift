import Foundation

struct MCPWebSocketURL {
    let url: String
    let sent: Int64
    let received: Int64
    let firstSeen: Int64?
}

struct MCPWebSocketQuery {
    let url: String
    let connectionID: String
    let kind: String
    let position: String
    let cursor: Int64?
    let through: Int64?
    let limit: Int
    let matcher: ProxyWebSocketMatcher
    var ascending: Bool { position == "first" || position == "after" }
    init(_ args: MCPArguments) throws {
        url = try args.requiredString("url", max: 16_384)
        connectionID = try args.string("connectionId", max: 1024) ?? ""
        guard !url.isEmpty, !url.utf8.contains(0), !connectionID.utf8.contains(0) else {
            throw RunbarMCPToolError.invalidArguments("url 不能为空，URL 和连接 ID 不能包含 NUL。")
        }
        let direction = try args.string("direction") ?? "all"
        kind = direction == "all" ? "" : direction
        position = try args.string("position") ?? "latest"
        if position == "after" || position == "before" {
            cursor = try Self.id(args.requiredString("cursor", max: 19), name: "cursor", zero: position == "after")
        } else {
            guard !args.has("cursor") else { throw RunbarMCPToolError.invalidArguments("cursor 仅用于 after / before。") }
            cursor = nil
        }
        through = try args.string("throughMessageId", max: 19).map { try Self.id($0, name: "throughMessageId", zero: true) }
        if position == "after", let cursor, let through, cursor > through {
            throw RunbarMCPToolError.invalidArguments("after 的 cursor 不能大于 throughMessageId；监听新增时不要携带旧的 throughMessageId。")
        }
        limit = try args.integer("limit", fallback: 30, min: 1, max: 100)
        matcher = try ProxyWebSocketMatcher(search: args.string("query", max: 1024) ?? "",
            includes: args.words("include"), excludes: args.words("exclude"),
            mode: NetworkKeywordMode(rawValue: args.string("keywordMode") ?? "all") ?? .all)
    }
    static func id(_ value: String, name: String, zero: Bool = false) throws -> Int64 {
        guard !value.isEmpty, value.utf8.count <= 19, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int64(value), number >= (zero ? 0 : 1) else {
            throw RunbarMCPToolError.invalidArguments("\(name) 必须是工具返回的十进制字符串 ID。")
        }
        return number
    }
}

/// Stateless ID cursors isolate concurrent AI sessions from each other and the
/// UI. Scans visit a bounded number of immutable events, keeping only one page.
/// The existing MCP queue serializes this work with log and HTTP reads.
final class RunbarMCPWebSocketDataSource {
    static let names = ["runbar_list_websocket_connections", "runbar_list_websocket_messages",
                        "runbar_get_websocket_message", "runbar_read_websocket_body"]
    private let directory: URL
    private let formatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    private static let responseBudget = 512 * 1024
    private var exists: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("websockets.sqlite").path) }
    private init(directory: URL) { self.directory = directory }
    static func call(_ name: String, args: MCPArguments, directory: URL) throws -> Data {
        try Self(directory: directory).perform(name, args: args)
    }
    static func statistics(directory: URL) throws -> [String: Any] {
        let reader = Self(directory: directory)
        guard reader.exists else { return ["available": false, "urlCount": 0, "messageCount": 0, "latestMessageId": NSNull()] }
        let store = try ProxyWebSocketStore(directory: directory, readOnly: true); defer { store.close() }
        let counts = try store.mcpStatistics()
        return ["available": true, "urlCount": counts.urls, "messageCount": counts.messages,
                "latestMessageId": counts.latest > 0 ? String(counts.latest) as Any : NSNull()]
    }
    private func json(_ value: Any) throws -> Data { try RunbarMCPProtocol.json(value) }
    private func date(_ micros: Int64?) -> Any {
        micros.map { formatter.string(from: Date(timeIntervalSince1970: Double($0) / 1_000_000)) } ?? NSNull() as Any
    }
    private func summary(_ row: ProxyWebSocketSummary, cachedBytes: Int) -> [String: Any] {
        ["messageId": String(row.id), "connectionId": row.flowID, "url": String(decoding: row.url.utf8.prefix(2048), as: UTF8.self),
         "urlTruncated": row.url.utf8.count > 2048, "direction": row.kind.rawValue, "timestamp": date(row.timestamp),
         "opcode": row.opcode, "originalBytes": row.bytes, "cachedBytes": cachedBytes,
         "truncated": row.bytes > Int64(cachedBytes), "preview": row.preview, "previewTruncated": cachedBytes > 512]
    }
    private func perform(_ name: String, args: MCPArguments) throws -> Data {
        if name == "runbar_list_websocket_connections" {
            let filter = try args.string("url", max: 1024) ?? ""
            guard !filter.utf8.contains(0) else { throw RunbarMCPToolError.invalidArguments("URL 筛选不能包含 NUL。") }
            let offset = try args.integer("offset", fallback: 0), limit = try args.integer("limit", fallback: 30, min: 1, max: 100)
            guard exists else { return try json(["available": false, "connections": [], "total": 0, "offset": offset, "nextOffset": NSNull(), "note": "本次运行没有已缓存的代理 WebSocket 数据。开启 MCP 不会启用抓包。"] as [String: Any]) }
            let store = try ProxyWebSocketStore(directory: directory, readOnly: true); defer { store.close() }
            let page = try store.mcpConnections(filter: filter, offset: offset, limit: limit)
            var rows: [[String: Any]] = [], size = 0
            for item in page.rows {
                let value: [String: Any] = ["url": item.url, "sendCount": item.sent, "receiveCount": item.received,
                                           "firstSeenAt": date(item.firstSeen), "groupedByURL": true]
                let bytes = try json(value).count
                if !rows.isEmpty, size + bytes > Self.responseBudget { break }
                rows.append(value); size += bytes
            }
            return try json(["available": true, "connections": rows, "total": page.total, "offset": offset,
                             "nextOffset": offset + rows.count < page.total ? offset + rows.count as Any : NSNull()])
        }
        if name == "runbar_list_websocket_messages" {
            let query = try MCPWebSocketQuery(args)
            guard exists else { return try json(["available": false, "messages": [], "hasMore": false, "nextCursor": NSNull(), "nextPosition": NSNull(), "throughMessageId": "0", "pollAfterMessageId": "0", "scannedMessages": 0, "scannedBytes": 0, "note": "本次运行没有已缓存的代理 WebSocket 数据。"] as [String: Any]) }
            let store = try ProxyWebSocketStore(directory: directory, readOnly: true); defer { store.close() }
            return try messages(store, query: query)
        }
        let id = try MCPWebSocketQuery.id(args.requiredString("messageId", max: 19), name: "messageId")
        let format = NetworkBodyFormat(rawValue: try args.string("format") ?? "raw") ?? .raw
        let page = try args.integer("page", fallback: 0)
        guard exists else { throw RunbarError.message("本次运行没有 WebSocket 缓存，消息不可用。") }
        let store = try ProxyWebSocketStore(directory: directory, readOnly: true); defer { store.close() }
        if name == "runbar_get_websocket_message" {
            guard let row = try store.summaries(ids: [id]).first, row.kind == .send || row.kind == .receive else {
                throw RunbarError.message("消息不存在于本次运行的 WebSocket 缓存中。")
            }
            let size = try store.mcpCachedBytes(id)
            var result = summary(row, cachedBytes: size)
            result.removeValue(forKey: "preview"); result.removeValue(forKey: "previewTruncated")
            result["url"] = row.url; result["urlTruncated"] = false; result["note"] = row.note
            let headers = try store.handshake(row.flowID)
            result["requestHeaders"] = (try? JSONSerialization.jsonObject(with: Data(headers.0.utf8))) ?? headers.0
            result["responseHeaders"] = (try? JSONSerialization.jsonObject(with: Data(headers.1.utf8))) ?? headers.1
            if let close = try store.closure(row.flowID) {
                result["observedClose"] = ["timestamp": formatter.string(from: close.date), "code": close.code.map { $0 as Any } ?? NSNull(), "reason": close.reason]
            } else { result["observedClose"] = NSNull() }
            result["connectionStateNote"] = "关闭状态只描述已缓存的关闭事件，不推断当前连接是否在线。"
            return try json(result)
        }
        guard name == "runbar_read_websocket_body", let event = try store.event(id), event.kind == .send || event.kind == .receive else {
            throw RunbarError.message("消息不存在于本次运行的 WebSocket 缓存中。")
        }
        return try body(event, format: format, page: page)
    }
    private func messages(_ store: ProxyWebSocketStore, query: MCPWebSocketQuery) throws -> Data {
        let snapshot = try store.searchSnapshot(url: query.url, kind: query.kind)
        let through = min(query.through ?? snapshot.latest, snapshot.latest)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        let needsBodySearch = !query.matcher.words.isEmpty
        var cursor = query.cursor, scanned = 0, bytes = 0, resultBytes = 0, limitedBy: String?
        var rows: [[String: Any]] = []
        scanning: while true {
            let candidates = try store.mcpCandidates(query: query, cursor: cursor, through: through)
            if candidates.isEmpty { break }
            for candidate in candidates {
                try Task.checkCancellation()
                let cost = needsBodySearch ? candidate.storedBytes : 0
                if scanned > 0, bytes + cost > 8 * 1024 * 1024 { limitedBy = "scanBudget"; break scanning }
                let matches = try !needsBodySearch || autoreleasepool { try store.matches(candidate, matcher: query.matcher) }
                if matches, let summary = try store.summaries(ids: [candidate.id]).first {
                    let value = self.summary(summary, cachedBytes: candidate.storedBytes)
                    let size = try json(value).count
                    if !rows.isEmpty, resultBytes + size > Self.responseBudget { limitedBy = "responseBudget"; break scanning }
                    rows.append(value); resultBytes += size
                }
                cursor = candidate.id; scanned += 1; bytes += cost
                if rows.count >= query.limit { limitedBy = "pageLimit"; break scanning }
                if scanned >= 512 || bytes >= 8 * 1024 * 1024 { limitedBy = "scanBudget"; break scanning }
                if ProcessInfo.processInfo.systemUptime >= deadline { limitedBy = "timeBudget"; break scanning }
            }
        }
        let hasMore = !(try store.mcpCandidates(query: query, cursor: cursor, through: through, limit: 1)).isEmpty
        if !query.ascending { rows.reverse() }
        // Once an ascending range is exhausted, metadata-filtered gaps have
        // also been covered. Advance to its snapshot boundary for polling.
        let pollAfter = query.ascending && hasMore ? cursor ?? query.cursor ?? through :
            max(through, query.ascending ? query.cursor ?? 0 : 0)
        return try json(["available": true, "messages": rows, "hasMore": hasMore,
                         "nextCursor": hasMore ? cursor.map { String($0) as Any } ?? NSNull() : NSNull(),
                         "nextPosition": hasMore ? (query.ascending ? "after" : "before") as Any : NSNull(),
                         "throughMessageId": String(through), "pollAfterMessageId": String(pollAfter),
                         "scannedThroughMessageId": cursor.map { String($0) as Any } ?? NSNull(),
                         "scannedMessages": scanned, "scannedBytes": bytes, "limitedBy": limitedBy.map { $0 as Any } ?? NSNull()])
    }
    private func body(_ event: ProxyWebSocketEvent, format: NetworkBodyFormat, page: Int) throws -> Data {
        let chunk = 32_768
        var value: [String: Any] = ["available": true, "messageId": String(event.id), "connectionId": event.flowID,
            "originalBytes": event.bytes, "cachedBytes": event.payload.count, "truncated": event.bytes > Int64(event.payload.count), "note": event.note]
        if event.opcode == 2 || event.payload.contains(0) || String(data: event.payload, encoding: .utf8) == nil {
            guard format == .raw else { throw RunbarError.message("二进制 WebSocket 消息请用 raw 读取 Base64 分页。") }
            let pages = max(1, (event.payload.count + chunk - 1) / chunk), selected = min(page, pages - 1)
            let lower = selected * chunk, upper = min(event.payload.count, lower + chunk)
            value.merge(["encoding": "base64", "format": "raw", "text": event.payload.subdata(in: lower..<upper).base64EncodedString(),
                         "page": selected, "pages": pages, "nextPage": selected + 1 < pages ? selected + 1 as Any : NSNull()]) { _, new in new }
        } else {
            let bytes = try NetworkBodyFormatter.format(event.payload, as: format)
            let result = NetworkBodyFormatter.page(bytes, page: page, chunk: chunk)
            value.merge(["encoding": "utf-8", "format": format.rawValue, "text": result.text,
                         "page": result.page, "pages": result.pages, "formattedBytes": bytes.count,
                         "nextPage": result.page + 1 < result.pages ? result.page + 1 as Any : NSNull()]) { _, new in new }
        }
        return try json(value)
    }
}
