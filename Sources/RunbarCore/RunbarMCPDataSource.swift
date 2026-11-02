import Foundation
import CoreFoundation

public struct RunbarMCPSource: Sendable {
    public let id: String
    public let key: String
    public let name: String
    public let path: String
    public let kind: String
    public let activeSessionID: UUID?
    public init(id: String, key: String, name: String, path: String, kind: String, activeSessionID: UUID? = nil) {
        self.id = id; self.key = key; self.name = name; self.path = path; self.kind = kind; self.activeSessionID = activeSessionID
    }
}
public struct RunbarMCPRuntime: Sendable {
    public let phase: String
    public let processID: Int32?
    public let networkState: String
    public init(phase: String, processID: Int32? = nil, networkState: String) {
        self.phase = phase; self.processID = processID; self.networkState = networkState
    }
}
public struct RunbarMCPSnapshot: Sendable {
    public let sources: [RunbarMCPSource]
    public let sessions: [RunSession]
    public let live: [UUID: RunbarMCPRuntime]
    public init(sources: [RunbarMCPSource] = [], sessions: [RunSession] = [], live: [UUID: RunbarMCPRuntime] = [:]) {
        self.sources = sources; self.sessions = sessions; self.live = live
    }
}

/// Disk work is independent of the UI's selection and readers. One heavy query
/// at a time bounds payloads, search state and SQLite connections per server.
/// Other heavy requests wait in a bounded, cancellable FIFO queue.
public actor RunbarMCPDataSource {
    private let root: URL
    private let snapshot: @Sendable () async -> RunbarMCPSnapshot
    private let network = NetworkCacheReader(queryTimeLimit: 30)
    private let queries = RunbarMCPQueryQueue()
    private var stopped = false
    var waitingQueries: Int { get async { await queries.waitingCount } }
    private let dateFormatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    public init(root: URL, snapshot: @escaping @Sendable () async -> RunbarMCPSnapshot) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath(); self.snapshot = snapshot
    }
    public func shutdown() async {
        stopped = true
        await queries.shutdown()
        await network.cancelContentSearch()
    }
    private func json(_ value: Any) throws -> Data { try RunbarMCPProtocol.json(value) }
    private func date(_ value: Date?) -> Any { value.map { dateFormatter.string(from: $0) } ?? NSNull() as Any }
    private func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
    private func cut(_ value: String, _ count: Int) -> String { String(value.prefix(count)) }

    public func call(_ name: String, arguments: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !stopped else { throw RunbarMCPQueueError.closed }
        guard let definition = RunbarMCPProtocol.tools().first(where: { $0["name"] as? String == name }),
              let schema = definition["inputSchema"] as? [String: Any], let fields = schema["properties"] as? [String: Any] else {
            throw RunbarMCPToolError.invalidArguments("未知工具。")
        }
        let args = try MCPArguments(arguments, fields: fields, required: schema["required"] as? [String] ?? [])
        if ["runbar_list_sources", "runbar_list_sessions"].contains(name) { return try await perform(name, args: args) }
        let permit = try await queries.acquire()
        do {
            // A queued task may be cancelled just as its permit is handed off.
            try Task.checkCancellation()
            guard !stopped else { throw RunbarMCPQueueError.closed }
            let result = try await perform(name, args: args)
            try Task.checkCancellation()
            await queries.release(permit)
            return result
        } catch {
            await queries.release(permit)
            throw error
        }
    }
    private func perform(_ name: String, args: MCPArguments) async throws -> Data {
        let current = await snapshot()
        try Task.checkCancellation()
        guard !stopped else { throw RunbarMCPQueueError.closed }
        if name == "runbar_list_sources" {
            let offset = try args.integer("offset", fallback: 0), limit = try args.integer("limit", fallback: 50, min: 1, max: 100)
            let sources = current.sources.dropFirst(min(offset, current.sources.count)).prefix(limit)
            let heads = await ProjectGitReader.snapshot(paths: sources.filter { $0.kind != "attachedApp" }.map(\.path))
            return try json(["sources": sources.map { source -> [String: Any] in
                ["sourceId": source.id, "name": source.name, "path": source.path, "kind": source.kind,
                 "gitBranch": optional(heads[source.path]?.title), "activeSessionId": optional(source.activeSessionID?.uuidString)]
            }, "total": current.sources.count, "nextOffset": offset + sources.count < current.sources.count ? offset + sources.count as Any : NSNull()])
        }
        if name == "runbar_list_sessions" {
            let sourceID = try args.string("sourceId"), activeOnly = try args.boolean("runningOnly", fallback: false)
            let source: RunbarMCPSource?
            if let sourceID {
                guard let found = current.sources.first(where: { $0.id == sourceID }) else { throw RunbarError.message("来源不存在，请先调用 runbar_list_sources。") }
                source = found
            } else { source = nil }
            let values = current.sessions.filter { (source == nil || $0.sourceKey == source!.key) && (!activeOnly || current.live[$0.id] != nil) }.sorted { $0.startedAt > $1.startedAt }
            let offset = try args.integer("offset", fallback: 0), limit = try args.integer("limit", fallback: 30, min: 1, max: 100)
            let page = values.dropFirst(min(offset, values.count)).prefix(limit)
            return try json(["sessions": page.map { metadata($0, snapshot: current, commandLimit: 1024) }, "total": values.count,
                             "nextOffset": offset + page.count < values.count ? offset + page.count as Any : NSNull()])
        }
        guard let id = UUID(uuidString: try args.requiredString("sessionId", max: 64)),
              let session = current.sessions.first(where: { $0.id == id }) else {
            throw RunbarError.message("运行记录不存在，请先调用 runbar_list_sessions；不接受文件路径。")
        }
        let directory = try checked("sessions/\(id.uuidString)")
        if name == "runbar_get_session" {
            var value = metadata(session, snapshot: current, commandLimit: 16_384)
            let log = try checked("output.raw", inside: directory)
            value["logBytes"] = (try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let networkDirectory = try checked("network", inside: directory)
            let database = try checked("requests.sqlite", inside: networkDirectory)
            if FileManager.default.fileExists(atPath: database.path) {
                let store = try NetworkStore(directory: networkDirectory, readOnly: true, queryTimeLimit: 30); defer { store.close() }
                value["cachedRequests"] = try store.listCounts(query: NetworkQuery()).total
            } else { value["cachedRequests"] = 0 }
            value["networkCapture"] = current.live[id]?.networkState ?? "历史缓存；本次采集已结束"
            return try json(value)
        }
        if name == "runbar_read_logs" {
            let file = try checked("output.raw", inside: directory)
            guard FileManager.default.fileExists(atPath: file.path) else { return try json(["available": false, "text": "", "reason": "本次运行尚未创建输出文件。"] ) }
            let position = try args.string("position") ?? "latest", offset = try args.integer("offset", fallback: 0, max: 9_007_199_254_740_991)
            let location: LogPageLocation
            switch position {
            case "first": location = .first
            case "latest": location = .latest
            case "after", "before", "around":
                guard args.has("offset") else { throw RunbarMCPToolError.invalidArguments("此位置需要 offset。") }
                location = position == "after" ? .after(UInt64(offset)) : position == "before" ? .before(UInt64(offset)) : .around(UInt64(offset))
            default: throw RunbarMCPToolError.invalidArguments("position 必须是 latest/first/after/before/around。")
            }
            let page = try LogFileReader.read(file, at: location, isLive: current.live[id] != nil, limit: args.integer("maxBytes", fallback: 32_768, min: 1024, max: 65_536))
            return try json(["available": true, "sessionId": id.uuidString, "text": page.text,
                             "startOffset": page.startOffset, "endOffset": page.endOffset, "totalBytes": page.totalBytes,
                             "nextOffset": page.endOffset, "previousOffset": page.startOffset,
                             "hasEarlier": page.hasEarlier, "hasLater": page.hasLater, "isLive": current.live[id] != nil])
        }
        if name == "runbar_search_logs" {
            let file = try checked("output.raw", inside: directory)
            let query = try args.requiredString("query", max: 4096)
            guard !query.isEmpty else { throw RunbarMCPToolError.invalidArguments("query 不能为空。") }
            return try search(file, query: query, offset: args.integer("offset", fallback: 0, max: 9_007_199_254_740_991), limit: args.integer("limit", fallback: 20, min: 1, max: 50))
        }
        let networkDirectory = try checked("network", inside: directory)
        _ = try checked("requests.sqlite", inside: networkDirectory)
        _ = try checked("bodies", inside: networkDirectory)
        if name == "runbar_list_network_requests" {
            var query = NetworkQuery(); query.keywordMode = .any
            for scope in [NetworkKeywordScope.url, .headers, .request, .response] { query.setKeywords(try args.words(scope.rawValue), in: scope) }
            query.setKeywords(try args.words("exclude"), in: .everywhere, excluding: true)
            query.method = try args.string("method", max: 64) ?? ""
            guard let status = NetworkQuery.Status(rawValue: try args.string("status") ?? "all") else { throw RunbarMCPToolError.invalidArguments("status 不受支持。") }
            query.status = status
            let offset = try args.integer("offset", fallback: 0), limit = try args.integer("limit", fallback: 30, min: 1, max: 100)
            let window = try await network.listWindow(directory: networkDirectory, query: query, around: offset)
            let rows = window.rows.dropFirst(min(window.rows.count, max(0, offset - window.offset))).prefix(offset < window.matching ? limit : 0)
            return try json(["requests": rows.map { record -> [String: Any] in
                ["requestId": record.id, "method": record.method, "url": cut(record.url, 2048), "urlTruncated": record.url.count > 2048,
                 "startedAt": date(record.startDate), "status": optional(record.status), "failed": record.failed, "durationMs": optional(record.durationMS)]
            }, "total": window.total, "matching": window.matching, "matchingIsComplete": window.counts.isComplete,
                             "offset": offset, "nextOffset": offset + rows.count < window.matching ? offset + rows.count as Any : NSNull()])
        }
        let requestID = try args.requiredString("requestId", max: 64)
        guard requestID.count == 64, requestID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RunbarMCPToolError.invalidArguments("requestId 必须是列表返回的 64 位小写十六进制 ID。")
        }
        let store = try NetworkStore(directory: networkDirectory, readOnly: true, queryTimeLimit: 30); defer { store.close() }
        guard let record = try store.request(requestID) else { throw RunbarError.message("请求不存在于本次运行缓存中。") }
        if name == "runbar_get_network_request" {
            let data = try JSONEncoder().encode(record)
            var value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            value["startedAt"] = date(record.startDate); value["durationMs"] = optional(record.durationMS)
            value["sessionId"] = id.uuidString; value["requestId"] = record.id
            value["vmRequestId"] = record.requestID
            return try json(value)
        }
        guard name == "runbar_read_network_body" else { throw RunbarMCPToolError.invalidArguments("未知工具。") }
        let part = try args.string("part") ?? "response"
        guard ["request", "response"].contains(part), let format = NetworkBodyFormat(rawValue: try args.string("format") ?? "raw") else { throw RunbarMCPToolError.invalidArguments("part 或 format 不受支持。") }
        guard record.bodyState == .saved else {
            return try json(["available": false, "state": record.bodyState.rawValue, "note": record.bodyNote.isEmpty ? record.bodyState.title : record.bodyNote,
                             "message": "只读取已缓存正文，不会触发目标 App 的网络或调试操作。"])
        }
        let file = try checked("bodies/\(record.id).\(part)", inside: networkDirectory)
        return try body(file, format: format, page: args.integer("page", fallback: 0))
    }

    private func metadata(_ value: RunSession, snapshot: RunbarMCPSnapshot, commandLimit: Int) -> [String: Any] {
        ["sessionId": value.id.uuidString, "sourceId": optional(snapshot.sources.first { $0.key == value.sourceKey }?.id),
         "name": value.sourceName, "projectPath": value.projectPath, "command": cut(value.command, commandLimit), "commandTruncated": value.command.count > commandLimit,
         "status": value.status.rawValue, "isLive": snapshot.live[value.id] != nil, "phase": optional(snapshot.live[value.id]?.phase),
         "processId": optional(snapshot.live[value.id]?.processID ?? value.attachment?.processID), "startedAt": date(value.startedAt), "endedAt": date(value.endedAt),
         "durationSeconds": optional(value.duration ?? (snapshot.live[value.id] != nil ? Date().timeIntervalSince(value.startedAt) : nil)),
         "exitCode": optional(value.exitCode), "error": optional(value.error.map { cut($0, 4096) })]
    }
    private func checked(_ path: String, inside base: URL? = nil) throws -> URL {
        let base = base ?? root, value = base.appendingPathComponent(path).standardizedFileURL
        guard value.path.hasPrefix(base.path + "/"), value.resolvingSymlinksInPath().path == value.path else {
            throw RunbarError.message("缓存路径包含重定向或符号链接，未读取。")
        }
        return value
    }
    private func search(_ url: URL, query: String, offset: Int, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let size = try handle.seekToEnd(), start = min(UInt64(offset), size), end = start + min(size - start, 8 * 1024 * 1024)
        try handle.seek(toOffset: start)
        let needle = Data(query.utf8)
        var overlap = Data(), cursor = start, hits: [[String: Any]] = [], stopped = false
        while cursor < end && !stopped {
            try Task.checkCancellation()
            guard let bytes = try handle.read(upToCount: Int(min(65_536, end - cursor))), !bytes.isEmpty else { break }
            let base = cursor - UInt64(overlap.count), data = overlap + bytes
            cursor += UInt64(bytes.count)
            var position = 0
            while position < data.count, let found = data.range(of: needle, in: position..<data.count) {
                let absolute = base + UInt64(found.lowerBound)
                if absolute >= start {
                    let context = try LogFileReader.read(url, at: .around(absolute), limit: 1024)
                    hits.append(["offset": absolute, "context": context.text, "contextStartOffset": context.startOffset])
                    if hits.count == limit { cursor = base + UInt64(found.upperBound); stopped = true; break }
                }
                position = found.upperBound
            }
            overlap = Data(data.suffix(max(0, needle.count - 1)))
        }
        let next: UInt64 = stopped || cursor >= size ? cursor : max(start, cursor > UInt64(needle.count - 1) ? cursor - UInt64(needle.count - 1) : start)
        return try json(["matches": hits, "scannedThrough": cursor, "totalBytes": size, "caseSensitive": true,
                         "nextOffset": next < size ? next as Any : NSNull(), "complete": next >= size])
    }
    private func body(_ url: URL, format: NetworkBodyFormat, page: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let size = try handle.seekToEnd(), chunk = 32_768
        if format != .raw || size <= UInt64(NetworkBodyFormatter.inputLimit) {
            guard size <= UInt64(NetworkBodyFormatter.inputLimit) else { throw RunbarError.message("正文超过 1 MiB，请使用 raw 分页读取。") }
            try handle.seek(toOffset: 0)
            let input = try handle.read(upToCount: NetworkBodyFormatter.inputLimit + 1) ?? Data()
            let data = try NetworkBodyFormatter.format(input, as: format)
            if !data.contains(0), String(data: data, encoding: .utf8) != nil {
                let result = NetworkBodyFormatter.page(data, page: page, chunk: chunk)
                return try json(["available": true, "encoding": "utf-8", "format": format.rawValue, "text": result.text,
                                 "page": result.page, "pages": result.pages, "bytes": size, "formattedBytes": data.count,
                                 "nextPage": result.page + 1 < result.pages ? result.page + 1 as Any : NSNull()])
            }
        }
        let pages = max(UInt64(1), (size + UInt64(chunk) - 1) / UInt64(chunk)), selected = min(UInt64(page), pages - 1)
        try handle.seek(toOffset: selected * UInt64(chunk))
        let data = try handle.read(upToCount: chunk) ?? Data()
        return try json(["available": true, "encoding": "base64", "format": "raw", "text": data.base64EncodedString(),
                         "page": selected, "pages": pages, "bytes": size, "nextPage": selected + 1 < pages ? selected + 1 as Any : NSNull()])
    }
}

