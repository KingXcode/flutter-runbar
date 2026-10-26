import XCTest
@testable import RunbarCore

final class RunnerTests: XCTestCase {
    private func temporaryStore() throws -> SessionStore {
        try SessionStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("Runbar tests \(UUID().uuidString)"))
    }
    func testGenericProjectRunsCustomCommandWithoutFlutterOnPath() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
        var project = Project(path: store.root.path)
        XCTAssertEqual(project.kind, .generic)
        XCTAssertTrue(project.availablePresets.isEmpty)
        try project.savePreset(name: "自定义命令", command: "PATH=/usr/bin:/bin; if command -v fvm >/dev/null 2>&1; then exit 99; fi; printf 'custom project\\n'")
        let finished = expectation(description: "custom command finished")
        var result: RunSession?
        let runner = ProcessRunner(store: store) { event in
            if case .finished(let session) = event { result = session; finished.fulfill() }
            if case .failure(let message) = event { XCTFail(message) }
        }
        runner.run(project: project, preset: try XCTUnwrap(project.selectedPreset), extraPath: "/usr/bin:/bin", shell: "/bin/sh")
        wait(for: [finished], timeout: 10)
        let session = try XCTUnwrap(result)
        XCTAssertEqual(session.status, .succeeded)
        XCTAssertEqual(try Data(contentsOf: store.directory(session.id).appendingPathComponent("output.raw")), Data("custom project\n".utf8))
    }
    func testNativeActionRejectedBeforeShellLaunch() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
        let rejected = expectation(description: "built-in rejected")
        let runner = ProcessRunner(store: store) { event in
            if case .rejected = event { rejected.fulfill() }
            if case .started = event { XCTFail("A native action must not launch a shell") }
        }
        var preset = CommandPreset.sandboxReset; preset.command = "touch must-not-exist"
        runner.run(project: Project(path: store.root.path), preset: preset, extraPath: "", shell: "/bin/sh")
        wait(for: [rejected], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("must-not-exist").path))
        XCTAssertTrue(try store.sessions().isEmpty)
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
    func testShortOutputArrivesBeforeProcessExit() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
        let live = expectation(description: "short output delivered while child still sleeps")
        let finished = expectation(description: "child finishes")
        var sawLive = false
        var didFinish = false
        let runner = ProcessRunner(store: store) { event in
            switch event {
            case .output(let text):
                if text.contains("LIVE") && !sawLive {
                    sawLive = true; XCTAssertFalse(didFinish); live.fulfill()
                }
            case .finished: didFinish = true; finished.fulfill()
            default: break
            }
        }
        runner.run(project: Project(path: store.root.path), preset: CommandPreset(command: "printf 'LIVE\\n'; sleep 5"), extraPath: "/usr/bin:/bin", shell: "/bin/sh")
        wait(for: [live], timeout: 3)
        wait(for: [finished], timeout: 8)
    }

}
