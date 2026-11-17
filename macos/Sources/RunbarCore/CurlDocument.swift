import Foundation

/// A single HTTP transfer described by validated curl options. The editor's
/// text is never evaluated by a shell or passed through as arbitrary arguments.
public struct CurlRequest: Codable, Equatable, Sendable {
    public let method: String
    public let url: URL
    let options: [Option]

    struct Option: Codable, Equatable, Sendable {
        let name: String
        let value: String?
        init(_ name: String, _ value: String? = nil) { self.name = name; self.value = value }
    }

    public var curlText: String {
        func quote(_ value: String) -> String {
            if value.contains("\n") || value.contains("\r") {
                return "$'" + value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                    .replacingOccurrences(of: "\r", with: "\\r")
                    .replacingOccurrences(of: "\n", with: "\\n") + "'"
            }
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let parts = ["curl " + quote(url.absoluteString)] + options.map {
            "--" + $0.name + ($0.value.map { " " + quote($0) } ?? "")
        }
        return parts.joined(separator: " \\\n  ")
    }

    func validatedForSending() throws -> Self {
        try CurlDocument.parseCurl(curlText, variables: [:], expands: false)
    }
}

public struct CurlDocument: Sendable {
    public static let maximumBytes = 256 * 1024
    public struct Block: Identifiable, Sendable {
        public let id: Int
        public let range: NSRange
        public let title: String
        public let request: CurlRequest?
        public let error: String?
    }
    public let blocks: [Block]
    public let error: String?