private struct MCPArguments {
    let values: [String: Any]
    init(_ data: Data, fields: [String: Any], required: [String]) throws {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(values.keys).isSubset(of: Set(fields.keys)), required.allSatisfy({ values[$0] != nil }) else {
            throw RunbarMCPToolError.invalidArguments("缺少必填参数或包含未知参数。")
        }
        self.values = values
        // Validate before consulting snapshot/files, so invalid arguments do
        // not silently become valid just because a session has no output yet.
        for key in values.keys {
            guard let field = fields[key] as? [String: Any], let type = field["type"] as? String else { continue }
            switch type {
            case "integer": _ = try integer(key, fallback: 0, min: field["minimum"] as? Int ?? 0, max: field["maximum"] as? Int ?? Int.max)
            case "boolean": _ = try boolean(key, fallback: false)
            case "array": _ = try words(key)
            case "string":
                let value = try requiredString(key)
                if let choices = field["enum"] as? [String], !choices.contains(value) { throw RunbarMCPToolError.invalidArguments("\(key) 的选项不受支持。") }
            default: break
            }
        }
    }
    func has(_ key: String) -> Bool { values[key] != nil }
    func string(_ key: String, max: Int = 4096) throws -> String? {
        guard let value = values[key] else { return nil }
        guard let text = value as? String, text.utf8.count <= max else { throw RunbarMCPToolError.invalidArguments("\(key) 必须是字符串且不超过 \(max) 字节。") }
        return text
    }
    func requiredString(_ key: String, max: Int = 4096) throws -> String {
        guard let value = try string(key, max: max) else { throw RunbarMCPToolError.invalidArguments("缺少 \(key)。") }; return value
    }
    func integer(_ key: String, fallback: Int, min lower: Int = 0, max upper: Int = Int.max) throws -> Int {
        guard let value = values[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue, number.doubleValue >= Double(lower), number.doubleValue < Double(Int.max), number.doubleValue <= Double(upper) else {
            throw RunbarMCPToolError.invalidArguments("\(key) 必须是 \(lower)...\(upper) 范围内的整数。")
        }
        return number.intValue
    }
    func boolean(_ key: String, fallback: Bool) throws -> Bool {
        guard let value = values[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw RunbarMCPToolError.invalidArguments("\(key) 必须是 true 或 false。") }
        return number.boolValue
    }
    func words(_ key: String) throws -> [String] {
        guard let value = values[key] else { return [] }
        guard let words = value as? [String], words.count <= 16, words.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { throw RunbarMCPToolError.invalidArguments("\(key) 最多 16 个非空关键词，每项最多 1024 字节。") }
        return words
    }
}
