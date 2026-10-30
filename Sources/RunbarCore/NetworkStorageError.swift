import Foundation
import CSQLite

/// Preserve SQLite's real result codes before rollback/finalization can replace
/// them. Never include SQL parameters, request payloads or VM authentication.
public struct NetworkStorageError: LocalizedError, Sendable {
    public let code: Int32?
    public let extendedCode: Int32?
    public let operation: String
    public let detail: String
    public var isTransient: Bool { code == nil || code == SQLITE_BUSY || code == SQLITE_LOCKED }

    init(code: Int32?, extendedCode: Int32?, operation: String, detail: String) {
        self.code = code; self.extendedCode = extendedCode; self.operation = operation
        self.detail = String(detail.prefix(400))
    }
    static var accessTimeout: Self {
        Self(code: nil, extendedCode: nil, operation: "等待缓存读写", detail: "同一缓存的其他操作尚未完成")
    }
    public var errorDescription: String? {
        let message: String
        switch code {
        case nil, SQLITE_BUSY, SQLITE_LOCKED: message = "网络缓存暂时被占用"
        case SQLITE_FULL: message = "网络缓存空间不足或已达容量上限"
        case SQLITE_READONLY: message = "网络缓存处于只读状态，无法保存"
        case SQLITE_PERM, SQLITE_AUTH: message = "没有网络缓存的访问权限"
        case SQLITE_CANTOPEN: message = "无法打开网络缓存，请检查缓存目录和访问权限"
        case SQLITE_CORRUPT, SQLITE_NOTADB: message = "网络缓存文件格式异常或已损坏，原文件已保留"
        case SQLITE_IOERR: message = "网络缓存发生磁盘读写错误"
        default: message = "网络缓存操作失败"
        }
        let result = code.map { primary in
            extendedCode.map { $0 != primary ? "SQLite \(primary)/\($0)" : "SQLite \(primary)" } ?? "SQLite \(primary)"
        } ?? "缓存读写队列繁忙"
        return "\(message)（\(operation)，\(result)）：\(detail)"
    }
    func saveDiagnostic(in directory: URL) {
        // One small overwritten file per session, never an accumulating log.
        var value: [String: Any] = ["time": Date().timeIntervalSince1970, "operation": operation, "detail": detail]
        if let code { value["code"] = code }
        if let extendedCode { value["extendedCode"] = extendedCode }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data.count <= 4096 else { return }
        let file = directory.appendingPathComponent("last-error.json")
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* The original SQLite error must survive a diagnostic-write failure. */ }
    }
}

/// Five bounded retries (100, 200, 400, 800, 1600 ms), only for contention.
/// Capacity, permission, corruption and I/O failures remain explicit failures.
public enum NetworkStorageRetry {
    public static let maximumRetries = 5
    public static func delay(for error: Error, failure: Int) -> Duration? {
        guard let storage = error as? NetworkStorageError, storage.isTransient,
              (1...maximumRetries).contains(failure) else { return nil }
        return .milliseconds(100 << (failure - 1))
    }
}

/// All connections to one cache coordinate *whole synchronous operations*,
/// including a writer's complete transaction. SQLite FULLMUTEX only protects
/// each individual connection; it does not coordinate the UI and capture actors.
/// No lock is held across await, network transport or body formatting.
final class NetworkCacheAccess {
    private final class WeakReference {
        weak var value: NetworkCacheAccess?
        init(_ value: NetworkCacheAccess) { self.value = value }
    }
    private static let registryLock = NSLock()
    private static var registry: [String: WeakReference] = [:]
    private let lock = NSRecursiveLock()
    static func shared(for directory: URL) -> NetworkCacheAccess {
        let key = directory.standardizedFileURL.resolvingSymlinksInPath().path
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = registry[key]?.value { return existing }
        if registry.count >= 32 { registry = registry.filter { $0.value.value != nil } }
        let access = NetworkCacheAccess(); registry[key] = WeakReference(access)
        return access
    }
    func acquire() throws {
        try Task.checkCancellation()
        guard lock.lock(before: Date().addingTimeInterval(0.5)) else { throw NetworkStorageError.accessTimeout }
        do { try Task.checkCancellation() }
        catch { lock.unlock(); throw error }
    }
    func acquireForClose() { lock.lock() }
    func release() { lock.unlock() }
}
