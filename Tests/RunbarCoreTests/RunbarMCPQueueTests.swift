import XCTest
@testable import RunbarCore

final class RunbarMCPQueueTests: XCTestCase {
    private func until(_ predicate: () async -> Bool) async throws {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
        while !(await predicate()) {
            guard clock.now < deadline else { XCTFail("queue state did not settle"); throw CancellationError() }
            await Task.yield()
        }
    }
    func testFIFOAndStaleReleaseCannotHandOutTwoPermits() async throws {
        let queue = RunbarMCPQueryQueue(), initial = try await queue.acquire()
        let first = Task { try await queue.acquire() }
        try await until { await queue.waitingCount == 1 }
        let second = Task { try await queue.acquire() }
        try await until { await queue.waitingCount == 2 }
        await queue.release(initial)
        let firstPermit = try await first.value
        let waiting = await queue.waitingCount
        XCTAssertEqual(waiting, 1)
        await queue.release(initial) // A delayed duplicate release is harmless.
        let stillWaiting = await queue.waitingCount
        XCTAssertEqual(stillWaiting, 1)
        await queue.release(firstPermit)
        let secondPermit = try await second.value
        XCTAssertNotEqual(firstPermit, secondPermit)
        await queue.release(secondPermit)
        let next = try await queue.acquire(); await queue.release(next)
        await queue.shutdown()
    }
    func testFullQueueAndCancellationRemoveOnlyTheCancelledWaiter() async throws {
        let queue = RunbarMCPQueryQueue(capacity: 1), initial = try await queue.acquire()
        let pending = Task { try await queue.acquire() }
        try await until { await queue.waitingCount == 1 }
        do { _ = try await queue.acquire(); XCTFail("queue must be bounded") }
        catch { XCTAssertEqual(error as? RunbarMCPQueueError, .full) }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("cancelled task must leave queue") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await queue.waitingCount
        XCTAssertEqual(count, 0)
        let replacement = Task { try await queue.acquire() }
        try await until { await queue.waitingCount == 1 }
        await queue.release(initial)
        let permit = try await replacement.value; await queue.release(permit)
        await queue.shutdown()
    }
    func testQueueTimeoutDoesNotConsumeTheNextPermit() async throws {
        let queue = RunbarMCPQueryQueue(timeout: .milliseconds(30)), initial = try await queue.acquire()
        do { _ = try await queue.acquire(); XCTFail("waiting must have a deadline") }
        catch { XCTAssertEqual(error as? RunbarMCPQueueError, .timedOut) }
        let count = await queue.waitingCount
        XCTAssertEqual(count, 0)
        await queue.release(initial)
        let next = try await queue.acquire(); await queue.release(next)
        await queue.shutdown()
    }
    func testAlreadyCancelledTaskNeverAcquiresAPermit() async throws {
        let queue = RunbarMCPQueryQueue()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await queue.acquire()
        }
        do { _ = try await cancelled.value; XCTFail("cancelled task must not own permit") }
        catch { XCTAssertTrue(error is CancellationError) }
        let permit = try await queue.acquire(); await queue.release(permit)
        await queue.shutdown()
    }
    func testShutdownReleasesAllWaitersAndRejectsNewQueries() async throws {
        let queue = RunbarMCPQueryQueue(), initial = try await queue.acquire()
        let first = Task { try await queue.acquire() }
        try await until { await queue.waitingCount == 1 }
        let second = Task { try await queue.acquire() }
        try await until { await queue.waitingCount == 2 }
        await queue.shutdown()
        for task in [first, second] {
            do { _ = try await task.value; XCTFail("shutdown must finish waiting tasks") }
            catch { XCTAssertEqual(error as? RunbarMCPQueueError, .closed) }
        }
        do { _ = try await queue.acquire(); XCTFail("closed queue must reject work") }
        catch { XCTAssertEqual(error as? RunbarMCPQueueError, .closed) }
        await queue.release(initial)
        let count = await queue.waitingCount
        XCTAssertEqual(count, 0)
    }
    func testDataSourceQueuesBehindFailedQueryAndAllowsLightweightQueries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runbar-mcp-queue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root), session = RunSession(projectPath: "/fixture", command: "echo fixture")
        try store.save(session)
        let barrier = MCPSnapshotBarrier(RunbarMCPSnapshot(sessions: [session]))
        let source = RunbarMCPDataSource(root: root) { await barrier.snapshot() }
        let invalid = try JSONSerialization.data(withJSONObject: ["sessionId": UUID().uuidString])
        let valid = try JSONSerialization.data(withJSONObject: ["sessionId": session.id.uuidString])
        let first = Task { try await source.call("runbar_get_session", arguments: invalid) }
        try await until { await barrier.blocked }
        let second = Task { try await source.call("runbar_get_session", arguments: valid) }
        try await until { await source.waitingQueries == 1 }
        // This finishes while the first heavy query is held and the second waits.
        let light = try await source.call("runbar_list_sessions", arguments: Data("{}".utf8))
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: light) as? [String: Any])
        XCTAssertEqual(list["total"] as? Int, 1)
        await barrier.unblock()
        do { _ = try await first.value; XCTFail("unknown session must fail") } catch {}
        let result = try await second.value
        let detail = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(detail["sessionId"] as? String, session.id.uuidString)
        await source.shutdown()
    }
}

private actor MCPSnapshotBarrier {
    private let value: RunbarMCPSnapshot
    private var first = true
    private var continuation: CheckedContinuation<Void, Never>?
    var blocked: Bool { continuation != nil }
    init(_ value: RunbarMCPSnapshot) { self.value = value }
    func snapshot() async -> RunbarMCPSnapshot {
        if first {
            first = false
            await withCheckedContinuation { continuation = $0 }
        }
        return value
    }
    func unblock() { let pending = continuation; continuation = nil; pending?.resume() }
}
