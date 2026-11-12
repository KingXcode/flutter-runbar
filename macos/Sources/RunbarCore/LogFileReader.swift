import Foundation

public enum LogPageLocation: Sendable {
    case first, latest, before(UInt64), after(UInt64), around(UInt64), fraction(Double)
}

/// A bounded disk window. Offsets refer to original bytes, not rendered text.
public struct LogFilePage: Sendable {
    public let text: String
    public let startOffset: UInt64
    public let endOffset: UInt64
    public let totalBytes: UInt64
    public let anchorByteOffset: UInt64?
    public let anchorUTF16Offset: Int?
    public let change: LogTextChange?
    public init(text: String, startOffset: UInt64, endOffset: UInt64, totalBytes: UInt64,
                anchorByteOffset: UInt64? = nil, anchorUTF16Offset: Int? = nil, change: LogTextChange? = nil) {
        self.text = text; self.startOffset = startOffset; self.endOffset = endOffset; self.totalBytes = totalBytes
        self.anchorByteOffset = anchorByteOffset; self.anchorUTF16Offset = anchorUTF16Offset; self.change = change
    }
    public var hasEarlier: Bool { startOffset > 0 }
    public var hasLater: Bool { endOffset < totalBytes }
}

/// Applied only if the native view still displays this exact base window.
public struct LogTextChange: Sendable {
    public let baseStartOffset: UInt64
    public let baseEndOffset: UInt64
    public let baseUTF16Length: Int
    public let removedUTF16Count: Int
    public let insertedText: String
}

public enum LogFileReader {
    public static let windowBytes = 1_048_576
    private static let contextBytes = 4096

    /// Reads at most one window plus a small ANSI/UTF-8 boundary context, even
    /// for multi-gigabyte files. Adjacent pages share an exact byte boundary.
    public static func read(_ url: URL, at location: LogPageLocation = .latest,
                            isLive: Bool = false, limit: Int = windowBytes) throws -> LogFilePage {
        let budget = min(windowBytes, max(4, limit))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start: UInt64
        let end: UInt64
        var anchor: UInt64?
        switch location {
        case .first: start = 0; end = min(size, UInt64(budget))
        case .latest: end = size; start = size > UInt64(budget) ? size - UInt64(budget) : 0
        case .before(let offset):
            end = min(offset, size); start = end > UInt64(budget) ? end - UInt64(budget) : 0
        case .after(let offset):
            start = min(offset, size); end = start + min(size - start, UInt64(budget))
        case .around(let offset):
            let target = min(offset, size)
            anchor = target
            let proposed = target > UInt64(budget / 2) ? target - UInt64(budget / 2) : 0
            start = min(proposed, size > UInt64(budget) ? size - UInt64(budget) : 0)
            end = start + min(size - start, UInt64(budget))
        case .fraction(let value):
            let fraction = LogScrollMetrics.clamp(value)
            let target = fraction == 1 ? size : UInt64(Double(size) * fraction)
            anchor = target
            let proposed = target > UInt64(budget / 2) ? target - UInt64(budget / 2) : 0
            start = min(proposed, size > UInt64(budget) ? size - UInt64(budget) : 0)
            end = start + min(size - start, UInt64(budget))
        }
        let contextStart = start > UInt64(contextBytes) ? start - UInt64(contextBytes) : 0
        try handle.seek(toOffset: contextStart)
        let data = try handle.read(upToCount: Int(end - contextStart) + 4) ?? Data()
        var lower = min(Int(start - contextStart), data.count)
        var upper = min(Int(end - contextStart), data.count)
        // Never split a valid UTF-8 scalar between pages.
        while lower < upper, data[lower] & 0xC0 == 0x80 { lower += 1 }
        if end < size {
            while upper > lower, upper < data.count, data[upper] & 0xC0 == 0x80 { upper -= 1 }
        } else if isLive, upper > lower {
            var scalarStart = upper - 1
            while scalarStart > lower, data[scalarStart] & 0xC0 == 0x80 { scalarStart -= 1 }
            let byte = data[scalarStart]
            let expected = byte < 0x80 ? 1 : byte & 0xE0 == 0xC0 ? 2 : byte & 0xF0 == 0xE0 ? 3 : byte & 0xF8 == 0xF0 ? 4 : 1
            if upper - scalarStart < expected { upper = scalarStart }
        }
        var contextLower = 0
        while contextLower < lower, data[contextLower] & 0xC0 == 0x80 { contextLower += 1 }
        var parser = OutputParser()
        // Warm up ANSI state across page boundaries without scanning old files
        // or repeatedly running URL detection for already-persisted output.
        _ = parser.consume(data.subdata(in: contextLower..<lower), detectURLs: false)
        var anchorIndex: Int?
        let text: String
        if let offset = anchor {
            var split = min(upper, max(lower, Int(offset - contextStart)))
            while split > lower, split < data.count, data[split] & 0xC0 == 0x80 { split -= 1 }
            let prefix = parser.consume(data.subdata(in: lower..<split), detectURLs: false).text
            anchorIndex = prefix.utf16.count
            text = prefix + parser.consume(data.subdata(in: split..<upper), final: !isLive, detectURLs: false).text
        } else { text = parser.consume(data.subdata(in: lower..<upper), final: !isLive, detectURLs: false).text }
        return LogFilePage(text: text, startOffset: contextStart + UInt64(lower),
                           endOffset: contextStart + UInt64(upper), totalBytes: size,
                           anchorByteOffset: anchor, anchorUTF16Offset: anchorIndex)
    }
}

/// Global byte progress derived from the local TextKit viewport. No whole-file
/// line index or artificial multi-gigabyte text document is retained in RAM.
public struct LogScrollMetrics {
    public let value: Double
    public let knobProportion: Double
    public static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
    public init(start: UInt64, end: UInt64, total: UInt64, localProgress: Double, visibleFraction: Double) {
        guard total > 0 else { value = 0; knobProportion = 1; return }
        let span = Double(end >= start ? end - start : 0)
        let visible = span * Self.clamp(visibleFraction)
        let top = Double(start) + Self.clamp(localProgress) * max(0, span - visible)
        value = Self.clamp(top / max(1, Double(total) - visible))
        knobProportion = Self.clamp(visible / Double(total))
    }
}
