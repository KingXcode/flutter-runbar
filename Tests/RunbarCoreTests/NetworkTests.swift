import XCTest
@testable import RunbarCore

private func networkFixture(_ block: (URL, NetworkStore) throws -> Void, limits: NetworkLimits = NetworkLimits()) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("runbar-network-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try NetworkStore(directory: root, limits: limits); defer { store.close() }
    try block(root, store)
}
private func sampleRecord(_ id: String, start: Int64 = 1_000_000, end: Bool = true, url: String = "http://example.test/api", method: String = "POST", status: Int = 200, epoch: String = "epoch", isolate: String = "isolates/1") throws -> NetworkRecord {
    var value: [String: Any] = ["id": id, "method": method, "uri": url, "startTime": start,
                                "request": ["contentLength": 2, "headers": ["content-type": ["application/json"]]],
                                "response": ["statusCode": status, "contentLength": 2, "headers": ["content-type": ["application/json"]]]]
    if end { value["endTime"] = start + 50_000 }
    return try NetworkRecord.parse(value, epoch: epoch, isolate: isolate)
}

final class NetworkStoreTests: XCTestCase {
    func testPagesLiteralFiltersStatusAndUpsertsPreserveBodies() throws {
        try networkFixture { root, store in
            var records: [NetworkRecord] = []
            for index in 0..<250 {
                let method = index % 2 == 0 ? "GET" : "POST"
                let status = index % 3 == 0 ? 500 : 200
                let url = "http://example.test/\(index)%_quote'"
                records.append(try sampleRecord(String(index), start: Int64(index * 1000), url: url, method: method, status: status))
            }
            try store.upsert(records)
            XCTAssertEqual(try store.page().records.count, 100)
            XCTAssertEqual(try store.page().records.first?.requestID, "249")
            XCTAssertEqual(try store.page(page: 1).records.count, 100)
            XCTAssertEqual(try store.page(page: 2).records.count, 50)
            XCTAssertEqual(try store.page(page: 99).page, 2)
            var query = NetworkQuery(); query.text = "49%_quote'"
            XCTAssertEqual(try store.page(query: query).matching, 3)
            query.text = ""; query.method = "GET"; query.status = .serverError
            XCTAssertEqual(try store.page(query: query).matching, 42)
            let record = records[0]
            try store.saveBodies(record.id, request: Data("{}".utf8), response: Data("[]".utf8))
            try store.upsert([record])
            let persisted = try XCTUnwrap(try store.page(page: 2).records.last)
            XCTAssertEqual(persisted.bodyState, .saved)
            XCTAssertEqual(try store.bodyPage(persisted, response: true, page: 0).text, "[]")
            let reader = try NetworkStore(directory: root, readOnly: true); defer { reader.close() }
            XCTAssertEqual(try reader.page().total, 250)
            XCTAssertEqual(try reader.bodyPage(persisted, response: false, page: 0).text, "{}")
        }
    }
    func testBodyLimitsBudgetIdempotenceAndCrashAccounting() throws {
        var limits = NetworkLimits(); limits.bodyBytes = 4; limits.bodyBudget = 8
        try networkFixture({ root, store in
            let a = try sampleRecord("a"), b = try sampleRecord("b"), c = try sampleRecord("c")
            try store.upsert([a, b, c])
            try store.saveBodies(a.id, request: Data("1234".utf8), response: Data("5678".utf8))
            try store.saveBodies(a.id, request: Data("zzzz".utf8), response: Data("xxxx".utf8))
            try store.saveBodies(b.id, request: Data("x".utf8), response: Data())
            try store.saveBodies(c.id, request: Data(repeating: 65, count: 5), response: Data())
            let records = try store.page().records
            XCTAssertEqual(records.first { $0.id == a.id }?.bodyState, .saved)
            XCTAssertEqual(records.first { $0.id == b.id }?.bodyState, .omitted)
            XCTAssertEqual(records.first { $0.id == c.id }?.bodyState, .omitted)
            let cached = try XCTUnwrap(records.first { $0.id == a.id })
            XCTAssertEqual(try store.bodyPage(cached, response: false, page: 0).text, "1234")
            store.close()
            // A body written before a crash still consumes the next run's budget.
            try Data(repeating: 1, count: 8).write(to: root.appendingPathComponent("bodies/orphan"))
            let reopened = try NetworkStore(directory: root, limits: limits); defer { reopened.close() }
            let d = try sampleRecord("d"); try reopened.upsert([d]); try reopened.saveBodies(d.id, request: Data([1]), response: Data())
            XCTAssertEqual(try reopened.page().records.first { $0.id == d.id }?.bodyState, .omitted)
        }, limits: limits)
    }
    func testBodyPagingUTF8EmptyBinaryAndFinishPending() throws {
        try networkFixture { _, store in
            let a = try sampleRecord("utf8"), b = try sampleRecord("pending", end: false)
            try store.upsert([a, b])
            let text = String(repeating: "a", count: 128 * 1024 - 1) + "🚀尾部"
            try store.saveBodies(a.id, request: Data(), response: Data(text.utf8))
            let saved = try XCTUnwrap(try store.page().records.first { $0.id == a.id })
            let first = try store.bodyPage(saved, response: true, page: 0), next = try store.bodyPage(saved, response: true, page: 1)
            XCTAssertEqual(first.pages, 2); XCTAssertTrue(first.text.hasSuffix("🚀")); XCTAssertEqual(next.text, "🚀尾部")
            XCTAssertFalse(first.text.contains("�")); XCTAssertFalse(next.text.contains("�"))
            XCTAssertEqual(try store.bodyPage(saved, response: false, page: 0).text, "（正文为空）")
            try store.finalizePending()
            XCTAssertEqual(try store.page().records.first { $0.id == b.id }?.bodyState, .unavailable)
        }
    }
    func testBatchAndCountQuotasRollbackWholeBatch() throws {
        var limits = NetworkLimits(); limits.requests = 2; limits.batchRequests = 3
        try networkFixture({ _, store in
            let records = try (0..<3).map { try sampleRecord(String($0)) }
            XCTAssertThrowsError(try store.upsert(records))
            XCTAssertEqual(try store.page().total, 0)
            try store.upsert(Array(records.prefix(2)))
            try store.upsert([records[0]])
            XCTAssertThrowsError(try store.upsert([records[2]]))
            XCTAssertEqual(try store.page().total, 2)
        }, limits: limits)
    }
    func testIdentityIsolationAndLegacyProjectPreference() throws {
        let one = try sampleRecord("1"), otherVM = try sampleRecord("1", epoch: "new-vm"), otherIsolate = try sampleRecord("1", isolate: "isolates/2")
        XCTAssertNotEqual(one.id, otherVM.id); XCTAssertNotEqual(one.id, otherIsolate.id)
        XCTAssertEqual(one.durationMS, 50)
        let legacy = Data("{\"id\":\"00000000-0000-4000-8000-000000000001\",\"path\":\"/tmp/example\",\"presets\":[]}".utf8)
        var project = try JSONDecoder().decode(Project.self, from: legacy)
        XCTAssertNil(project.networkCaptureEnabled)
        project.networkCaptureEnabled = true
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
    }
    func testLargeHistoryOnlyReadsRequestedPage() throws {
        try networkFixture { _, store in
            for batch in 0..<5 {
                try autoreleasepool {
                    let records = try (0..<2000).map { try sampleRecord(String(batch * 2000 + $0), start: Int64(batch * 2000 + $0)) }
                    try store.upsert(records)
                }
            }
            let last = try store.page(page: 99)
            XCTAssertEqual(last.total, 10_000); XCTAssertEqual(last.records.count, 100)
            XCTAssertEqual(last.records.first?.requestID, "99")
            XCTAssertEqual(last.records.last?.requestID, "0")
        }
    }
    func testDatabaseCapacityFailureRollsBackBatch() throws {
        var limits = NetworkLimits(); limits.databasePages = 32
        try networkFixture({ _, store in
            let records = try (0..<100).map { index -> NetworkRecord in
                var record = try sampleRecord(String(index)); record.requestHeaders = String(repeating: "a", count: 4096); return record
            }
            XCTAssertThrowsError(try store.upsert(records))
            XCTAssertEqual(try store.page().total, 0)
        }, limits: limits)
    }
}

