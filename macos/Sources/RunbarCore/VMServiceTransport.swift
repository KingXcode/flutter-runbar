import Foundation

public enum VMServiceError: Error, LocalizedError, Equatable {
    case responseTooLarge, unavailable, authenticationRequired, unsupported, invalidResponse, cancelled
    public var errorDescription: String? {
        switch self {
        case .responseTooLarge: return "VM Service 单次返回超过大小限制，已停止接收。"
        case .unavailable: return "VM Service 暂时无法连接。"
        case .authenticationRequired: return "VM Service 需要包含认证码的完整调试地址。"
        case .unsupported: return "当前进程没有提供 HTTP 采集扩展。"
        case .invalidResponse: return "VM Service 返回的数据格式不受支持。"
        case .cancelled: return "采集已暂停。"
        }
    }
}
public protocol VMServiceTransport: Sendable {
    func call(endpoint: VMServiceEndpoint, method: String, parameters: [String: String]) async throws -> Data
    func serviceRedirect(endpoint: VMServiceEndpoint) async throws -> VMServiceEndpoint?
}
public extension VMServiceTransport {
    func serviceRedirect(endpoint: VMServiceEndpoint) async throws -> VMServiceEndpoint? { nil }
}
public struct HTTPVMServiceTransport: VMServiceTransport {
    private let limit: Int
    public init(limit: Int = NetworkLimits().responseBytes) { self.limit = limit }
    public func call(endpoint: VMServiceEndpoint, method: String, parameters: [String: String]) async throws -> Data {
        guard method.allSatisfy({ $0.isLetter || $0 == "." || $0 == "_" }), !method.isEmpty,
              var parts = URLComponents(url: endpoint.url.appendingPathComponent(method), resolvingAgainstBaseURL: false) else { throw VMServiceError.invalidResponse }
        parts.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw VMServiceError.invalidResponse }
        let call = BoundedVMCall(limit: limit, checkAuthentication: method == "getVM")
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await call.run(url)
        }, onCancel: { call.cancel() })
    }
    /// Read the VM's DevTools redirect header only. Never follow it implicitly:
    /// parse a loopback VM URI and let the caller verify the target PID again.
    public func serviceRedirect(endpoint: VMServiceEndpoint) async throws -> VMServiceEndpoint? {
        let call = BoundedVMCall(limit: 0, captureRedirect: true)
        let data = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await call.run(endpoint.url.appendingPathComponent("index.html"))
        }, onCancel: { call.cancel() })
        guard !data.isEmpty, let location = String(data: data, encoding: .utf8),
              let target = VMServiceEndpoint(location),
              endpoint.url.scheme != "https" || target.url.scheme == "https" else { return nil }
        return target
    }
}

/// Delegate streaming checks the wire size before JSON decoding. No unbounded
/// data(for:) allocation, redirects, shared cookies, response cache, or URL errors
/// containing the authenticated endpoint can reach the UI.
private final class BoundedVMCall: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let captureRedirect: Bool
    private let checkAuthentication: Bool
    private var forbidden = false
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    init(limit: Int, captureRedirect: Bool = false, checkAuthentication: Bool = false) {
        self.limit = limit
        self.captureRedirect = captureRedirect
        self.checkAuthentication = checkAuthentication
    }
    func run(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 3; configuration.timeoutIntervalForResource = 5
            configuration.connectionProxyDictionary = [:]
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            let task = session.dataTask(with: url); self.task = task
            lock.unlock(); task.resume()
        }
    }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil
        let session = session; self.session = nil; task = nil; buffer = Data(); lock.unlock()
        continuation?.resume(with: result); session?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        if captureRedirect { finish(.success(redirectHeader(response))) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if captureRedirect {
            completionHandler(.cancel)
            finish(.success((response as? HTTPURLResponse).map(redirectHeader) ?? Data()))
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode
        forbidden = checkAuthentication && status == 403
        guard status == 200 || forbidden else {
            completionHandler(.cancel); finish(.failure(VMServiceError.unavailable)); return
        }
        guard response.expectedContentLength <= Int64(forbidden ? 4096 : limit) else {
            completionHandler(.cancel); finish(.failure(VMServiceError.responseTooLarge)); return
        }
        completionHandler(.allow)
    }
    private func redirectHeader(_ response: HTTPURLResponse) -> Data {
        guard [301, 302, 303, 307, 308].contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"), location.utf8.count <= 16_384 else { return Data() }
        return Data(location.utf8)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        let responseLimit = forbidden ? 4096 : limit
        guard buffer.count <= responseLimit - data.count else { lock.unlock(); finish(.failure(VMServiceError.responseTooLarge)); return }
        buffer.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let cancelled = cancelled; let data = buffer; lock.unlock()
        if cancelled { finish(.failure(CancellationError())) }
        else if error != nil { finish(.failure(VMServiceError.unavailable)) }
        else if forbidden {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            finish(.failure(text == "missing or invalid authentication code" ? VMServiceError.authenticationRequired : VMServiceError.unavailable))
        }
        else { finish(.success(data)) }
    }
}
