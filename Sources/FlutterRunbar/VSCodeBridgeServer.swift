import Foundation
import Network
import RunbarCore

struct VSCodeDebugTarget {
    let projectPath: String
    let projectName: String
    let sessionID: UUID
    let endpoint: VMServiceEndpoint
}

/// An ephemeral, capability-protected handoff. VM credentials never appear in
/// an OS URL, launch.json, extension settings, or the cross-window pending file.
@MainActor
final class VSCodeBridgeServer {
    private var listener: NWListener?
    private var startup: CheckedContinuation<UInt16, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var ticket: String?
    private var expiresAt = Date.distantPast
    private var claimID: String?
    private var target: (() throws -> VSCodeDebugTarget)?
    private var completion: ((String?) -> Void)?
    private var expiryTask: Task<Void, Never>?
    private var generation = UUID()

    func link(target: @escaping () throws -> VSCodeDebugTarget, completion: @escaping (String?) -> Void) async throws -> URL {
        close()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        let port = try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        let continuation = self.startup; self.startup = nil
                        if let port = listener?.port { continuation?.resume(returning: port.rawValue) }
                        else { continuation?.resume(throwing: RunbarError.message("无法创建 VS Code 本机连接。")) }
                    case .failed, .cancelled:
                        self.startup?.resume(throwing: RunbarError.message("VS Code 本机连接不可用，请重试。")); self.startup = nil
                        self.finish("VS Code 本机连接已关闭，请重新连接。")
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
        guard self.listener === listener else { throw CancellationError() }
        _ = try target()
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        ticket = token; expiresAt = Date().addingTimeInterval(180)
        self.target = target; self.completion = completion
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            self?.finish("VS Code 尚未响应。请确认已启用 Runbar Bridge、允许打开连接链接，并已信任项目目录，再重试。")
        }
        var parts = URLComponents()
        parts.scheme = "vscode"; parts.host = "kingxcode.runbar-bridge"; parts.path = "/attach"
        parts.queryItems = [URLQueryItem(name: "port", value: String(port)), URLQueryItem(name: "token", value: token)]
        return parts.url!
    }

    func close() {
        generation = UUID()
        expiryTask?.cancel(); expiryTask = nil
        let pending = startup; startup = nil; pending?.resume(throwing: CancellationError())
        listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll(); ticket = nil; target = nil; claimID = nil; completion = nil
    }

    private func finish(_ message: String?) {
        let generation = generation
        let callback = completion
        // Let a result response finish before shutting down its TCP connection.
        completion = nil; ticket = nil; target = nil; expiryTask?.cancel(); expiryTask = nil
        callback?(message)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, self.ticket == nil, self.generation == generation else { return }
            self.close()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8, ticket != nil else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: .main)
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(5))
            if let connection { self?.end(id, connection) }
        }
        receive(connection, id: id, buffer: Data())
    }
    private func end(_ id: UUID, _ connection: NWConnection) {
        connections[id] = nil; connection.cancel()
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var bytes = buffer; if let data { bytes.append(data) }
                guard bytes.count <= 8192, error == nil else { self.end(id, connection); return }
                if let range = bytes.range(of: Data("\r\n\r\n".utf8)),
                   let header = String(data: bytes[..<range.lowerBound], encoding: .utf8) {
                    let rows = header.components(separatedBy: "\r\n")
                    let fields = rows.dropFirst().compactMap { row -> (String, String)? in
                        guard let colon = row.firstIndex(of: ":") else { return nil }
                        return (row[..<colon].lowercased(), row[row.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                    }
                    let lengths = fields.filter { $0.0 == "content-length" }
                    guard lengths.count <= 1, !fields.contains(where: { ["origin", "transfer-encoding"].contains($0.0) }),
                          let length = Int(lengths.first?.1 ?? "0"), (0...2048).contains(length) else { self.end(id, connection); return }
                    let body = Data(bytes[range.upperBound...])
                    if body.count >= length {
                        let (status, object) = self.response(request: rows.first ?? "", body: Data(body.prefix(length)))
                        let payload = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
                        var reply = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Unavailable")\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
                        reply.append(payload)
                        connection.send(content: reply, completion: .contentProcessed { [weak self] _ in
                            Task { @MainActor in self?.end(id, connection) }
                        })
                        return
                    }
                }
                guard !complete else { self.end(id, connection); return }
                self.receive(connection, id: id, buffer: bytes)
            }
        }
    }
    private func response(request: String, body: Data) -> (Int, [String: Any]) {
        let parts = request.split(separator: " ")
        guard parts.count == 3, let token = ticket, expiresAt > Date(), let target,
              let action = String(parts[1]).split(separator: "/").last,
              String(parts[1]) == "/v1/\(token)/\(action)" else { return (404, [:]) }
        guard let current = try? target() else {
            finish("这次 Flutter 运行已结束或发生变化，请在当前 Debug 运行中重新连接。")
            return (410, [:])
        }
        var context: [String: Any] = ["version": 1, "projectPath": current.projectPath, "projectName": current.projectName,
                                      "sessionID": current.sessionID.uuidString, "expiresAt": expiresAt.timeIntervalSince1970 * 1000]
        switch (parts[0], action) {
        case ("GET", "context"): return (200, context)
        case ("POST", "claim"):
            guard claimID == nil, let value = try? JSONSerialization.jsonObject(with: body) as? [String: String],
                  let id = value["claimID"], id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { return (409, [:]) }
            claimID = id; context["vmServiceUri"] = current.endpoint.url.absoluteString
            return (200, context)
        case ("POST", "result"):
            guard let value = try? JSONSerialization.jsonObject(with: body) as? [String: String],
                  claimID == nil || value["claimID"] == claimID else { return (409, [:]) }
            if value["status"] == "attached", claimID != nil { finish(nil) }
            else if value["status"] == "failed" { finish(Self.message(for: value["reason"])) }
            else { return (400, [:]) }
            return (200, ["ok": true])
        default: return (404, [:])
        }
    }
    private static func message(for reason: String?) -> String {
        switch reason {
        case "workspace-untrusted": return "请在 VS Code 中信任此项目目录，再点击连接。Runbar 不会自动授予工作区信任。"
        case "dart-extension-missing": return "请在 VS Code 中安装并启用官方 Dart 和 Flutter 扩展，再重试。"
        case "dart-extension-outdated": return "请将官方 Dart 扩展更新到 3.144.0 或更新版本。若刚更新过，请在 VS Code 中执行「开发人员: 重新加载窗口」后再重试。"
        case "local-mac-only": return "请使用本机 macOS 的 VS Code 窗口；当前不支持远程工作区。"
        default: return "未能附加调试。请确认这次 Debug 运行仍在进行，并查看 VS Code 中的调试错误，再重试。"
        }
    }
}
