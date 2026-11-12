import Foundation

public struct LogFilter: Codable, Equatable, Sendable {
    public var includes: [String]
    public var excludes: [String]
    public var from: Date?
    public var through: Date?
    public init(includes: [String] = [], excludes: [String] = [], from: Date? = nil, through: Date? = nil) {
        self.includes = includes; self.excludes = excludes; self.from = from; self.through = through
    }
    public var hasTimeRange: Bool { from != nil || through != nil }
    public var isEmpty: Bool { includes.isEmpty && excludes.isEmpty && !hasTimeRange }
    public func contains(_ date: Date?) -> Bool {
        guard hasTimeRange else { return true }
        guard let date else { return false }
        return (from == nil || date >= from!) && (through == nil || date <= through!)
    }
    public func validated() throws -> LogFilter {
        func clean(_ words: [String]) throws -> [String] {
            var result: [String] = []
            for word in words where !word.isEmpty && !result.contains(word) {
                guard word.utf8.count <= 1024, !word.contains("\n"), !word.contains("\r") else {
                    throw RunbarError.message("每个筛选关键词最多 1 KB，且不能包含换行。")
                }
                result.append(word)
            }
            guard result.count <= 32 else { throw RunbarError.message("包含、排除各最多 32 个关键词。") }
            return result
        }
        guard from?.timeIntervalSince1970.isFinite != false, through?.timeIntervalSince1970.isFinite != false,
              from == nil || through == nil || from! <= through! else {
            throw RunbarError.message("开始时间不能晚于结束时间。")
        }
        return try LogFilter(includes: clean(includes), excludes: clean(excludes), from: from, through: through)
    }
    /// Include/exclude lists are unions; time constraints all apply together.
    public static func combining(_ filters: [LogFilter]) throws -> LogFilter {
        let from = filters.compactMap(\.from).max()
        let through = filters.compactMap(\.through).min()
        if let from, let through, from > through {
            throw RunbarError.message("筛选时间段没有交集，请取消冲突的方案或调整时间。")
        }
        return try LogFilter(includes: filters.flatMap(\.includes), excludes: filters.flatMap(\.excludes),
                             from: from, through: through).validated()
    }
}

public struct LogFilterPreset: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var filter: LogFilter
    public init(name: String, filter: LogFilter) { self.name = name; self.filter = filter }
}

public struct LogPreferences: Codable, Equatable, Sendable {
    public var filter = LogFilter()
    public var keywords: [String] = []
    public var presets: [LogFilterPreset] = []
    public private(set) var selectedPresetIDs: [UUID] = []
    // Keep the original custom conditions so deselecting a scheme never removes
    // a shared keyword or leaves conditions from a previously selected scheme.
    private var baseFilter: LogFilter?
    public init() {}
    private enum CodingKeys: String, CodingKey { case filter, keywords, presets, selectedPresetIDs, baseFilter }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        filter = try values.decodeIfPresent(LogFilter.self, forKey: .filter) ?? LogFilter()
        keywords = try values.decodeIfPresent([String].self, forKey: .keywords) ?? []
        presets = try values.decodeIfPresent([LogFilterPreset].self, forKey: .presets) ?? []
        selectedPresetIDs = try values.decodeIfPresent([UUID].self, forKey: .selectedPresetIDs) ?? []
        baseFilter = try values.decodeIfPresent(LogFilter.self, forKey: .baseFilter)
        selectedPresetIDs = selectedPresetIDs.filter { id in presets.contains { $0.id == id } }
        if selectedPresetIDs.isEmpty { baseFilter = nil }
        else { try rebuildSelection() }
    }
    public mutating func apply(_ value: LogFilter) throws {
        filter = try value.validated()
        // Editing the effective conditions makes a custom snapshot. Presets
        // themselves remain unchanged, and clear also clears their selection.
        selectedPresetIDs = []; baseFilter = nil
        rememberKeywords()
    }
    public mutating func togglePreset(_ id: UUID) throws {
        guard presets.contains(where: { $0.id == id }) else { throw RunbarError.message("筛选方案已不存在。") }
        var next = self
        if next.selectedPresetIDs.isEmpty { next.baseFilter = next.filter }
        if next.selectedPresetIDs.contains(id) { next.selectedPresetIDs.removeAll { $0 == id } }
        else { next.selectedPresetIDs.append(id) }
        try next.rebuildSelection(); next.rememberKeywords(); self = next
    }
    public mutating func removePreset(_ id: UUID) throws {
        var next = self
        next.presets.removeAll { $0.id == id }
        if next.selectedPresetIDs.contains(id) {
            next.selectedPresetIDs.removeAll { $0 == id }
            try next.rebuildSelection()
        }
        self = next
    }
    private mutating func rebuildSelection() throws {
        filter = try LogFilter.combining([baseFilter ?? LogFilter()] + selectedPresetIDs.compactMap { id in
            presets.first { $0.id == id }?.filter
        })
        if selectedPresetIDs.isEmpty { baseFilter = nil }
    }
    private mutating func rememberKeywords() {
        for word in (filter.includes + filter.excludes).reversed() {
            keywords.removeAll { $0 == word }; keywords.insert(word, at: 0)
        }
        keywords = Array(keywords.prefix(128))
    }
    public mutating func savePreset(name: String) throws {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty else { throw RunbarError.message("请填写筛选方案名称。") }
        var next = self
        if let index = next.presets.firstIndex(where: { $0.name == name }) { next.presets[index].filter = filter }
        else {
            guard presets.count < 32 else { throw RunbarError.message("最多保存 32 组筛选方案，请先删除不用的方案。") }
            next.presets.append(LogFilterPreset(name: name, filter: filter))
        }
        if !next.selectedPresetIDs.isEmpty { try next.rebuildSelection() }
        self = next
    }
}

