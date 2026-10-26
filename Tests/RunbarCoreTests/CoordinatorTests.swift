import XCTest
@testable import RunbarCore

private final class FakeProjectDriver: ProjectCommandRunning {
    let send: (ProcessRunner.Event) -> Void
    var starts = 0
    var stops = 0
    var command: String?
    init(_ send: @escaping (ProcessRunner.Event) -> Void) { self.send = send }
    func start(project: Project, preset: CommandPreset, extraPath: String) { starts += 1; command = preset.command }
    func stop() { stops += 1 }
}

final class CoordinatorTests: XCTestCase {
    @MainActor
    func testBuiltInCannotCreateShellDriverEvenWithCommandText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var calls = 0
        let coordinator = ProjectRunCoordinator(store: store) { _, send in
            calls += 1; return FakeProjectDriver(send)
        }
        var preset = CommandPreset.sandboxReset
        preset.command = "echo must-not-execute"
        XCTAssertFalse(coordinator.start(project: Project(path: root.path), preset: preset, extraPath: ""))
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertTrue(try store.sessions().isEmpty)
    }

    @MainActor
    func testConcurrentProjectsOwnSessionsURLsAndStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var drivers: [FakeProjectDriver] = []
        let coordinator = ProjectRunCoordinator(store: store) { _, send in
            let driver = FakeProjectDriver(send); drivers.append(driver); return driver
        }
        let a = Project(path: "/tmp/runbar-a"), b = Project(path: "/tmp/runbar-b")
        let command = CommandPreset(command: "example command")
        XCTAssertTrue(coordinator.start(project: a, preset: command, extraPath: ""))
        XCTAssertFalse(coordinator.start(project: a, preset: command, extraPath: ""))
        XCTAssertTrue(coordinator.start(project: b, preset: command, extraPath: ""))
        XCTAssertEqual(drivers.count, 2)
        var runA = RunSession(projectPath: a.path, command: command.command)
        var runB = RunSession(projectPath: b.path, command: command.command)
        drivers[0].send(.started(runA)); drivers[1].send(.started(runB))
        runA.devToolsURLs = ["http://127.0.0.1:9101/devtools/?uri=a"]
        runB.devToolsURLs = ["http://127.0.0.1:9102/devtools/?uri=b"]
        drivers[0].send(.updated(runA)); drivers[1].send(.updated(runB))
        XCTAssertEqual(coordinator.state(for: a.id).liveDevToolsURLs, runA.devToolsURLs)
        XCTAssertEqual(coordinator.state(for: b.id).liveDevToolsURLs, runB.devToolsURLs)
        coordinator.stop(projectID: a.id)
        XCTAssertEqual(drivers[0].stops, 1); XCTAssertEqual(drivers[1].stops, 0)
        XCTAssertTrue(coordinator.state(for: a.id).liveDevToolsURLs.isEmpty)
        XCTAssertEqual(coordinator.state(for: b.id).phase, .running)
        runA.status = .stopped; drivers[0].send(.finished(runA))
        XCTAssertTrue(coordinator.isBusy)
        XCTAssertEqual(coordinator.state(for: a.id).phase, .idle)
        runB.status = .succeeded; drivers[1].send(.finished(runB))
        XCTAssertFalse(coordinator.isBusy)
    }

    @MainActor
    func testOutputRoutingAndRestartRejectStaleCallbacks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var drivers: [FakeProjectDriver] = []
        let coordinator = ProjectRunCoordinator(store: store) { _, send in
            let driver = FakeProjectDriver(send); drivers.append(driver); return driver
        }
        let a = Project(path: "/tmp/a"), b = Project(path: "/tmp/b"), preset = CommandPreset(command: "echo fixture")
        var outputs: [UUID: String] = [:]
        coordinator.onEvent = { event in
            if case .output(let id, _, let text) = event { outputs[id, default: ""] += text }
        }
        coordinator.start(project: a, preset: preset, extraPath: ""); coordinator.start(project: b, preset: preset, extraPath: "")
        var old = RunSession(projectPath: a.path, command: preset.command)
        let other = RunSession(projectPath: b.path, command: preset.command)
        drivers[0].send(.started(old)); drivers[1].send(.started(other))
        drivers[0].send(.output("AAA")); drivers[1].send(.output("BBB"))
        XCTAssertEqual(outputs[a.id], "AAA"); XCTAssertEqual(outputs[b.id], "BBB")
        old.devToolsURLs = ["http://localhost:9100/devtools/?uri=old"]
        drivers[0].send(.updated(old)); drivers[0].send(.finished(old))
        XCTAssertTrue(coordinator.start(project: a, preset: preset, extraPath: ""))
        XCTAssertTrue(coordinator.state(for: a.id).liveDevToolsURLs.isEmpty)
        drivers[0].send(.updated(old)); drivers[0].send(.output("STALE")); drivers[0].send(.finished(old))
        XCTAssertEqual(coordinator.state(for: a.id).phase, .starting)
        XCTAssertEqual(outputs[a.id], "AAA")
        XCTAssertEqual(coordinator.state(for: b.id).session?.id, other.id)
    }

    @MainActor
    func testStopAllIncludesPendingLaunchAndWaitsForEveryTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var drivers: [FakeProjectDriver] = []
        let coordinator = ProjectRunCoordinator(store: store) { _, send in
            let driver = FakeProjectDriver(send); drivers.append(driver); return driver
        }
        let a = Project(path: "/tmp/a"), b = Project(path: "/tmp/b"), preset = CommandPreset(command: "echo fixture")
        coordinator.start(project: a, preset: preset, extraPath: ""); coordinator.start(project: b, preset: preset, extraPath: "")
        let session = RunSession(projectPath: a.path, command: preset.command)
        drivers[0].send(.started(session))
        coordinator.stopAll(); coordinator.stopAll()
        XCTAssertEqual(drivers.map(\.stops), [1, 1])
        XCTAssertEqual(coordinator.state(for: b.id).phase, .stopping)
        drivers[0].send(.finished(session)); XCTAssertTrue(coordinator.isBusy)
        drivers[1].send(.rejected("launch rejected")); XCTAssertFalse(coordinator.isBusy)
        XCTAssertEqual(coordinator.state(for: b.id).error, "launch rejected")
    }

    @MainActor
    func testFailuresAndAliasesDoNotAffectOtherProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var drivers: [FakeProjectDriver] = []
        let coordinator = ProjectRunCoordinator(store: store) { _, send in
            let driver = FakeProjectDriver(send); drivers.append(driver); return driver
        }
        let a = Project(path: "/tmp/a"), alias = Project(path: "/tmp/a/../a"), b = Project(path: "/tmp/b")
        XCTAssertFalse(coordinator.start(project: a, preset: CommandPreset(command: " \n"), extraPath: ""))
        XCTAssertFalse(coordinator.isBusy)
        coordinator.start(project: a, preset: CommandPreset(command: "echo fixture"), extraPath: "")
        XCTAssertFalse(coordinator.start(project: alias, preset: CommandPreset(command: "echo fixture"), extraPath: ""))
        coordinator.start(project: b, preset: CommandPreset(command: "echo fixture"), extraPath: "")
        drivers[0].send(.failure("disk failure"))
        XCTAssertEqual(coordinator.state(for: a.id).phase, .stopping)
        XCTAssertEqual(drivers[0].stops, 1); XCTAssertEqual(drivers[1].stops, 0)
        XCTAssertEqual(coordinator.state(for: b.id).phase, .starting)
    }

    @MainActor
    func testLiveLogSnapshotsArePerSessionBoundedAndReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var drivers: [FakeProjectDriver] = []
        let coordinator = ProjectRunCoordinator(store: store) { _, send in
            let driver = FakeProjectDriver(send); drivers.append(driver); return driver
        }
        let a = Project(path: "/tmp/a"), b = Project(path: "/tmp/b"), preset = CommandPreset(command: "echo fixture")
        coordinator.start(project: a, preset: preset, extraPath: "")
        coordinator.start(project: b, preset: preset, extraPath: "")
        let sessionA = RunSession(projectPath: a.path, command: preset.command)
        let sessionB = RunSession(projectPath: b.path, command: preset.command)
        drivers[0].send(.started(sessionA)); drivers[1].send(.started(sessionB))
        drivers[0].send(.output("A1")); drivers[1].send(.output("B1"))
        XCTAssertEqual(coordinator.liveLog(for: sessionA.id), "A1")
        // Selection snapshots cannot include not-yet-delivered future chunks.
        drivers[0].send(.output("A2"))
        XCTAssertEqual(coordinator.liveLog(for: sessionA.id), "A1A2")
        XCTAssertEqual(coordinator.liveLog(for: sessionB.id), "B1")
        drivers[0].send(.output("a" + String(repeating: "\u{0301}", count: 150_000)))
        XCTAssertLessThan(try XCTUnwrap(coordinator.liveLog(for: sessionA.id)).utf8.count, 100_200)
        drivers[0].send(.finished(sessionA))
        XCTAssertNil(coordinator.liveLog(for: sessionA.id))
        coordinator.start(project: a, preset: preset, extraPath: "")
        let next = RunSession(projectPath: a.path, command: preset.command)
        drivers[2].send(.started(next))
        XCTAssertEqual(coordinator.liveLog(for: next.id), "")
        XCTAssertEqual(coordinator.liveLog(for: sessionB.id), "B1")
    }

    func testSelectionBackwardsCompatibilityAndURLValidation() throws {
        let json = """
        {"id":"11111111-1111-4111-8111-111111111111","path":"/tmp/demo","presets":[{"id":"22222222-2222-4222-8222-222222222222","name":"Run","command":"echo ok"}]}
        """
        var project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(project.selectedPreset?.name, "Run")
        let second = CommandPreset(name: "Second", command: "echo two")
        project.presets.append(second); project.selectedPresetID = second.id
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(restored.selectedPreset?.id, second.id)
        XCTAssertNotNil(DevToolsLink.validatedURL("http://localhost:9100/devtools/?uri=ok"))
        XCTAssertNil(DevToolsLink.validatedURL("https://example.com/devtools/"))
        XCTAssertNil(DevToolsLink.validatedURL("javascript:alert(1)"))
        XCTAssertNil(DevToolsLink.validatedURL("http://name:password@localhost:9100/"))
    }
}
