import Foundation

public struct ProxyWebSocketTarget: Codable, Identifiable, Sendable {
    public let id: String
    public let url: String
}

/// Commands are scoped to the private capture directory of one running session.
public enum ProxyWebSocketSender {
    public static func connections(directory: URL) throws -> [ProxyWebSocketTarget] {
        let status = try JSONDecoder().decode(ProxyCaptureStatus.self,
            from: Data(contentsOf: directory.appendingPathComponent("status.json")))
        guard status.running else { return [] }
        return try JSONDecoder().decode([ProxyWebSocketTarget].self,
            from: Data(contentsOf: directory.appendingPathComponent("control/connections.json")))
    }

    public static func send(directory: URL, flowID: String, text: String) async throws {
        guard !text.isEmpty, text.utf8.count <= 1024 * 1024 else {
            throw RunbarError.message("请输入不超过 1 MB 的消息")
        }
        guard try connections(directory: directory).contains(where: { $0.id == flowID }) else {
            throw RunbarError.message("连接已断开，请重新选择")
        }
        let base = directory.appendingPathComponent("control/\(UUID().uuidString)")
        let request = base.appendingPathExtension("request"), response = base.appendingPathExtension("response")
        let command: [String: Any] = ["flowID": flowID, "text": text, "expires": Date().timeIntervalSince1970 + 3]
        try JSONSerialization.data(withJSONObject: command).write(to: request, options: .atomic)
        defer { try? FileManager.default.removeItem(at: request); try? FileManager.default.removeItem(at: response) }
        for _ in 0..<50 {
            if let data = try? Data(contentsOf: response) {
                struct Reply: Decodable { let error: String? }
                let reply = try JSONDecoder().decode(Reply.self, from: data)
                if let error = reply.error { throw RunbarError.message(error) }
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RunbarError.message("代理未确认发送结果，请检查连接和消息列表后再重试")
    }
}
