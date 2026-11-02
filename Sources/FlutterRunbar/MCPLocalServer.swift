import Foundation
import Network
import RunbarCore

@MainActor
final class MCPLocalServer {
    private final class Client {
        let connection: NWConnection
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var sent = false
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private var listener: NWListener?
    private var startup: CheckedContinuation<Void, Error>?
    private var clients: [UUID: Client] = [:]
    private var port: UInt16 = 0
    private var token = ""
    private var handler: (@Sendable (String, Data) async throws -> Data)?
    private var onTool: ((String) -> Void)?
    private var onFailure: ((String) -> Void)?
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.10.1"

    func start(port: UInt16, token: String, handler: @escaping @Sendable (String, Data) async throws -> Data,
               onTool: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) async throws {
        stop()
        self.port = port; self.token = token; self.handler = handler; self.onTool = onTool; self.onFailure = onFailure
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, self.listener === listener else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        let pending = self.startup; self.startup = nil; pending?.resume()
                    case .failed(let error):
                        let message = "MCP 端口 \(port) 无法启动或已关闭：\(error.localizedDescription)。若端口被占用，请修改端口重试。"
                        let pending = self.startup; self.startup = nil
                        let failure = self.onFailure; self.stop()
                        pending?.resume(throwing: RunbarError.message(message)); failure?(message)
                    case .cancelled:
                        self.stop()
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }
    func stop() {
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        let pending = startup; startup = nil; pending?.resume(throwing: CancellationError())
        for client in clients.values { client.timer?.cancel(); client.work?.cancel(); client.connection.cancel() }
        clients.removeAll(); token = ""; handler = nil; onTool = nil; onFailure = nil
    }
    private func accept(_ connection: NWConnection) {
        guard clients.count < 8, listener != nil else { connection.cancel(); return }
        let id = UUID(), client = Client(connection); clients[id] = client
        connection.start(queue: .main)
        client.timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.sendError(408, "Request timeout", id: id)
        }
        receive(id: id, buffer: Data())
    }
    private func end(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timer?.cancel(); client.work?.cancel(); client.connection.cancel()
    }
    private func receive(id: UUID, buffer: Data) {
        guard let client = clients[id] else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, let client = self.clients[id], !client.sent else { return }
                guard error == nil else { self.end(id); return }
                var buffer = buffer; if let data { buffer.append(data) }
                do {
                    if let request = try RunbarMCPHTTP.request(buffer, port: self.port, token: self.token), let handler = self.handler {
                        client.timer?.cancel()
                        client.timer = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(40)) } catch { return }
                            self?.clients[id]?.work?.cancel(); self?.sendError(503, "Query deadline exceeded; use smaller pages", id: id)
                        }
                        let version = self.version
                        client.work = Task { [weak self] in
                            let reply = await RunbarMCPProtocol.respond(to: request.body, protocolVersion: request.protocolVersion, serverVersion: version) { [weak self] name, arguments in
                                await self?.record(name)
                                return try await handler(name, arguments)
                            }
                            guard !Task.isCancelled else { return }
                            self?.send(reply, id: id)
                        }
                        return
                    }
                } catch let error as RunbarMCPHTTPError { self.sendError(error.status, error.message, id: id); return }
                catch { self.sendError(400, "Invalid request", id: id); return }
                guard !complete else { self.sendError(400, "Incomplete request", id: id); return }
                self.receive(id: id, buffer: buffer)
            }
        }
    }
    private func record(_ name: String) { onTool?(name) }
    private func sendError(_ status: Int, _ message: String, id: UUID) {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        send(RunbarMCPReply(status: status, body: body), id: id)
    }
    private func send(_ reply: RunbarMCPReply, id: UUID) {
        guard let client = clients[id], !client.sent else { return }
        client.sent = true
        client.timer?.cancel()
        // A blocked receiver cannot hold a response buffer or slot indefinitely.
        client.timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.end(id)
        }
        client.connection.send(content: RunbarMCPHTTP.response(reply), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.end(id) }
        })
    }
}