final class VMServiceDiscoveryTests: XCTestCase {
    func testExplicitAnnouncementsSplitAcrossChunksAndNestedURI() throws {
        var parser = VMServiceDiscovery()
        XCTAssertTrue(parser.consume("The Dart VM service is listening on http://127.0.0.1:5555/PRIVATE_").isEmpty)
        let result = parser.consume("TEST_TOKEN=/\n")
        XCTAssertEqual(result.first?.url.absoluteString, "http://127.0.0.1:5555/PRIVATE_TEST_TOKEN=/")
        let wrapped = parser.consume("The Flutter DevTools is available at: http://127.0.0.1:9100/?uri=http%3A%2F%2F127.0.0.1%3A5555%2FPRIVATE_TEST_TOKEN%3D%2F\n")
        XCTAssertEqual(wrapped, result)
        XCTAssertTrue(parser.consume("App requested http://127.0.0.1:9000/business\n").isEmpty)
        XCTAssertEqual(VMServiceEndpoint("ws://localhost:5555/auth=/ws")?.url.absoluteString, "http://localhost:5555/auth=/")
        XCTAssertTrue(parser.consume("DevTools at http://127.0.0.1:9100/\n").isEmpty)
        XCTAssertNil(VMServiceEndpoint("http://127.0.0.1:9100/devtools/"))
        for value in ["http://remote.example/auth/", "http://127.0.0.1.example/auth/", "http://user:pass@localhost/auth/", "file:///tmp/x", "http://localhost/a/#secret", "http://localhost/a/?uri=http://remote.example/x"] {
            XCTAssertNil(VMServiceEndpoint(value))
        }
    }
}

