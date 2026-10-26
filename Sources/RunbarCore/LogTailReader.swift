import Foundation

/// Incremental tail: a 256 KiB active window for low-latency live layout, up to
/// one MiB for finished logs. Batched eviction avoids shifting per output byte.
public struct LogTailReader {
    public static let liveWindowBytes = 262_144
    private struct Chunk {
        var start: UInt64
        var end: UInt64
        var text: String
    }
    private static let chunkBytes = 65_536
    private var limit = LogFileReader.windowBytes
    private var chunks: [Chunk] = []
    private var parser = OutputParser()
    private var source: URL?
    private var inode: UInt64?
    private var cursor: UInt64 = 0
    private var wasFinal = false
    public private(set) var bytesReadLastRefresh = 0
    var retainedChunkCount: Int { chunks.count }
    public init() {}

    public mutating func reset() { self = LogTailReader() }

    public mutating func read(_ url: URL, isLive: Bool) throws -> LogFilePage {
        bytesReadLastRefresh = 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let desiredLimit = isLive ? Self.liveWindowBytes : LogFileReader.windowBytes
        let identity = (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        let rebuild = source != url || inode != identity || size < cursor || size - min(size, cursor) > UInt64(desiredLimit)
            || (wasFinal && size > cursor)
            || desiredLimit < limit || (desiredLimit > limit && (chunks.first?.start ?? 0) > 0)
        limit = desiredLimit
        if rebuild {
            chunks = []; parser = OutputParser(); source = url; inode = identity; wasFinal = false
            let start = size > UInt64(limit) ? size - UInt64(limit) : 0
            let contextStart = start > 4096 ? start - 4096 : 0
            try handle.seek(toOffset: contextStart)
            let data = try handle.read(upToCount: Int(size - contextStart)) ?? Data()
            bytesReadLastRefresh = data.count
            var lower = min(Int(start - contextStart), data.count)
            while lower < data.count, data[lower] & 0xC0 == 0x80 { lower += 1 }
            var contextLower = 0
            while contextLower < lower, data[contextLower] & 0xC0 == 0x80 { contextLower += 1 }
            _ = parser.consume(data.subdata(in: contextLower..<lower), detectURLs: false)
            cursor = contextStart + UInt64(lower)
            var ignoredRemoval = 0
            _ = consume(data.subdata(in: lower..<data.count), removed: &ignoredRemoval)
            if !isLive { _ = finish(removed: &ignoredRemoval) }
            return page(total: size, change: nil)
        }

        let oldStart = chunks.first?.start ?? cursor - UInt64(parser.bufferedByteCount)
        let oldEnd = cursor - UInt64(parser.bufferedByteCount)
        let oldLength = chunks.reduce(0) { $0 + $1.text.utf16.count }
        var removed = 0
        try handle.seek(toOffset: cursor)
        let data = try handle.read(upToCount: Int(size - cursor)) ?? Data()
        bytesReadLastRefresh = data.count
        var inserted = consume(data, removed: &removed)
        if !isLive { inserted += finish(removed: &removed) }
        // A large append may evict part of its own prefix as well as old text.
        let removedNew = max(0, removed - oldLength)
        if removedNew > 0 { inserted = (inserted as NSString).substring(from: min(removedNew, inserted.utf16.count)) }
        let change = LogTextChange(baseStartOffset: oldStart, baseEndOffset: oldEnd, baseUTF16Length: oldLength,
                                   removedUTF16Count: min(oldLength, removed), insertedText: inserted)
        return page(total: size, change: change)
    }

    private mutating func consume(_ data: Data, removed: inout Int) -> String {
        var output = ""
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + Self.chunkBytes)
            let start = cursor - UInt64(parser.bufferedByteCount)
            let text = parser.consume(data.subdata(in: offset..<end), detectURLs: false).text
            cursor += UInt64(end - offset)
            append(Chunk(start: start, end: cursor - UInt64(parser.bufferedByteCount), text: text), removed: &removed)
            output += text; offset = end
        }
        return output
    }
    private mutating func finish(removed: inout Int) -> String {
        let start = cursor - UInt64(parser.bufferedByteCount)
        let text = parser.consume(Data(), final: true, detectURLs: false).text
        if cursor > start || !text.isEmpty { append(Chunk(start: start, end: cursor, text: text), removed: &removed) }
        wasFinal = true
        return text
    }
    private mutating func append(_ chunk: Chunk, removed: inout Int) {
        if let last = chunks.last, last.end == chunk.start, chunk.end - last.start <= UInt64(Self.chunkBytes) {
            chunks[chunks.count - 1].end = chunk.end
            chunks[chunks.count - 1].text += chunk.text
        } else { chunks.append(chunk) }
        guard let first = chunks.first, let last = chunks.last,
              last.end - first.start > UInt64(limit) else { return }
        while chunks.count > 1, chunks.last!.end - chunks.first!.start > UInt64(limit * 3 / 4) {
            removed += chunks.removeFirst().text.utf16.count
        }
    }
    private func page(total: UInt64, change: LogTextChange?) -> LogFilePage {
        let end = cursor - UInt64(parser.bufferedByteCount)
        return LogFilePage(text: chunks.map(\.text).joined(), startOffset: chunks.first?.start ?? end,
                           endOffset: end, totalBytes: total, change: change)
    }
}
