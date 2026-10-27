import Foundation

public enum NetworkBodyFormat: String, Sendable {
    case raw, json, xml
}

/// Only one bounded response is formatted on the cache reader's background actor.
/// The original payload stays unchanged, and the UI receives just one text page.
public enum NetworkBodyFormatter {
    public static let inputLimit = 1024 * 1024
    public static let outputLimit = 4 * 1024 * 1024

    public static func format(_ data: Data, as format: NetworkBodyFormat) throws -> Data {
        try Task.checkCancellation()
        guard data.count <= inputLimit else { throw RunbarError.message("正文超过 1 MB，无法格式化。") }
        switch format {
        case .raw: return data
        case .json: return try json(data)
        case .xml:
            guard !data.contains(0), let text = String(data: data, encoding: .utf8),
                  text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
                  text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
                throw RunbarError.message("XML 格式化需要 UTF-8 正文，且不能包含 DTD 或实体声明。")
            }
            // Never resolve file / network entities from an inspected response.
            let document: XMLDocument
            do { document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePreserveCDATA]) }
            catch { throw RunbarError.message("正文不是有效的 XML，已保留原始内容。") }
            try Task.checkCancellation()
            let result = document.xmlData(options: .nodePrettyPrint)
            guard result.count <= outputLimit else { throw tooLarge }
            return result
        }
    }
    private static var tooLarge: RunbarError { .message("格式化结果超过 4 MB，请查看原始内容。") }

    private static func json(_ data: Data) throws -> Data {
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw RunbarError.message("JSON 格式化需要 UTF-8 正文，请查看原始内容。")
        }
        // Bound nesting before allocating the parser's object graph. Reformat
        // lexically afterwards to preserve number precision and key order.
        var quoted = false, escaped = false, depth = 0
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 128 else { throw RunbarError.message("JSON 嵌套超过 128 层，请查看原始内容。") }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
        do { _ = try autoreleasepool { try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) } }
        catch { throw RunbarError.message("正文不是有效的 JSON，已保留原始内容。") }
        var result = Data(); result.reserveCapacity(min(data.count * 2, outputLimit))
        func append(_ bytes: Data) throws {
            guard result.count + bytes.count <= outputLimit else { throw tooLarge }
            result.append(bytes)
        }
        func append(_ byte: UInt8) throws {
            guard result.count < outputLimit else { throw tooLarge }
            result.append(byte)
        }
        func newline(_ depth: Int) throws { try append(Data([10] + Array(repeating: 32, count: max(0, depth) * 2))) }
        quoted = false; escaped = false; depth = 0
        var previous: UInt8 = 0
        for (index, byte) in data.enumerated() {
            if index % 4096 == 0 { try Task.checkCancellation() }
            if quoted {
                try append(byte)
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                previous = byte; continue
            }
            if [9, 10, 13, 32].contains(byte) { continue }
            if byte == 34 { quoted = true }
            if byte == 125 || byte == 93 {
                depth -= 1
                if previous != 123 && previous != 91 { try newline(depth) }
            }
            try append(byte)
            if byte == 123 || byte == 91 {
                depth += 1
                let next = data.dropFirst(index + 1).first { ![9, 10, 13, 32].contains($0) }
                if next != 125 && next != 93 { try newline(depth) }
            } else if byte == 44 { try newline(depth) }
            else if byte == 58 { try append(32) }
            previous = byte
        }
        return result
    }

    static func page(_ data: Data, page: Int, chunk: Int) -> (text: String, page: Int, pages: Int) {
        let pages = max(1, (data.count + chunk - 1) / chunk), page = min(max(0, page), pages - 1)
        // Move the end back to a UTF-8 boundary. The next page starts at that
        // same boundary, so every scalar appears exactly once across pages.
        var lower = min(page * chunk, data.count), upper = min((page + 1) * chunk, data.count)
        while lower > 0 && lower < data.count && data[lower] & 0xC0 == 0x80 { lower -= 1 }
        while upper > lower && upper < data.count && data[upper] & 0xC0 == 0x80 { upper -= 1 }
        return (String(decoding: data[lower..<upper], as: UTF8.self), page, pages)
    }
}
