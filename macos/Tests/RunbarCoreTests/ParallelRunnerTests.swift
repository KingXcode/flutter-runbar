import XCTest
@testable import RunbarCore

final class ParallelRunnerTests: XCTestCase {
    @MainActor
    func testRealConcurrentRunsStopAndDevToolsIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parallel-runbar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let aURL = root.appendingPathComponent("Project A"), bURL = root.appendingPathComponent("Project B")
        try FileManager.default.createDirectory(at: aURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bURL, withIntermediateDirectories: true)
        let a = Project(path: aURL.path), b = Project(path: bURL.path)
        let coordinator = ProjectRunCoordinator(store: store)
        let finished = expectation(description: "both projects finish"); finished.expectedFulfillmentCount = 2
        var sessions: [UUID: RunSession] = [:]
        var requestedStop = false
        var stoppedAWhileBActive = false
        coordinator.onEvent = { [weak coordinator] event in
            guard let coordinator else { return }
            switch event {
            case .updated:
                if !requestedStop && !coordinator.state(for: a.id).liveDevToolsURLs.isEmpty && !coordinator.state(for: b.id).liveDevToolsURLs.isEmpty {
                    requestedStop = true
                    XCTAssertEqual(coordinator.state(for: a.id).liveDevToolsURLs, ["http://127.0.0.1:9101/devtools/?uri=a"])
                    XCTAssertEqual(coordinator.state(for: b.id).liveDevToolsURLs, ["http://127.0.0.1:9102/devtools/?uri=b"])
                    coordinator.stop(projectID: a.id)
                }
            case .finished(let id, let session):
                sessions[id] = session
                if id == a.id { stoppedAWhileBActive = coordinator.state(for: b.id).isBusy }
                finished.fulfill()
            default: break
            }
        }
        coordinator.start(project: a, preset: CommandPreset(command: "printf 'A-only\\nhttp://127.0.0.1:9101/devtools/?uri=a\\n'; sleep 30"), extraPath: "/usr/bin:/bin")
        coordinator.start(project: b, preset: CommandPreset(command: "printf 'B-only\\nhttp://127.0.0.1:9102/devtools/?uri=b\\n'; sleep 9; printf 'B-finished\\n'"), extraPath: "/usr/bin:/bin")
        await fulfillment(of: [finished], timeout: 20)
        // Even a failed URL-detection assertion/timeout must not orphan subprocesses.
        if coordinator.isBusy {
            let cleanup = expectation(description: "cleanup active processes after test failure")
            coordinator.onEvent = { [weak coordinator] event in
                guard let coordinator else { return }
                if case .finished = event, !coordinator.isBusy { cleanup.fulfill() }
            }
            coordinator.stopAll()
            await fulfillment(of: [cleanup], timeout: 12)
        }
        coordinator.onEvent = nil
        XCTAssertTrue(requestedStop); XCTAssertTrue(stoppedAWhileBActive)
        XCTAssertFalse(coordinator.isBusy)
        let sessionA = try XCTUnwrap(sessions[a.id]), sessionB = try XCTUnwrap(sessions[b.id])
        XCTAssertNotEqual(sessionA.id, sessionB.id)
        XCTAssertEqual(sessionA.status, .stopped); XCTAssertEqual(sessionB.status, .succeeded)
        let logA = try String(contentsOf: store.directory(sessionA.id).appendingPathComponent("output.raw"), encoding: .utf8)
        let logB = try String(contentsOf: store.directory(sessionB.id).appendingPathComponent("output.raw"), encoding: .utf8)
        XCTAssertTrue(logA.contains("A-only")); XCTAssertFalse(logA.contains("B-only"))
        XCTAssertTrue(logB.contains("B-only")); XCTAssertTrue(logB.contains("B-finished")); XCTAssertFalse(logB.contains("A-only"))
        XCTAssertTrue(coordinator.state(for: a.id).liveDevToolsURLs.isEmpty)
        XCTAssertTrue(coordinator.state(for: b.id).liveDevToolsURLs.isEmpty)
    }
}