public struct LogQuerySnapshot: Sendable {
    public let fullURL: URL
    public let filteredURL: URL
    public let fullTimesURL: URL
    public let filteredTimesURL: URL
    public let matchCount: UInt64
    public let sourceBytes: UInt64
    public let filteredBytes: UInt64
    /// Changes whenever a previously visible unfinished line is removed.
    public let filterRevision: UInt64
}

/// Serial worker owned by the UI's disk actor. Source, decoded output, filtered
/// output and match offsets stay on disk. Neither line length nor match count
/// can grow the retained RAM: chunks are 64 KB and keyword overlap is <= 4 KB.
public final class LogQueryProcessor {
    public static let chunkBytes = 65_536
    private var folder: URL?
    private var source: FileHandle?
    private var full: FileHandle?
    private var fullReader: FileHandle?
    private var filtered: FileHandle?
    private var matches: FileHandle?
    private var sourceURL: URL?
    private var inode: UInt64 = 0
    private var filter = LogFilter()
    private var query = ""
    private var parser = OutputParser()
    private var sourceOffset: UInt64 = 0
    private var cleanOffset: UInt64 = 0
    private var filteredOffset: UInt64 = 0
    private var finalized = false
    private var lineStart: UInt64 = 0
    private var projectedStart: UInt64 = 0
    private var projectedEnd: UInt64 = 0
    private var lineVisible = false
    private var includeFound = false
    private var excludeFound = false
    private var lineOverlap = Data()
    private var includeBytes: [Data] = []
    private var excludeBytes: [Data] = []
    private var filterOverlapSize = 0
    private var needle = Data()
    private var searchOverlap = Data()
    private var nextMatchOffset: UInt64 = 0
    private var matchBuffer = Data()
    private var filteredBuffer = Data()
    private var matchCount: UInt64 = 0
    private var filterRevision: UInt64 = 0
    private var fullTimes: LogTimeProjection?
    private var filteredTimes: LogTimeProjection?
    private var timeGeneration: UUID?
    private var rawLineStart: UInt64 = 0
    private var rawLineDate: Date?
    private var hasRawLine = false
    private var hasFullTimeMark = false
    public private(set) var bytesReadLastUpdate: UInt64 = 0
    public var retainedOverlapBytes: Int { lineOverlap.count + searchOverlap.count + matchBuffer.count + parser.bufferedByteCount }
    public init() {}
    deinit { reset() }

    public func reset() {
        fullTimes = nil; filteredTimes = nil
        for handle in [source, full, fullReader, filtered, matches] { try? handle?.close() }
        source = nil; full = nil; fullReader = nil; filtered = nil; matches = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil; sourceURL = nil; parser = OutputParser()
        sourceOffset = 0; cleanOffset = 0; filteredOffset = 0; finalized = false
        lineStart = 0; projectedStart = 0; projectedEnd = 0; lineVisible = false
        includeFound = false; excludeFound = false; lineOverlap = Data()
        searchOverlap = Data(); nextMatchOffset = 0; matchBuffer = Data(); filteredBuffer = Data(); matchCount = 0; filterRevision = 0
        timeGeneration = nil; rawLineStart = 0; rawLineDate = nil; hasRawLine = false; hasFullTimeMark = false
    }

