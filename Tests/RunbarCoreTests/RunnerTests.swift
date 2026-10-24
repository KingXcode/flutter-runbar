import XCTest
@testable import RunbarCore

final class RunnerTests: XCTestCase {
    private func temporaryStore() throws -> SessionStore {
        try SessionStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("Runbar tests \(UUID().uuidString)"))
    }
    func testRunPersistsExitAndAllOutput() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
        let finished = expectation(description: "finished")
        var result: RunSession?
        let runner = ProcessRunner(store: store) { event in
            if case .finished(let session) = event { result = session; finished.fulfill() }
        }
        runner.run(project: Project(path: store.root.path), preset: CommandPreset(command: "printf '你好\\n'; printf 'stderr\\n' >&2; exit 7"), extraPath: "/usr/bin:/bin", shell: "/bin/sh")
        wait(for: [finished], timeout: 10)
        let session = try XCTUnwrap(result)
        XCTAssertEqual(session.status, .failed); XCTAssertEqual(session.exitCode, 7)
        XCTAssertNotNil(session.endedAt); XCTAssertNotNil(session.duration)
        XCTAssertEqual(try Data(contentsOf: store.directory(session.id).appendingPathComponent("output.raw")), Data("你好\nstderr\n".utf8))
    }
    func testSmallOutputIsDeliveredBeforeProcessExits() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
        let finished = expectation(description: "finished")
        let launchedAt = Date()
        var firstOutputDelay: TimeInterval?
        var result: RunSession?
        let runner = ProcessRunner(store: store) { event in
            switch event {
            case .output(let text):
                if text.contains("ready"), firstOutputDelay == nil {
                    firstOutputDelay = Date().timeIntervalSince(launchedAt)
                }
            case .finished(let session): result = session; finished.fulfill()
            case .failure(let message): XCTFail(message)
            default: break
            }
        }
        runner.run(project: Project(path: store.root.path), preset: CommandPreset(command: "printf ready; sleep 3; printf done"), extraPath: "/usr/bin:/bin", shell: "/bin/sh")
        wait(for: [finished], timeout: 10)
        XCTAssertLessThan(try XCTUnwrap(firstOutputDelay), 1.5, "Short output must not wait for a full buffer or EOF")
        let session = try XCTUnwrap(result)
        XCTAssertEqual(session.status, .succeeded)
        XCTAssertEqual(try Data(contentsOf: store.directory(session.id).appendingPathComponent("output.raw")), Data("readydone".utf8))
    }
    func testMissingShellIsTerminalFailure() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
        let finished = expectation(description: "failed start")
        let runner = ProcessRunner(store: store) { event in
            if case .finished(let session) = event {
                XCTAssertEqual(session.status, .failed); XCTAssertNotNil(session.error); finished.fulfill()
            }
        }
        runner.run(project: Project(path: store.root.path), preset: CommandPreset(command: "true"), extraPath: "", shell: "/no-such-runbar-shell")
        wait(for: [finished], timeout: 10)
    }
    func testStopEscalatesAndPersistsStoppedStatus() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
        let finished = expectation(description: "stopped")
        var runner: ProcessRunner!
        runner = ProcessRunner(store: store) { event in
            switch event {
            case .started: runner.stop()
            case .failure(let message): XCTFail("Stopping an owned process must not report an error: \(message)")
            case .finished(let session): XCTAssertEqual(session.status, .stopped); finished.fulfill()
            default: break
            }
        }
        runner.run(project: Project(path: store.root.path), preset: CommandPreset(command: "sleep 30"), extraPath: "/usr/bin:/bin", shell: "/bin/sh")
        wait(for: [finished], timeout: 12)
        runner = nil
        XCTAssertEqual(try store.sessions().first?.status, .stopped)
    }
    func testEmptyCommandRejectedWithoutStarting() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
        let rejected = expectation(description: "rejected")
        let runner = ProcessRunner(store: store) { event in
            if case .rejected = event { rejected.fulfill() }
        }
        runner.run(project: Project(path: store.root.path), preset: CommandPreset(command: " \n"), extraPath: "", shell: "/bin/sh")
        wait(for: [rejected], timeout: 3)
        XCTAssertEqual(try store.sessions().count, 0)
    }
}
