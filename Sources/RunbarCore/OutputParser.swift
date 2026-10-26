import Foundation

/// Incremental UTF-8 and ANSI parser. Raw storage never passes through this parser.
public struct OutputParser {
    private var bytes = Data()
    private var escapeState = 0
    private var line = ""
    private var devToolsContext = false
    public init() {}
    public mutating func consume(_ data: Data, final: Bool = false, detectURLs: Bool = true) -> (text: String, urls: [String]) {
        bytes.append(data)
        var count = bytes.count
        if !final && count > 0 {
            // Hold only an incomplete trailing UTF-8 scalar; replace malformed bytes.
            var start = count - 1
            while start > 0 && bytes[start] & 0xC0 == 0x80 { start -= 1 }
            let first = bytes[start]
            let expected = first < 0x80 ? 1 : first & 0xE0 == 0xC0 ? 2 : first & 0xF0 == 0xE0 ? 3 : first & 0xF8 == 0xF0 ? 4 : 1
            if count - start < expected { count = start }
        }
        let decoded = String(decoding: bytes.prefix(count), as: UTF8.self); bytes = Data(bytes.dropFirst(count))
        var clean = ""
        for scalar in decoded.unicodeScalars {
            switch escapeState {
            case 0:
                if scalar.value == 27 { escapeState = 1 } else { clean.unicodeScalars.append(scalar) }
            case 1:
                if scalar == "[" { escapeState = 2 } else if scalar == "]" { escapeState = 3 } else { escapeState = 0 }
            case 2: if scalar.value >= 0x40 && scalar.value <= 0x7e { escapeState = 0 }
            case 3: if scalar.value == 7 { escapeState = 0 } else if scalar.value == 27 { escapeState = 4 }
            default: escapeState = scalar == "\\" ? 0 : 3
            }
        }
        guard detectURLs else { return (clean, []) }
        var urls: [String] = []
        for character in clean {
            if character == "\n" || character == "\r" {
                urls += detect(line); line = ""
            } else {
                line.append(character)
                if line.utf8.count > 32_768 { line = String(decoding: line.utf8.suffix(16_384), as: UTF8.self) }
            }
        }
        // Detect no-newline output only at EOF; avoids truncated URLs across chunks.
        if final { urls += detect(line); line = "" }
        return (clean, Array(Set(urls)).sorted())
    }
    private mutating func detect(_ value: String) -> [String] {
        let lower = value.lowercased()
        let context = devToolsContext || lower.contains("devtools")
        devToolsContext = lower.contains("devtools") && !lower.contains("http")
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s<>\\\"\\x{001B}]+") else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            let candidate = String(value[range]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;"))
            guard let url = URLComponents(string: candidate), let host = url.host?.lowercased(), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host), ["http", "https"].contains(url.scheme ?? "") else { return nil }
            let path = url.path.lowercased()
            // VM service URLs alone are not DevTools. Modern standalone DevTools
            // may use root path with ?uri=..., older Flutter uses /devtools/.
            let hasURI = url.queryItems?.contains(where: { $0.name == "uri" }) ?? false
            guard path.contains("devtools") || (context && hasURI) else { return nil }
            return candidate
        }
    }
}
