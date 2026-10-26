import Foundation

public struct LogTimeMark: Equatable, Sendable {
    public let utf16Offset: Int
    public let date: Date?
    public init(utf16Offset: Int, date: Date?) { self.utf16Offset = utf16Offset; self.date = date }
    public static func date(at offset: Int, in marks: [LogTimeMark]) -> Date? {
        var low = 0, high = marks.count
        while low < high {
            let middle = (low + high) / 2
            if marks[middle].utf16Offset <= offset { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? marks[low - 1].date : nil
    }
}

private func number(_ data: Data, _ start: Int) -> UInt64 {
    (0..<8).reduce(0) { $0 | UInt64(data[start + $1]) << ($1 * 8) }
}
private func bytes(_ values: UInt64...) -> Data {
    var data = Data()
    for value in values { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
    return data
}

/// A bounded streaming JSON reader plus an on-disk, fixed-width event index.
/// Random log navigation never loads all receive events into RAM.
public final class LogReceiveTimeIndex {
    public private(set) var generation = UUID()
    public private(set) var count: UInt64 = 0
    public private(set) var bytesReadLastUpdate = 0
    public var availableThrough: UInt64 { lastEnd }
    public var hasFile: Bool { url != nil }
    private var url: URL?
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    private var pending = Data()
    private var droppingLine = false
    private var directory: URL?
    private var input: FileHandle?
    private var writer: FileHandle?
    private var reader: FileHandle?
    private var cached: (index: UInt64, start: UInt64, end: UInt64, date: Date)?
    private var lastEnd: UInt64 = 0
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }()
    public init() {}
    deinit { reset() }
    public func reset() {
        for handle in [input, writer, reader] { try? handle?.close() }
        input = nil; writer = nil; reader = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; url = nil; offset = 0; count = 0; pending = Data(); cached = nil; lastEnd = 0; droppingLine = false
        generation = UUID()
    }
    public func update(_ value: URL) throws {
        bytesReadLastUpdate = 0
        guard FileManager.default.fileExists(atPath: value.path) else { if url != nil { reset() }; return }
        let attributes = try FileManager.default.attributesOfItem(atPath: value.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        if url != value || identity != inode || size < offset {
            reset(); url = value; inode = identity
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("runbar-log-times-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            directory = root
            let binary = root.appendingPathComponent("events.idx")
            guard FileManager.default.createFile(atPath: binary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw RunbarError.message("无法创建输出时间索引。")
            }
            input = try FileHandle(forReadingFrom: value); writer = try FileHandle(forWritingTo: binary); reader = try FileHandle(forReadingFrom: binary)
        }
        while offset < size {
            try Task.checkCancellation()
            let read = try autoreleasepool {
                guard let data = try input?.read(upToCount: Int(min(65_536, size - offset))), !data.isEmpty else { return false }
                offset += UInt64(data.count); bytesReadLastUpdate += data.count
                var position = 0, output = Data()
                while position < data.count {
                    let newline = data.range(of: Data([10]), in: position..<data.count)
                    let end = newline?.lowerBound ?? data.count
                    if !droppingLine {
                        if pending.count + end - position <= 16_384 { pending.append(data.subdata(in: position..<end)) }
                        else { pending.removeAll(keepingCapacity: true); droppingLine = true }
                    }
                    if newline != nil {
                        if !droppingLine, let event = try? decoder.decode(OutputEvent.self, from: pending), event.byteCount > 0,
                           event.offset >= lastEnd, UInt64(event.byteCount) <= UInt64.max - event.offset,
                           event.receivedAt.timeIntervalSince1970.isFinite {
                            let end = event.offset + UInt64(event.byteCount)
                            output.append(bytes(event.offset, end, event.receivedAt.timeIntervalSince1970.bitPattern))
                            count += 1; lastEnd = end
                        }
                        pending.removeAll(keepingCapacity: true); droppingLine = false
                    }
                    position = newline?.upperBound ?? data.count
                }
                try writer?.write(contentsOf: output)
                return true
            }
            if !read { break }
        }
    }
    public func date(at offset: UInt64) throws -> Date? {
        if let cached, cached.start <= offset, offset < cached.end { return cached.date }
        if let cached, cached.index + 1 < count, offset >= cached.end,
           let next = try record(cached.index + 1), next.start <= offset, offset < next.end {
            self.cached = next; return next.date
        }
        var low: UInt64 = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            guard let entry = try record(middle) else { return nil }
            if entry.start <= offset { low = middle + 1 } else { high = middle }
        }
        guard low > 0, let entry = try record(low - 1), offset < entry.end else { return nil }
        cached = entry; return entry.date
    }
    private func record(_ index: UInt64) throws -> (index: UInt64, start: UInt64, end: UInt64, date: Date)? {
        try reader?.seek(toOffset: index * 24)
        guard let data = try reader?.read(upToCount: 24), data.count == 24 else { return nil }
        return (index, number(data, 0), number(data, 8), Date(timeIntervalSince1970: Double(bitPattern: number(data, 16))))
    }
}

/// Sparse changes of receive time in a decoded/filtered byte stream. Equal
/// timestamps share one marker, even across many thousands of output lines.
final class LogTimeProjection {
    private let writer: FileHandle
    private let reader: FileHandle
    private var count: UInt64 = 0
    private var last: Date?
    init(_ url: URL) throws {
        writer = try FileHandle(forWritingTo: url); reader = try FileHandle(forReadingFrom: url)
    }
    deinit { try? writer.close(); try? reader.close() }
    func append(at offset: UInt64, date: Date?) throws {
        if count > 0 && last == date { return }
        try writer.write(contentsOf: bytes(offset, (date?.timeIntervalSince1970 ?? .nan).bitPattern))
        count += 1; last = date
    }
    func truncate(at offset: UInt64) throws {
        var low: UInt64 = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            try reader.seek(toOffset: middle * 16)
            let data = try reader.read(upToCount: 16) ?? Data()
            guard data.count == 16 else { throw RunbarError.message("输出时间索引不完整。") }
            if number(data, 0) < offset { low = middle + 1 } else { high = middle }
        }
        count = low; try writer.truncate(atOffset: count * 16); try writer.seek(toOffset: count * 16)
        last = nil
        if count > 0 {
            try reader.seek(toOffset: (count - 1) * 16)
            if let data = try reader.read(upToCount: 16), data.count == 16 {
                let value = Double(bitPattern: number(data, 8)); if value.isFinite { last = Date(timeIntervalSince1970: value) }
            }
        }
    }
}

/// Date metadata for one bounded text window; live appends reuse old marks and
/// parse only the new raw bytes, preserving the first timestamp of a long line.
public final class LogTimestampReader {
    private var source: URL?
    private var generation: UUID?
    private var previous: LogFilePage?
    private var marks: [LogTimeMark] = []
    public private(set) var bytesReadLastRefresh = 0
    public init() {}
    public func reset() { source = nil; previous = nil; generation = nil; marks = [] }
    public func raw(_ url: URL, page: LogFilePage, times: LogReceiveTimeIndex) throws -> [LogTimeMark] {
        bytesReadLastRefresh = 0
        let result: [LogTimeMark]
        if source == url, generation == times.generation, let old = previous, let change = page.change,
           change.baseStartOffset == old.startOffset, change.baseEndOffset == old.endOffset,
           change.baseUTF16Length == old.text.utf16.count, change.removedUTF16Count <= change.baseUTF16Length {
            let removed = change.removedUTF16Count
            var retained = [LogTimeMark(utf16Offset: 0, date: LogTimeMark.date(at: removed, in: marks))]
            retained += marks.filter { $0.utf16Offset > removed }.map { LogTimeMark(utf16Offset: $0.utf16Offset - removed, date: $0.date) }
            let base = max(0, change.baseUTF16Length - removed)
            let continuation = LogTimeMark.date(at: old.text.utf16.count, in: marks)
            let added = try readRaw(url, start: old.endOffset, end: page.endOffset, times: times, initial: .some(continuation))
            for mark in added { append(&retained, offset: base + mark.utf16Offset, date: mark.date) }
            result = retained
        } else { result = try readRaw(url, start: page.startOffset, end: page.endOffset, times: times) }
        source = url; generation = times.generation; previous = page; marks = result
        return result
    }
    private func readRaw(_ url: URL, start: UInt64, end: UInt64, times: LogReceiveTimeIndex, initial: Date?? = nil) throws -> [LogTimeMark] {
        guard end > start else { return [] }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let contextStart = start > 4096 ? start - 4096 : 0
        try handle.seek(toOffset: contextStart)
        let data = try handle.read(upToCount: Int(end - contextStart)) ?? Data()
        bytesReadLastRefresh += data.count
        let lower = Int(start - contextStart)
        guard lower <= data.count else { return [] }
        var parser = OutputParser(), contextLower = 0
        while contextLower < lower, data[contextLower] & 0xc0 == 0x80 { contextLower += 1 }
        _ = parser.consume(data.subdata(in: contextLower..<lower), detectURLs: false)
        var position = lower, utf16 = 0, result: [LogTimeMark] = []
        while position < data.count {
            try Task.checkCancellation()
            let newline = data.range(of: Data([10]), in: position..<data.count)
            let upper = newline?.upperBound ?? data.count
            let lineDate: Date?
            if position == lower, start > 0, (lower == 0 || data[lower - 1] != 10) { lineDate = initial ?? nil }
            else { lineDate = try times.date(at: contextStart + UInt64(position)) }
            let text = parser.consume(data.subdata(in: position..<upper), final: upper == data.count, detectURLs: false).text
            if !text.isEmpty { append(&result, offset: utf16, date: lineDate); utf16 += text.utf16.count }
            position = upper
        }
        return result
    }
    public func projected(_ url: URL, page: LogFilePage) throws -> [LogTimeMark] {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let count = try handle.seekToEnd() / 16
        var low: UInt64 = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            try handle.seek(toOffset: middle * 16)
            guard let record = try handle.read(upToCount: 16), record.count == 16 else { break }
            if number(record, 0) <= page.startOffset { low = middle + 1 } else { high = middle }
        }
        var index = low > 0 ? low - 1 : 0
        try handle.seek(toOffset: index * 16)
        let text = Data(page.text.utf8)
        var bytePosition = 0, utf16 = 0, result: [LogTimeMark] = []
        while index < count {
            try Task.checkCancellation()
            guard let record = try handle.read(upToCount: 16), record.count == 16 else { break }
            let offset = number(record, 0)
            if offset >= page.endOffset && offset > page.startOffset { break }
            let relative = min(text.count, Int(offset > page.startOffset ? offset - page.startOffset : 0))
            utf16 += String(decoding: text.subdata(in: bytePosition..<relative), as: UTF8.self).utf16.count
            bytePosition = relative
            let time = Double(bitPattern: number(record, 8))
            append(&result, offset: utf16, date: time.isFinite ? Date(timeIntervalSince1970: time) : nil)
            index += 1
        }
        return result
    }
    private func append(_ target: inout [LogTimeMark], offset: Int, date: Date?) {
        if target.last?.date != date || target.isEmpty { target.append(LogTimeMark(utf16Offset: offset, date: date)) }
    }
}
