import Foundation

public struct RunbarMCPHTTPError: Error {
    public let status: Int
    public let message: String
    public init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}
public struct RunbarMCPHTTPRequest: Sendable {
    public let method: String
    public let body: Data
    public let protocolVersion: String?
}

/// A single, bounded HTTP/1.1 exchange. Host, Origin and bearer authentication
/// are validated before any RPC or filesystem work is dispatched.
public enum RunbarMCPHTTP {
    public static let frameLimit = 128 * 1024
    public static func request(_ data: Data, port: UInt16, token: String) throws -> RunbarMCPHTTPRequest? {
        guard data.count <= frameLimit else { throw RunbarMCPHTTPError(413, "Request too large") }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 8192 else { throw RunbarMCPHTTPError(431, "Headers too large") }; return nil
        }
        guard boundary.lowerBound <= 8192, let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { throw RunbarMCPHTTPError(400, "Invalid headers") }
        let lines = header.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1", lines.count <= 100 else { throw RunbarMCPHTTPError(400, "Invalid HTTP request") }
        guard first[1] == "/mcp" else { throw RunbarMCPHTTPError(404, "Not found") }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw RunbarMCPHTTPError(400, "Invalid header") }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), fields[name] == nil else { throw RunbarMCPHTTPError(400, "Duplicate or invalid header") }
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = fields["host"]?.lowercased(), hosts.contains(host) else { throw RunbarMCPHTTPError(403, "Invalid Host") }
        if let origin = fields["origin"], !hosts.map({ "http://" + $0 }).contains(origin.lowercased()) { throw RunbarMCPHTTPError(403, "Invalid Origin") }
        guard let authorization = fields["authorization"], authorization.prefix(7).lowercased() == "bearer ",
              equalToken(String(authorization.dropFirst(7)), token) else { throw RunbarMCPHTTPError(401, "Bearer token required") }
        let method = String(first[0])
        guard method == "POST" else { throw RunbarMCPHTTPError(405, "Only POST is supported; no SSE stream or persistent sessions") }
        guard fields["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw RunbarMCPHTTPError(415, "Use application/json") }
        let accept = fields["accept"]?.lowercased() ?? ""
        guard accept.contains("application/json") || accept.contains("*/*") else { throw RunbarMCPHTTPError(406, "Accept application/json and text/event-stream") }
        let input = Data(data[boundary.upperBound...]), body: Data
        if let transfer = fields["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", fields["content-length"] == nil else { throw RunbarMCPHTTPError(400, "Ambiguous transfer encoding") }
            guard let decoded = try decodeChunks(input) else { return nil }; body = decoded
        } else {
            guard let raw = fields["content-length"], !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(raw), length <= RunbarMCPProtocol.requestLimit else { throw RunbarMCPHTTPError(413, "A bounded Content-Length is required") }
            guard input.count >= length else { return nil }
            guard input.count == length else { throw RunbarMCPHTTPError(400, "Unexpected trailing request data") }
            body = input
        }
        return RunbarMCPHTTPRequest(method: method, body: body, protocolVersion: fields["mcp-protocol-version"])
    }
    private static func equalToken(_ input: String, _ expected: String) -> Bool {
        let a = Array(input.utf8), b = Array(expected.utf8)
        guard !b.isEmpty, a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private static func decodeChunks(_ data: Data) throws -> Data? {
        var offset = 0, result = Data(), count = 0
        while offset < data.count {
            count += 1
            guard count <= 1024 else { throw RunbarMCPHTTPError(413, "Too many chunks") }
            guard let line = data.range(of: Data("\r\n".utf8), in: offset..<data.count) else { return nil }
            guard line.lowerBound - offset <= 128, let text = String(data: data[offset..<line.lowerBound], encoding: .ascii),
                  let raw = text.split(separator: ";", omittingEmptySubsequences: false).first, !raw.isEmpty,
                  raw.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let size = Int(raw, radix: 16), size <= RunbarMCPProtocol.requestLimit - result.count else { throw RunbarMCPHTTPError(413, "Invalid or oversized chunk") }
            offset = line.upperBound
            guard data.count - offset >= size + 2 else { return nil }
            if size == 0 {
                guard data[offset..<offset + 2] == Data("\r\n".utf8), data.count == offset + 2 else { throw RunbarMCPHTTPError(400, "Trailers are not supported") }
                return result
            }
            guard data[offset + size..<offset + size + 2] == Data("\r\n".utf8) else { throw RunbarMCPHTTPError(400, "Invalid chunk boundary") }
            result.append(data[offset..<offset + size]); offset += size + 2
        }
        return nil
    }
    public static func response(_ reply: RunbarMCPReply) -> Data {
        let phrases = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 413: "Content Too Large", 415: "Unsupported Media Type", 429: "Too Many Requests", 431: "Request Header Fields Too Large", 503: "Service Unavailable"]
        var headers = "HTTP/1.1 \(reply.status) \(phrases[reply.status] ?? "Error")\r\nContent-Length: \(reply.body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if !reply.body.isEmpty { headers += "Content-Type: application/json\r\n" }
        if reply.status == 401 { headers += "WWW-Authenticate: Bearer realm=\"Runbar MCP\"\r\n" }
        if reply.status == 405 { headers += "Allow: POST\r\n" }
        if reply.status == 429 { headers += "Retry-After: 1\r\n" }
        return Data((headers + "\r\n").utf8) + reply.body
    }
}
