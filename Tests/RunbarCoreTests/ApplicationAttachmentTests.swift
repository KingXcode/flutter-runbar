import XCTest
@testable import RunbarCore

private actor AttachmentProbeVM: VMServiceTransport {
    var methods: [String] = []
    var pid = 42
    var flutter = true
    func configure(pid: Int, flutter: Bool) { self.pid = pid; self.flutter = flutter }
    func call(endpoint: VMServiceEndpoint, method: String, parameters: [String: String]) async throws -> Data {
        methods.append(method)
        return try JSONSerialization.data(withJSONObject: ["result": method == "getVM" ? ["pid": pid] : ["views": flutter ? [["id": "view"]] : []]])
    }
}
private actor AttachmentSocket: VMEventConnection {
    var methods: [String] = []
    var frames: [Data] = []
    var pending: CheckedContinuation<Data, Error>?
    var closed = false
    func send(_ data: Data) throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        methods.append(object["method"] as? String ?? "")
        try push(["id": object["id"]!, "result": ["type": "Success"]])
    }
    func push(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        if let pending { self.pending = nil; pending.resume(returning: data) } else { frames.append(data) }
    }
    func receive() async throws -> Data {
        if closed { throw CancellationError() }
        if !frames.isEmpty { return frames.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func close() { closed = true; pending?.resume(throwing: CancellationError()); pending = nil }
    func requests() -> [String] { methods }
}
private actor AttachmentRecorder {
    var session: RunSession?
    func accept(_ event: ApplicationLogSession.Event) { if case .finished(let value) = event { session = value } }
    func result() -> RunSession? { session }
}

final class ApplicationAttachmentTests: XCTestCase {
    func testDevToolsStartupAddressWithSDKTrailingPeriod() {
        XCTAssertEqual(LocalDevToolsServer.startupURL(from: "Serving DevTools at http://127.0.0.1:9100."), URL(string: "http://127.0.0.1:9100"))
        XCTAssertNotNil(LocalDevToolsServer.startupURL(from: "Serving DevTools at http://127.0.0.1:9100"))
        XCTAssertNil(LocalDevToolsServer.startupURL(from: "Serving DevTools at http://remote.example:9100."))
        XCTAssertNil(LocalDevToolsServer.startupURL(from: "http://127.0.0.1:9100"))
    }
    func testLegacyConfigurationAndSourceIdentitySurvivePIDChanges() throws {
        let old = try JSONDecoder().decode(Configuration.self, from: Data(#"{"projects":[],"extraPath":""}"#.utf8))
        XCTAssertNil(old.applications)
        let target = ApplicationTarget(name: "Fixture", bundleIdentifier: "test.fixture", bundlePath: "/tmp/fixture.app")
        let next = ApplicationTarget(name: "Fixture renamed", bundleIdentifier: "test.fixture", bundlePath: "/tmp/fixture.app")
        XCTAssertTrue(target.matches(next))
        XCTAssertFalse(target.matches(ApplicationTarget(name: "Fixture", bundleIdentifier: "test.fixture", bundlePath: "/tmp/other.app")))
        var first = RunSession(projectPath: "", command: "监听 Fixture"), second = first
        first.attachment = ApplicationAttachment(application: target, processID: 42)
        second.attachment = ApplicationAttachment(application: target, processID: 77)
        XCTAssertEqual(first.sourceKey, second.sourceKey); XCTAssertTrue(second.belongs(to: target))
        XCTAssertEqual(first.sourceName, "Fixture")
        let copy = try JSONDecoder().decode(RunSession.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(copy.attachment, first.attachment)
        let project = RunSession(projectPath: "/tmp/fixture", command: "echo hello")
        XCTAssertNil(project.attachment); XCTAssertFalse(project.belongs(to: target))
        var config = old; config.applications = [target]
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config)).applications, [target])
    }
    func testDiscoveryOnlyUsesSelectedProcessPortsAndVerifiedPID() async throws {
        XCTAssertEqual(ApplicationDiscovery.ports(from: "p42\nn127.0.0.1:8000\nn*:8000\nn[::1]:9000\nn*:0\nn*:99999"), [8000, 9000])
        let vm = AttachmentProbeVM(), probe = ApplicationServiceProbe(transport: vm)
        let endpoint = try XCTUnwrap(VMServiceEndpoint("http://127.0.0.1:5555/PRIVATE_AUTH/"))
        try await probe.validate(endpoint, processID: 42, flutterDetected: false)
        await vm.configure(pid: 43, flutter: true)
        do { try await probe.validate(endpoint, processID: 42, flutterDetected: true); XCTFail("Different process must be rejected") } catch {}
        let wrong = try await probe.discover(processID: 42, flutterDetected: true, known: [endpoint], ports: [])
        XCTAssertNil(wrong)
        await vm.configure(pid: 42, flutter: false)
        do { try await probe.validate(endpoint, processID: 42, flutterDetected: false); XCTFail("Non-Flutter must be rejected") } catch {}
        let methods = await vm.methods
        XCTAssertTrue(methods.allSatisfy { ["getVM", "_flutter.listViews"].contains($0) })
    }
    func testDisconnectPersistsStreamsAndNeverControlsTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = AttachmentSocket(), recorder = AttachmentRecorder(), ready = expectation(description: "streams subscribed")
        let target = ApplicationTarget(name: "Fixture", bundleIdentifier: "test.fixture", bundlePath: "/tmp/Fixture.app")
        let endpoint = try XCTUnwrap(VMServiceEndpoint("http://localhost:5555/PRIVATE_AUTH/"))
        let monitor = ApplicationLogSession(root: root, endpoint: endpoint, attachment: ApplicationAttachment(application: target, processID: 42), connection: socket) { event in
            await recorder.accept(event)
            if case .connected(let streams) = event { XCTAssertEqual(streams, ["Stdout", "Stderr", "Logging"]); ready.fulfill() }
        }
        await monitor.start(); await fulfillment(of: [ready], timeout: 3)
        for stream in ["Stdout", "Stderr"] {
            try await socket.push(["method": "streamNotify", "params": ["streamId": stream, "event": ["bytes": Data((stream + "_中文🚀\n").utf8).base64EncodedString()]]])
        }
        try await socket.push(["method": "streamNotify", "params": ["streamId": "Logging", "event": ["logRecord": ["message": ["valueAsString": "developer.log OK"], "loggerName": ["valueAsString": "fixture"]]]]])
        try await Task.sleep(for: .milliseconds(180))
        await monitor.disconnect()
        let recorded = await recorder.result()
        let result = try XCTUnwrap(recorded)
        XCTAssertEqual(result.status, .stopped); XCTAssertNil(result.error)
        XCTAssertEqual(result.attachment?.application.id, target.id)
        let store = try SessionStore(root: root), text = try store.tail(result.id)
        XCTAssertTrue(text.contains("Stdout_中文🚀")); XCTAssertTrue(text.contains("Stderr_中文🚀")); XCTAssertTrue(text.contains("[fixture] developer.log OK"))
        XCTAssertFalse(text.contains("PRIVATE_AUTH")); XCTAssertTrue(result.devToolsURLs.isEmpty)
        let requests = await socket.requests()
        XCTAssertEqual(requests, ["streamListen", "streamListen", "streamListen"])
        XCTAssertEqual(try store.sessions().first?.status, .stopped)
    }
    func testLocalDartAttachmentCapturesLogsAndLeavesTargetAlive() async throws {
        guard let executable = ProcessInfo.processInfo.environment["RUNBAR_DART_VM"] else { throw XCTSkip("Set RUNBAR_DART_VM for attachment integration") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.arguments = ["--enable-vm-service=0", repository.appendingPathComponent("scripts/probe-devtools-network.dart").path, "--fixture"]
        process.standardOutput = output; process.standardError = errors; try process.run()
        let timeout = Task.detached { try? await Task.sleep(for: .seconds(20)); if !Task.isCancelled && process.isRunning { process.terminate() } }
        defer { timeout.cancel(); if process.isRunning { process.terminate() }; process.waitUntilExit(); try? FileManager.default.removeItem(at: root) }
        let connection: (VMServiceEndpoint, VMServiceEndpoint) = try await Task.detached {
            var text = "", endpoint: VMServiceEndpoint?, control: VMServiceEndpoint?
            while text.utf8.count < 32_768 {
                let data = output.fileHandleForReading.availableData
                guard !data.isEmpty else { throw VMServiceError.unavailable }
                text += String(decoding: data, as: UTF8.self)
                for line in text.split(separator: "\n") {
                    if line.hasPrefix("VM_ENDPOINT=") { endpoint = VMServiceEndpoint(String(line.dropFirst(12))) }
                    if line.hasPrefix("CONTROL_PORT="), let port = Int(line.dropFirst(13)) { control = VMServiceEndpoint("http://127.0.0.1:\(port)/") }
                }
                if let endpoint, let control { return (endpoint, control) }
            }
            throw VMServiceError.invalidResponse
        }.value
        try await ApplicationServiceProbe().validate(connection.0, processID: process.processIdentifier, flutterDetected: true)
        let target = ApplicationTarget(name: "Local fixture", bundleIdentifier: "test.fixture", bundlePath: "/tmp/Fixture.app")
        let recorder = AttachmentRecorder(), ready = expectation(description: "real VM streams")
        let monitor = ApplicationLogSession(root: root, endpoint: connection.0, attachment: ApplicationAttachment(application: target, processID: process.processIdentifier)) { event in
            await recorder.accept(event)
            if case .connected(let streams) = event { XCTAssertTrue(streams.contains("Stdout")); ready.fulfill() }
        }
        await monitor.start(); await fulfillment(of: [ready], timeout: 8)
        _ = try await HTTPVMServiceTransport().call(endpoint: connection.1, method: "logs", parameters: [:])
        try await Task.sleep(for: .milliseconds(400)); await monitor.disconnect()
        let recorded = await recorder.result()
        let result = try XCTUnwrap(recorded), store = try SessionStore(root: root)
        let text = try store.tail(result.id)
        XCTAssertTrue(text.contains("ATTACH_STDOUT_中文🚀")); XCTAssertTrue(text.contains("ATTACH_STDERR_OK"))
        XCTAssertTrue(text.contains("ATTACH_LOGGING_")); XCTAssertTrue(text.contains(String(repeating: "long-value-", count: 1000)))
        XCTAssertTrue(process.isRunning, "Disconnect must not terminate the attached app")
        _ = try await HTTPVMServiceTransport().call(endpoint: connection.0, method: "getVM", parameters: [:])
        XCTAssertEqual(result.status, .stopped)
        _ = try await HTTPVMServiceTransport().call(endpoint: connection.1, method: "stop", parameters: [:]); process.waitUntilExit()
    }
    func testLocalDevToolsFrontendStartsAndStops() async throws {
        guard let executable = ProcessInfo.processInfo.environment["RUNBAR_DART_VM"] else { throw XCTSkip("Set RUNBAR_DART_VM for local DevTools integration") }
        let server = LocalDevToolsServer()
        let endpoint = try XCTUnwrap(VMServiceEndpoint("http://127.0.0.1:1/PRIVATE_TEST_AUTH/"))
        let sdkBin = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        do {
            let url = try await server.url(for: endpoint, extraPath: sdkBin)
            let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.host, "127.0.0.1")
            XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "uri" })?.value, endpoint.url.absoluteString)
            let (data, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("flutter_bootstrap.js"))
            await server.stop()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 0.3
            let client = URLSession(configuration: configuration)
            var closed = false
            for _ in 0..<10 {
                do { _ = try await client.data(from: url); try await Task.sleep(for: .milliseconds(50)) }
                catch { closed = true; break }
            }
            client.invalidateAndCancel()
            XCTAssertTrue(closed, "The owned frontend must stop with Runbar")
        } catch { await server.stop(); throw error }
    }
}
