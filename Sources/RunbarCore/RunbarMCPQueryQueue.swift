import Foundation

enum RunbarMCPQueueError: LocalizedError, Equatable {
    case full, timedOut, closed
    var errorDescription: String? {
        switch self {
        case .full: return "MCP 查询等待队列已满，请稍后重试。"
        case .timedOut: return "MCP 查询排队等待超时，请稍后重试或缩小查询范围。"
        case .closed: return "MCP 服务已关闭，查询已取消。"
        }
    }
}

/// One permit, bounded FIFO waiters, no file handles or query results held
/// while waiting. Ownership transfers before a continuation is resumed.
actor RunbarMCPQueryQueue {
    static let maximumWaiting = 7
    static let maximumWait: Duration = .seconds(30)
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, Error>
        let deadline: ContinuousClock.Instant
        let timer: Task<Void, Never>
    }
    private let capacity: Int
    private let timeout: Duration
    private let clock = ContinuousClock()
    private var active: UUID?
    private var waiters: [Waiter] = []
    private var closed = false
    var waitingCount: Int { waiters.count }

    init(capacity: Int = maximumWaiting, timeout: Duration = maximumWait) {
        self.capacity = min(Self.maximumWaiting, max(0, capacity)); self.timeout = max(.zero, timeout)
    }
    func acquire() async throws -> UUID {
        try Task.checkCancellation()
        guard !closed else { throw RunbarMCPQueueError.closed }
        let id = UUID()
        if active == nil { active = id; return id }
        guard waiters.count < capacity else { throw RunbarMCPQueueError.full }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                // Cancellation may happen before the continuation is registered.
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let deadline = clock.now.advanced(by: timeout)
                let timer = Task<Void, Never> { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.expire(id)
                }
                waiters.append(Waiter(id: id, continuation: continuation, deadline: deadline, timer: timer))
            }
        }, onCancel: {
            Task { await self.cancel(id) }
        })
    }
    func release(_ id: UUID) {
        guard active == id else { return }
        active = nil
        guard !closed else { return }
        while !waiters.isEmpty {
            let next = waiters.removeFirst(); next.timer.cancel()
            guard clock.now < next.deadline else { next.continuation.resume(throwing: RunbarMCPQueueError.timedOut); continue }
            active = next.id
            next.continuation.resume(returning: next.id)
            return
        }
    }
    private func cancel(_ id: UUID) { remove(id, error: CancellationError()) }
    private func expire(_ id: UUID) { remove(id, error: RunbarMCPQueueError.timedOut) }
    private func remove(_ id: UUID, error: Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index); waiter.timer.cancel()
        waiter.continuation.resume(throwing: error)
        // If the permit was already granted, its caller owns releasing it,
        // including the cancellation check immediately after acquire().
    }
    func shutdown() {
        closed = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending {
            waiter.timer.cancel(); waiter.continuation.resume(throwing: RunbarMCPQueueError.closed)
        }
    }
}