    /// Request delimiters and file variables follow REST Client conventions.
    public init(_ text: String) {
        guard text.utf8.count <= Self.maximumBytes else {
            blocks = []; error = "编辑区最多支持 256 KiB 的文本。"; return
        }
        let source = text as NSString
        let separator = try! NSRegularExpression(pattern: #"(?m)^\h*#{3,}(?:\h[^\r\n]*)?\h*(?:\r?\n|$)"#)
        let delimiters = separator.matches(in: text, range: NSRange(location: 0, length: source.length))
        var pieces: [(NSRange, String, [String])] = []
        var variables: [String: String] = [:]
        var start = 0, title = ""
        let declaration = try! NSRegularExpression(pattern: #"^@([a-zA-Z_][\w.-]*)\h*=\h*(.*)$"#)
        for delimiter in delimiters.map(\.range) + [NSRange(location: source.length, length: 0)] {
            let range = NSRange(location: start, length: delimiter.location - start)
            var lines = source.substring(with: range).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
            // Recognize declarations and comments only before the request.
            while let first = lines.first {
                let line = first.trimmingCharacters(in: .whitespaces)
                let string = line as NSString
                if let match = declaration.firstMatch(in: line, range: NSRange(location: 0, length: string.length)) {
                    variables[string.substring(with: match.range(at: 1))] = string.substring(with: match.range(at: 2))
                } else if line.hasPrefix("# @name ") {
                    if title.isEmpty { title = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
                } else if !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("//") {
                    break
                }
                lines.removeFirst()
            }
            if lines.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                pieces.append((range, title, Array(lines)))
            }
            if pieces.count > 100 {
                blocks = []; error = "一个项目最多保存 100 段请求。"; return
            }
            title = source.substring(with: delimiter).trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
            start = NSMaxRange(delimiter)
        }
        error = nil
        blocks = pieces.enumerated().map { index, piece in
            do {
                var lines = piece.2
                while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
                if lines.first?.hasPrefix("```") == true, lines.last == "```", lines.count > 2 {
                    lines.removeFirst(); lines.removeLast()
                }
                let first = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
                let request: CurlRequest
                if first.lowercased().hasPrefix("curl ") || first.lowercased().hasPrefix("curl\t") || first.lowercased() == "curl" {
                    request = try Self.parseCurl(lines.joined(separator: "\n"), variables: variables)
                } else {
                    request = try Self.parseHTTP(lines, variables: variables)
                }
                return Block(id: index, range: piece.0, title: piece.1, request: request, error: nil)
            } catch {
                return Block(id: index, range: piece.0, title: piece.1, request: nil, error: error.localizedDescription)
            }
        }
    }

    public func block(at caret: Int) -> Block? {
        blocks.last { $0.range.location <= caret } ?? blocks.first
    }

    private static func substitute(_ value: String, variables: [String: String], visited: Set<String> = []) throws -> String {
        let pattern = try! NSRegularExpression(pattern: #"\{\{\h*([A-Za-z_][\w.-]*)\h*\}\}"#)
        var cache: [String: String] = [:], budget = 4096
        func expand(_ value: String, visited: Set<String>) throws -> String {
            let source = value as NSString
            let result = NSMutableString(string: value)
            for match in pattern.matches(in: value, range: NSRange(location: 0, length: source.length)).reversed() {
                budget -= 1
                let name = source.substring(with: match.range(at: 1))
                guard let replacement = variables[name] else { throw RunbarError.message("未定义变量 {{\(name)}}。") }
                guard visited.count < 12, !visited.contains(name), budget >= 0 else {
                    throw RunbarError.message("变量 {{\(name)}} 存在循环引用或引用次数过多。")
                }
                let resolved: String
                if let existing = cache[name] { resolved = existing }
                else { resolved = try expand(replacement, visited: visited.union([name])); cache[name] = resolved }
                guard result.length - match.range.length + resolved.utf16.count <= maximumBytes else {
                    throw RunbarError.message("展开变量后的请求过长。")
                }
                result.replaceCharacters(in: match.range, with: resolved)
            }
            return String(result)
        }
        return try expand(value, visited: visited)
    }

    static func httpURL(_ raw: String) throws -> URL {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty,
              !host.contains("%"), parts.user == nil, parts.password == nil, let url = parts.url else {
            throw RunbarError.message("请填写完整的 HTTP 或 HTTPS URL；认证请使用请求头或 -u。")
        }
        return url
    }

    private static func parseHTTP(_ lines: [String], variables: [String: String]) throws -> CurlRequest {
        let parts = lines[0].split(whereSeparator: \.isWhitespace)
        let method: String, rawURL: String
        if parts.count == 1 {
            method = "GET"; rawURL = String(parts[0])
        } else if parts.count == 2 || (parts.count == 3 && parts[2] == "HTTP/1.1") {
            method = String(parts[0]); rawURL = String(parts[1])
        } else {
            throw RunbarError.message("请输入 cURL，或使用 GET / POST 加完整 URL 的请求行。")
        }
        try validateMethod(method)
        let url = try httpURL(substitute(rawURL, variables: variables))
        var options: [CurlRequest.Option] = method == "HEAD" ? [.init("head")] : [.init("request", method)]
        var index = 1
        while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            let header = try substitute(lines[index], variables: variables)
            if !header.hasPrefix("#") {
                try validateHeader(header)
                options.append(.init("header", header))
            }
            index += 1
        }
        let body = try substitute(lines.dropFirst(index + 1).joined(separator: "\n"), variables: variables)
        if !body.isEmpty {
            guard method != "HEAD" else { throw RunbarError.message("HEAD 请求不能附带正文。") }
            options.append(.init("data-raw", body))
        }
        return try makeRequest(method: method, url: url, options: options)
    }

    private static let shortValues: [String: String] = [
        "X":"request", "H":"header", "d":"data", "u":"user", "b":"cookie", "A":"user-agent", "e":"referer",
        "F":"form", "m":"max-time", "x":"proxy"
    ]
    private static let shortFlags: [String: String] = [
        "G":"get", "I":"head", "L":"location", "k":"insecure", "s":"silent", "S":"show-error", "g":"globoff",
        "i":"include", "f":"fail", "v":"verbose", "q":"disable", "N":"no-buffer", "4":"ipv4", "6":"ipv6"
    ]
    private static let values: Set<String> = [
        "request", "header", "data", "data-ascii", "data-raw", "data-binary", "data-urlencode", "json",
        "user", "oauth2-bearer", "cookie", "user-agent", "referer", "form", "form-string", "proxy",
        "max-time", "connect-timeout", "url", "url-query"
    ]
    private static let flags: Set<String> = [
        "get", "head", "location", "insecure", "compressed", "http1.1", "http1.0", "http2", "ipv4", "ipv6",
        "basic", "digest", "anyauth", "path-as-is"
    ]
    private static let displayFlags: Set<String> = [
        "silent", "show-error", "globoff", "include", "fail", "fail-with-body", "verbose", "disable", "no-buffer", "no-progress-meter"
    ]

    fileprivate static func parseCurl(_ text: String, variables: [String: String], expands: Bool = true) throws -> CurlRequest {
        let words = try CurlWords.split(text)
        guard words.first?.lowercased() == "curl" else { throw RunbarError.message("每段请求请以 curl 开头。") }
        var index = 1, options: [CurlRequest.Option] = [], url: URL?, explicit: String?
        var head = false, get = false, hasData = false, positional = false
        func appendURL(_ value: String) throws {
            guard url == nil else { throw RunbarError.message("每段只能发送一个 URL。多个请求请用 ### 分隔。") }
            url = try httpURL(value)
        }
        func resolve(_ value: String) throws -> String { expands ? try substitute(value, variables: variables) : value }
        func apply(_ name: String, _ value: String? = nil) throws {
            if let value {
                guard !value.contains("\0") else { throw RunbarError.message("请求中不能包含 NUL 字符。") }
                switch name {
                case "url": try appendURL(value); return
                case "request": try validateMethod(value); explicit = value
                case "header": try validateHeader(value)
                case "data", "data-ascii", "data-binary", "json":
                    guard !value.hasPrefix("@") else { throw localFile }
                    hasData = true
                case "data-raw": hasData = true
                case "data-urlencode", "url-query":
                    guard value.contains("=") && (value.firstIndex(of: "=") ?? value.endIndex) < (value.firstIndex(of: "@") ?? value.endIndex) ||
                            !value.contains("@") || (name == "url-query" && value.hasPrefix("+")) else { throw localFile }
                    if name == "data-urlencode" { hasData = true }
                case "form", "form-string":
                    let fields = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard fields.count == 2, !fields[0].isEmpty else { throw RunbarError.message("表单项应写成 name=value。") }
                    if name == "form" {
                        // The regular form grammar recognizes local files in
                        // several positions. Use literal form fields here.
                        let form = fields[1].trimmingCharacters(in: .whitespaces)
                        guard !form.hasPrefix("@"), !form.hasPrefix("<"), !form.contains(";") else { throw localFile }
                    }
                    options.append(.init("form-string", value)); hasData = true; return
                case "cookie": guard value.contains("=") else { throw localFile }
                case "user": guard value.contains(":") else { throw RunbarError.message("-u 请使用 用户名:密码 形式。") }
                case "max-time", "connect-timeout":
                    guard let seconds = Double(value), seconds.isFinite, seconds > 0, seconds <= 120 else {
                        throw RunbarError.message("--\(name) 须在 0 到 120 秒之间。")
                    }
                    options.append(.init(name, String(seconds))); return
                case "proxy":
                    if !value.isEmpty { _ = try httpURL(value) }
                default: break
                }
                if !["data", "data-ascii", "data-raw", "data-binary", "json", "data-urlencode"].contains(name),
                    value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" }) {
                    throw RunbarError.message("--\(name) 包含无效的控制字符。")
                }
                options.append(.init(name, value))
            } else if flags.contains(name) {
                if name == "get" { get = true }
                if name == "head" { head = true }
                options.append(.init(name))
            } else if !displayFlags.contains(name) {
                throw RunbarError.message("暂不支持 cURL 选项 --\(name)。")
            }
        }
        func argument(_ name: String, attached: String?) throws -> String {
            if let attached { return try resolve(attached) }
            guard index < words.count else { throw RunbarError.message("--\(name) 缺少值。") }
            defer { index += 1 }
            return try resolve(words[index])
        }
        while index < words.count {
            let word = words[index]; index += 1
            if word == "--", !positional { positional = true }
            else if word.hasPrefix("--"), !positional {
                let option = word.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(option[0])
                if values.contains(name) { try apply(name, argument(name, attached: option.count == 2 ? String(option[1]) : nil)) }
                else if option.count == 1 { try apply(name) }
                else { throw RunbarError.message("不支持带值的选项 --\(name)。") }
            } else if word.hasPrefix("-"), !positional {
                var shorts = word.dropFirst()
                guard !shorts.isEmpty else { throw RunbarError.message("无效的 cURL 选项。") }
                while let short = shorts.popFirst() {
                    let key = String(short)
                    if let name = shortValues[key] {
                        try apply(name, argument(name, attached: shorts.isEmpty ? nil : String(shorts)))
                        break
                    }
                    guard let name = shortFlags[key] else { throw RunbarError.message("暂不支持 cURL 选项 -\(key)。") }
                    try apply(name)
                }
            } else {
                try appendURL(resolve(word))
            }
        }
        guard let url else { throw RunbarError.message("在 cURL 中补上完整的 HTTP 或 HTTPS URL。") }
        let method = explicit ?? (head ? "HEAD" : get ? "GET" : hasData ? "POST" : "GET")
        return try makeRequest(method: method, url: url, options: options)
    }

    private static var localFile: RunbarError { .message("请求编辑区支持内联正文和表单字段；此写法会读取本地文件，暂不支持。") }

    private static func makeRequest(method: String, url: URL, options: [CurlRequest.Option]) throws -> CurlRequest {
        let request = CurlRequest(method: method, url: url, options: options)
        guard options.count <= 128, !options.contains(where: { $0.value?.contains("\0") == true }),
              request.curlText.utf8.count <= maximumBytes else {
            throw RunbarError.message("请求最多支持 128 个选项和 256 KiB 文本，且不能包含 NUL 字符。")
        }
        return request
    }
    private static func validateMethod(_ method: String) throws {
        guard !method.isEmpty, method.utf8.count <= 32, method.utf8.allSatisfy({ (65...90).contains($0) || $0 == 45 }) else {
            throw RunbarError.message("请求方法应为大写 HTTP 方法，例如 GET 或 POST。")
        }
    }
    private static func validateHeader(_ header: String) throws {
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^`_|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let name = header.prefix { $0 != ":" && $0 != ";" }
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(token.contains),
              header.dropFirst(name.count).hasPrefix(":") || header.dropFirst(name.count) == ";",
              !header.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" }) else {
            throw RunbarError.message("请求头应写成「名称: 值」，不能使用文件或换行。")
        }
    }
}

private enum CurlWords {
    static func split(_ text: String) throws -> [String] {
        let chars = Array(text.unicodeScalars)
        var i = 0, token = [UInt8](), result: [String] = [], started = false
        func take() -> Unicode.Scalar? {
            guard i < chars.count else { return nil }
            defer { i += 1 }
            return chars[i]
        }
        func append(_ ch: Unicode.Scalar) { token.append(contentsOf: String(ch).utf8) }
        func flush() throws {
            guard started else { return }
            guard let value = String(bytes: token, encoding: .utf8), !value.contains("\0") else {
                throw RunbarError.message("cURL 参数必须是 UTF-8 文本，且不能含 NUL 字符。")
            }
            result.append(value); token.removeAll(keepingCapacity: true); started = false
        }
        func ansiEscape() throws {
            guard let ch = take() else { throw malformed }
            switch ch {
            case "n": token.append(10)
            case "r": token.append(13)
            case "t": token.append(9)
            case "b": token.append(8)
            case "v": token.append(11)
            case "f": token.append(12)
            case "a": token.append(7)
            case "e", "E": token.append(27)
            case "\\", "'", "\"": append(ch)
            case "x", "u", "U", "0"..."7":
                let octal = ("0"..."7").contains(ch), hex = ch == "x"
                let count = octal ? 3 : hex ? 2 : ch == "u" ? 4 : 8
                let radix = octal ? 8 : 16
                var digits = octal ? String(ch) : ""
                while digits.count < count, i < chars.count, Int(String(chars[i]), radix: radix) != nil {
                    digits.unicodeScalars.append(chars[i]); i += 1
                }
                guard let number = UInt32(digits, radix: radix) else { throw malformed }
                if octal || hex { token.append(UInt8(truncatingIfNeeded: number)) }
                else if let scalar = Unicode.Scalar(number) { append(scalar) }
                else { throw malformed }
            default: append("\\"); append(ch)
            }
        }
        func quoted(_ quote: Unicode.Scalar, ansi: Bool = false) throws {
            while let ch = take() {
                if ch == quote { return }
                if ch == "\\", ansi { try ansiEscape(); continue }
                if quote == "\"" {
                    if ch == "$" || ch == "`" { throw shell }
                    if ch == "\\" {
                        guard let next = take() else { throw malformed }
                        if next == "\n" { continue }
                        if !["$", "`", "\"", "\\"].contains(next) { append("\\") }
                        append(next); continue
                    }
                }
                append(ch)
            }
            throw malformed
        }
        while let ch = take() {
            switch ch {
            case " ", "\t", "\n", "\r": try flush()
            case "#":
                if started { append(ch) }
                else { while i < chars.count && chars[i] != "\n" { i += 1 } }
            case "\\":
                guard let next = take() else { throw malformed }
                if next != "\n" { started = true; append(next) }
            case "'", "\"": started = true; try quoted(ch)
            case "$" where i < chars.count && chars[i] == "'":
                i += 1; started = true; try quoted("'", ansi: true)
            case "$", "`", ";", "&", "|", "<", ">", "(", ")": throw shell
            default: started = true; append(ch)
            }
        }
        try flush()
        return result
    }

    private static var malformed: RunbarError { .message("cURL 的引号、转义或续行还没有写完整。") }
    private static var shell: RunbarError { .message("此处只发送 HTTP 请求，不执行 Shell。请引用含特殊字符的参数，变量可用 {{名称}}。") }
}