private actor FakeNetworkVM: VMServiceTransport {
    var complete = false
    var start = 1
    var clockJitter = 0
    var missingBodies = false
    var oversized = false
    var delay = false
    var supported = true
    var bodyCalls = 0
    var clears = 0
    var resumes = 0
    var cursors: [String] = []
    func configure(complete: Bool? = nil, restart: Bool = false, missing: Bool = false, oversized: Bool = false, delay: Bool = false, supported: Bool = true, clockJitter: Int = 0) {
        if let complete { self.complete = complete }; if restart { start += 1 }
        missingBodies = missing; self.oversized = oversized; self.delay = delay; self.supported = supported
        self.clockJitter = clockJitter
    }
    func counts() -> (Int, Int, Int) { (bodyCalls, clears, resumes) }
    func cursorValues() -> [String] { cursors }
    func call(endpoint: VMServiceEndpoint, method: String, parameters: [String: String]) async throws -> Data {
        if delay { try await Task.sleep(for: .seconds(10)) }
        if oversized { return Data(repeating: 65, count: 1025) }
        var result: [String: Any] = [:]
        switch method {
        case "getVM": result = ["pid": start, "startTime": start * 10000 + clockJitter, "isolates": [["id": "isolates/1", "name": "main"]]]
        case "getIsolate": result = ["extensionRPCs": supported ? ["ext.dart.io.getHttpProfile"] : [], "pauseEvent": ["kind": "PauseStart"]]
        case "ext.dart.io.httpEnableTimelineLogging": result = ["enabled": true]
        case "ext.dart.io.getHttpProfile":
            cursors.append(parameters["updatedSince"] ?? "")
            var request: [String: Any] = ["id": "1", "method": "POST", "uri": "http://example.test/echo", "startTime": 2_000_000]
            if complete { request["endTime"] = 2_010_000; request["response"] = ["statusCode": 200, "contentLength": 2] }
            result = ["timestamp": 3_000_000, "requests": parameters["updatedSince"] == String(Int64.max) ? [] : [request]]
        case "ext.dart.io.getHttpProfileRequest":
            bodyCalls += 1
            result = missingBodies ? [:] : ["requestBody": [123, 125], "responseBody": [91, 93]]
        case "ext.dart.io.clearHttpProfile": clears += 1
        case "resume": resumes += 1
        default: throw VMServiceError.unsupported
        }
        return try JSONSerialization.data(withJSONObject: ["result": result])
    }
}