    /// Appended output is scanned exactly once. Cancellation also removes all
    /// partial files, so changing sessions/queries cannot publish a stale index.
    public func update(_ url: URL, filter value: LogFilter, query: String, isLive: Bool, times: LogReceiveTimeIndex? = nil,
                       progress: (UInt64, UInt64) -> Void = { _, _ in }) throws -> LogQuerySnapshot {
        let value = try value.validated()
        guard query.utf8.count <= 4096 else { throw RunbarError.message("搜索关键词最多 4 KB。") }
        bytesReadLastUpdate = 0
        do {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let currentInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let rawSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            // Raw bytes are written just before their receive event. Wait for
            // that append during a live run rather than permanently inventing
            // an unknown timestamp for a line that is still being persisted.
            let size = isLive && times?.hasFile == true ? min(rawSize, times!.availableThrough) : rawSize
            if sourceURL != url || inode != currentInode || sourceOffset > size || filter != value || self.query != query || (finalized && sourceOffset < size) || timeGeneration != times?.generation {
                reset()
                filter = value; self.query = query; sourceURL = url; inode = currentInode
                timeGeneration = times?.generation
                includeBytes = value.includes.map { Data($0.utf8) }; excludeBytes = value.excludes.map { Data($0.utf8) }
                filterOverlapSize = max(0, ((includeBytes + excludeBytes).map(\.count).max() ?? 0) - 1)
                needle = Data(query.utf8)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runbar-log-query-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                folder = directory
                for name in ["full.txt", "filtered.txt", "matches.idx", "full-times.idx", "filtered-times.idx"] {
                    guard FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw RunbarError.message("无法创建日志临时索引，请检查磁盘空间。")
                    }
                }
                source = try FileHandle(forReadingFrom: url)
                full = try FileHandle(forWritingTo: directory.appendingPathComponent("full.txt"))
                fullReader = try FileHandle(forReadingFrom: directory.appendingPathComponent("full.txt"))
                filtered = try FileHandle(forWritingTo: directory.appendingPathComponent("filtered.txt"))
                matches = try FileHandle(forWritingTo: directory.appendingPathComponent("matches.idx"))
                fullTimes = try LogTimeProjection(directory.appendingPathComponent("full-times.idx"))
                filteredTimes = try LogTimeProjection(directory.appendingPathComponent("filtered-times.idx"))
            }
            var lastProgress = Date.distantPast
            while sourceOffset < size {
                try Task.checkCancellation()
                let count = Int(min(UInt64(Self.chunkBytes), size - sourceOffset))
                // FileHandle/Foundation can return autoreleased storage. Drain
                // it per chunk even when scanning gigabytes on an actor thread.
                let advanced = try autoreleasepool {
                    guard let data = try source?.read(upToCount: count), !data.isEmpty else { return false }
                    sourceOffset += UInt64(data.count); bytesReadLastUpdate += UInt64(data.count)
                    try consumeRaw(data, start: sourceOffset - UInt64(data.count), times: times)
                    return true
                }
                if !advanced { break }
                if Date().timeIntervalSince(lastProgress) > 0.2 {
                    lastProgress = Date(); progress(sourceOffset, size)
                }
            }
            if !isLive && !finalized {
                try consume(Data(parser.consume(Data(), final: true, detectURLs: false).text.utf8), timestamp: rawLineDate)
                finalized = true
            }
            try flushMatches()
            try flushFiltered()
            try Task.checkCancellation()
            guard let folder else { throw RunbarError.message("日志索引不可用。") }
            return LogQuerySnapshot(fullURL: folder.appendingPathComponent("full.txt"), filteredURL: folder.appendingPathComponent(filter.isEmpty ? "full.txt" : "filtered.txt"),
                                    fullTimesURL: folder.appendingPathComponent("full-times.idx"), filteredTimesURL: folder.appendingPathComponent(filter.isEmpty ? "full-times.idx" : "filtered-times.idx"),
                                    matchCount: matchCount, sourceBytes: sourceOffset, filteredBytes: filteredOffset, filterRevision: filterRevision)
        } catch { reset(); throw error }
    }

    public func matchOffset(at ordinal: UInt64) throws -> UInt64 {
        try Task.checkCancellation()
        guard ordinal > 0, ordinal <= matchCount, let folder else { throw RunbarError.message("搜索结果已更新，请重新搜索。") }
        let handle = try FileHandle(forReadingFrom: folder.appendingPathComponent("matches.idx"))
        defer { try? handle.close() }
        try handle.seek(toOffset: (ordinal - 1) * 8)
        guard let data = try handle.read(upToCount: 8), data.count == 8 else { throw RunbarError.message("无法读取搜索位置。") }
        return data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }

    private func consumeRaw(_ data: Data, start: UInt64, times: LogReceiveTimeIndex?) throws {
        var position = 0
        while position < data.count {
            try Task.checkCancellation()
            let newline = data.range(of: Data([10]), in: position..<data.count)
            let upper = newline?.upperBound ?? data.count
            if !hasRawLine { rawLineDate = try times?.date(at: rawLineStart); hasRawLine = true }
            let clean = parser.consume(data.subdata(in: position..<upper), detectURLs: false).text
            try consume(Data(clean.utf8), timestamp: rawLineDate)
            if clean.hasSuffix("\n") { rawLineStart = start + UInt64(upper); hasRawLine = false }
            position = upper
        }
    }
    private func consume(_ data: Data, timestamp: Date?) throws {
        guard !data.isEmpty else { return }
        try full?.write(contentsOf: data)
        try search(data, start: cleanOffset)
        if filter.isEmpty {
            if !hasFullTimeMark { try fullTimes?.append(at: cleanOffset, date: timestamp); hasFullTimeMark = true }
            if data.last == 10 { hasFullTimeMark = false }
            cleanOffset += UInt64(data.count); filteredOffset = cleanOffset
            return
        }
        var lower = 0
        while lower < data.count {
            try Task.checkCancellation()
            let newline = data.range(of: Data([10]), in: lower..<data.count)
            let upper = newline?.upperBound ?? data.count
            let segment = data.subdata(in: lower..<upper)
            if !hasFullTimeMark { try fullTimes?.append(at: cleanOffset + UInt64(lower), date: timestamp); hasFullTimeMark = true }
            let sample = lineOverlap + segment
            if !includeFound { includeFound = includeBytes.contains { sample.range(of: $0) != nil } }
            if !excludeFound { excludeFound = excludeBytes.contains { sample.range(of: $0) != nil } }
            lineOverlap = Data(sample.suffix(max(0, filterOverlapSize)))
            let end = cleanOffset + UInt64(upper)
            let visible = (includeBytes.isEmpty || includeFound) && !excludeFound && filter.contains(timestamp)
            if !visible && lineVisible {
                try flushFiltered()
                try filtered?.truncate(atOffset: projectedStart); try filtered?.seek(toOffset: projectedStart)
                filteredOffset = projectedStart; lineVisible = false; filterRevision += 1
                try filteredTimes?.truncate(at: projectedStart)
            } else if visible {
                if !lineVisible { try filteredTimes?.append(at: filteredOffset, date: timestamp) }
                let start = lineVisible ? projectedEnd : lineStart
                if start >= cleanOffset { try appendFiltered(data.subdata(in: Int(start - cleanOffset)..<upper)) }
                else { try copyClean(from: start, to: end) }
                lineVisible = true; projectedEnd = end
            }
            if newline != nil {
                lineStart = end; projectedStart = filteredOffset; projectedEnd = end
                lineVisible = false; includeFound = false; excludeFound = false; lineOverlap.removeAll(keepingCapacity: true)
                hasFullTimeMark = false
            }
            lower = upper
        }
        cleanOffset += UInt64(data.count)
    }
    private func copyClean(from start: UInt64, to end: UInt64) throws {
        try fullReader?.seek(toOffset: start)
        var remaining = end - start
        while remaining > 0 {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let data = try fullReader?.read(upToCount: Int(min(UInt64(Self.chunkBytes), remaining))), !data.isEmpty else {
                    throw RunbarError.message("读取筛选日志失败。")
                }
                try appendFiltered(data); remaining -= UInt64(data.count)
            }
        }
    }
    private func appendFiltered(_ data: Data) throws {
        filteredBuffer.append(data); filteredOffset += UInt64(data.count)
        if filteredBuffer.count >= Self.chunkBytes { try flushFiltered() }
    }
    private func flushFiltered() throws {
        if !filteredBuffer.isEmpty { try filtered?.write(contentsOf: filteredBuffer); filteredBuffer.removeAll(keepingCapacity: true) }
    }
    private func search(_ data: Data, start: UInt64) throws {
        guard !needle.isEmpty else { return }
        let sample = searchOverlap + data
        let base = start - UInt64(searchOverlap.count)
        var position = Int(min(UInt64(sample.count), nextMatchOffset > base ? nextMatchOffset - base : 0))
        while position < sample.count, let range = sample.range(of: needle, in: position..<sample.count) {
            if matchCount % 4096 == 0 { try Task.checkCancellation() }
            var value = (base + UInt64(range.lowerBound)).littleEndian
            withUnsafeBytes(of: &value) { matchBuffer.append(contentsOf: $0) }
            matchCount += 1; position = range.upperBound; nextMatchOffset = base + UInt64(position)
            if matchBuffer.count >= Self.chunkBytes { try flushMatches() }
        }
        searchOverlap = Data(sample.suffix(max(0, needle.count - 1)))
    }
    private func flushMatches() throws {
        if !matchBuffer.isEmpty { try matches?.write(contentsOf: matchBuffer); matchBuffer.removeAll(keepingCapacity: true) }
    }
}