final class NetworkCaptureTests: XCTestCase {
    func testPendingUpdatesBodiesRestartAndExplicitClear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = try XCTUnwrap(VMServiceEndpoint("http://127.0.0.1:5555/PRIVATE_TEST_TOKEN=/")), vm = FakeNetworkVM()
        let capture = NetworkCaptureSession(directory: root, endpoint: endpoint, transport: vm)
        let first = try await capture.poll(); XCTAssertTrue(first.supported); XCTAssertFalse(first.pausedIsolates.isEmpty)
        await vm.configure(complete: true)
        _ = try await capture.poll()
        await vm.configure(clockJitter: 1)
        _ = try await capture.poll()
        let calls = await vm.counts(); XCTAssertEqual(calls.0, 1); XCTAssertEqual(calls.1, 0)
        let cursors = await vm.cursorValues(); XCTAssertEqual(cursors.first, String(Int64.max)); XCTAssertTrue(cursors.contains("2000000"))
        let reader = NetworkCacheReader()
        let page = try await reader.page(directory: root, query: NetworkQuery(), page: 0)
        XCTAssertEqual(page.total, 1); XCTAssertEqual(page.records.first?.status, 200); XCTAssertEqual(page.records.first?.bodyState, .saved)
        let body = try await reader.body(directory: root, record: XCTUnwrap(page.records.first), response: true, page: 0)
        XCTAssertEqual(body.text, "[]")
        await vm.configure(restart: true); _ = try await capture.poll()
        let restarted = try await reader.page(directory: root, query: NetworkQuery(), page: 0)
        XCTAssertEqual(restarted.total, 2)
        try await capture.clearTargetBuffer(); try await capture.resumePausedApplication()
        let explicit = await vm.counts(); XCTAssertEqual(explicit.1, 1); XCTAssertEqual(explicit.2, 1)
        try await capture.finish()
        let history = try await reader.page(directory: root, query: NetworkQuery(), page: 0); XCTAssertEqual(history.total, 2)
        let dbBytes = try Data(contentsOf: root.appendingPathComponent("requests.sqlite"))
        XCTAssertNil(dbBytes.range(of: Data("PRIVATE_TEST_TOKEN".utf8)))
    }
    func testMissingBodiesUnsupportedSizeAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = FakeNetworkVM(), endpoint = try XCTUnwrap(VMServiceEndpoint("http://localhost:5555/auth/"))
        await vm.configure(complete: true, missing: true)
        let capture = NetworkCaptureSession(directory: root, endpoint: endpoint, transport: vm)
        _ = try await capture.poll()
        let page = try await NetworkCacheReader().page(directory: root, query: NetworkQuery(), page: 0)
        XCTAssertEqual(page.records.first?.bodyState, .unavailable)
        await vm.configure(supported: false)
        let unsupported = try await capture.poll(); XCTAssertFalse(unsupported.supported)
        await vm.configure(delay: true)
        let task = Task { try await capture.poll() }
        try await Task.sleep(for: .milliseconds(20)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        try await capture.finish()
        let large = FakeNetworkVM(); await large.configure(oversized: true)
        var limits = NetworkLimits(); limits.responseBytes = 1024
        let bounded = NetworkCaptureSession(directory: root.appendingPathComponent("large"), endpoint: endpoint, transport: large, limits: limits)
        do { _ = try await bounded.poll(); XCTFail("Expected size limit") } catch VMServiceError.responseTooLarge {} catch { XCTFail("Unexpected error") }
        try await bounded.finish()
    }
}

extension NetworkCaptureTests {
    /// Opt-in integration: a self-owned Dart fixture, loopback traffic only.
    /// This exercises the same Swift collector used by Runbar, not the prototype.
    func testLocalDartVMIntegration() async throws {
        guard let vm = ProcessInfo.processInfo.environment["RUNBAR_DART_VM"] else {
            throw XCTSkip("Set RUNBAR_DART_VM to run the loopback Dart VM integration")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runbar-network-integration-" + UUID().uuidString)
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: vm)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.arguments = ["--enable-vm-service=0", repository.appendingPathComponent("scripts/probe-devtools-network.dart").path, "--fixture"]
        process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let timeout = Task.detached { try? await Task.sleep(for: .seconds(20)); if !Task.isCancelled && process.isRunning { process.terminate() } }
        defer {
            timeout.cancel(); if process.isRunning { process.terminate() }; process.waitUntilExit()
            try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
            try? FileManager.default.removeItem(at: root)
        }
        let connection: (VMServiceEndpoint, VMServiceEndpoint) = try await Task.detached {
            var text = "", endpoint: VMServiceEndpoint?, control: VMServiceEndpoint?
            while text.utf8.count < 32_768 {
                let data = stdout.fileHandleForReading.availableData
                guard !data.isEmpty else { throw RunbarError.message("Loopback fixture exited before handshake") }
                text += String(decoding: data, as: UTF8.self)
                for line in text.split(separator: "\n") {
                    if line.hasPrefix("VM_ENDPOINT=") { endpoint = VMServiceEndpoint(String(line.dropFirst(12))) }
                    if line.hasPrefix("CONTROL_PORT="), let port = Int(line.dropFirst(13)) { control = VMServiceEndpoint("http://127.0.0.1:\(port)/") }
                }
                if let endpoint, let control { return (endpoint, control) }
            }
            throw RunbarError.message("Loopback handshake too large")
        }.value
        let capture = NetworkCaptureSession(directory: root, endpoint: connection.0)
        let update = try await capture.poll()
        XCTAssertTrue(update.supported, "The real Dart VM must advertise the supported HTTP extension")
        let transport = HTTPVMServiceTransport()
        _ = try await transport.call(endpoint: connection.1, method: "trigger", parameters: ["value": "SWIFT_FIRST"])
        _ = try await capture.poll()
        _ = try await transport.call(endpoint: connection.1, method: "trigger", parameters: ["value": "SWIFT_SECOND"])
        _ = try await capture.poll()
        let reader = NetworkCacheReader()
        let page = try await reader.page(directory: root, query: NetworkQuery(), page: 0)
        XCTAssertEqual(page.total, 2, page.records.map { "\($0.requestID) \($0.isolateID) \($0.method) \($0.url)" }.joined(separator: "\n"))
        XCTAssertTrue(page.records.allSatisfy { $0.status == 200 && $0.bodyState == .saved })
        let first = try XCTUnwrap(page.records.last)
        let request = try await reader.body(directory: root, record: first, response: false, page: 0)
        let response = try await reader.body(directory: root, record: first, response: true, page: 0)
        XCTAssertTrue(request.text.contains("SWIFT_FIRST")); XCTAssertTrue(response.text.contains("SWIFT_FIRST"))
        let limited = HTTPVMServiceTransport(limit: 1024)
        do { _ = try await limited.call(endpoint: connection.1, method: "oversized", parameters: [:]); XCTFail("Expected wire size limit") }
        catch VMServiceError.responseTooLarge {} catch { XCTFail("Unexpected size error") }
        do { _ = try await transport.call(endpoint: connection.1, method: "redirect", parameters: [:]); XCTFail("Expected redirect rejection") }
        catch VMServiceError.unavailable {} catch { XCTFail("Unexpected redirect error") }
        _ = try await transport.call(endpoint: connection.1, method: "stop", parameters: [:])
        process.waitUntilExit(); try await capture.finish()
        let history = try await reader.page(directory: root, query: NetworkQuery(), page: 0)
        XCTAssertEqual(history.total, 2)
        let offline = try await reader.body(directory: root, record: first, response: true, page: 0)
        XCTAssertEqual(offline.text, response.text)
    }
}
