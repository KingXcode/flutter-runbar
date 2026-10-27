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
    value["endTime"] = start + 100
    if end {
        var response = value["response"] as! [String: Any]
        response["endTime"] = start + 50_000; value["response"] = response
    }
    return try NetworkRecord.parse(value, epoch: epoch, isolate: isolate)
}

final class NetworkStoreTests: XCTestCase {
    func testChronologicalPagesAndFollowingLatestAcrossBoundary() throws {
        try networkFixture { _, store in
            try store.upsert((0..<250).map { try sampleRecord(String($0), start: Int64($0)) })
            let latest = try store.page(latest: true)
            XCTAssertEqual(latest.page, 2)
            XCTAssertEqual(latest.records.first?.requestID, "200"); XCTAssertEqual(latest.records.last?.requestID, "249")
            try store.upsert((250..<301).map { try sampleRecord(String($0), start: Int64($0)) })
            let following = try store.page(page: latest.page, latest: true)
            XCTAssertEqual(following.page, 3); XCTAssertEqual(following.records.map(\.requestID), ["300"])
            let stopped = try store.page(page: 1)
            XCTAssertEqual(stopped.page, 1); XCTAssertEqual(stopped.records.first?.requestID, "100")
            XCTAssertEqual(stopped.records.last?.requestID, "199")
            var query = NetworkQuery(); query.text = "/missing"
            XCTAssertTrue(try store.page(query: query, latest: true).records.isEmpty)
            XCTAssertEqual(try store.page(query: query, latest: true).page, 0)
        }
    }
    func testFormattingFullBodyPagesWithoutChangingOriginal() throws {
        try networkFixture { root, store in
            let record = try sampleRecord("formatted")
            try store.upsert([record])
            let raw = Data(("{\"text\":\"" + String(repeating: "中🚀", count: 30_000) + "\",\"large\":900719925474099312345}").utf8)
            try store.saveBodies(record.id, request: Data(), response: raw)
            let saved = try XCTUnwrap(try store.request(record.id))
            let first = try store.bodyPage(saved, response: true, page: 0, format: .json)
            var combined = first.text
            for page in 1..<first.pages { combined += try store.bodyPage(saved, response: true, page: page, format: .json).text }
            XCTAssertFalse(combined.contains("�")); XCTAssertTrue(combined.contains("900719925474099312345"))
            XCTAssertEqual(combined, String(decoding: try NetworkBodyFormatter.format(raw, as: .json), as: UTF8.self))
            XCTAssertEqual(first.bytes, raw.count)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("bodies/\(saved.id).response")), raw)
            let request = try store.bodyPage(saved, response: false, page: 0)
            XCTAssertEqual(request.text, "（正文为空）")
        }
    }
    func testJSONAndXMLFormattingValidationAndLimits() throws {
        let json = Data(#"{"number":900719925474099312345,"text":"a\\\"b {} []","empty":[],"nested":{"x":true}}"#.utf8)
        let formatted = try NetworkBodyFormatter.format(json, as: .json)
        let text = String(decoding: formatted, as: UTF8.self)
        XCTAssertTrue(text.contains("\n  \"number\": 900719925474099312345,"))
        XCTAssertTrue(text.contains("\"empty\": []"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: formatted) as? NSDictionary, try JSONSerialization.jsonObject(with: json) as? NSDictionary)
        let xml = try NetworkBodyFormatter.format(Data("<root><item id=\"1\">你好</item><item><![CDATA[a<b]]></item></root>".utf8), as: .xml)
        XCTAssertNotNil(String(decoding: xml, as: UTF8.self).range(of: "\n +<item", options: .regularExpression))
        XCTAssertTrue(String(decoding: xml, as: UTF8.self).contains("<![CDATA[a<b]]>"))
        XCTAssertThrowsError(try NetworkBodyFormatter.format(Data("not json".utf8), as: .json))
        XCTAssertThrowsError(try NetworkBodyFormatter.format(Data("<invalid>".utf8), as: .xml))
        XCTAssertThrowsError(try NetworkBodyFormatter.format(Data("<!DOCTYPE root SYSTEM 'file:///private/test'><root/>".utf8), as: .xml))
        XCTAssertThrowsError(try NetworkBodyFormatter.format(try XCTUnwrap("{\"a\":1}".data(using: .utf16LittleEndian)), as: .json))
        XCTAssertThrowsError(try NetworkBodyFormatter.format(try XCTUnwrap("<!DOCTYPE root [<!ENTITY a 'x'>]><root>&a;</root>".data(using: .utf16LittleEndian)), as: .xml))
        XCTAssertThrowsError(try NetworkBodyFormatter.format(Data(repeating: 32, count: NetworkBodyFormatter.inputLimit + 1), as: .json))
        let deep = String(repeating: "[", count: 129) + "0" + String(repeating: "]", count: 129)
        XCTAssertThrowsError(try NetworkBodyFormatter.format(Data(deep.utf8), as: .json))
        let expanded = String(repeating: "[", count: 60) + Array(repeating: "0", count: 50_000).joined(separator: ",") + String(repeating: "]", count: 60)
        XCTAssertThrowsError(try NetworkBodyFormatter.format(Data(expanded.utf8), as: .json))
    }
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
            XCTAssertEqual(try store.page().records.first?.requestID, "0")
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
            let persisted = try XCTUnwrap(try store.page().records.first)
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
            XCTAssertEqual(last.records.first?.requestID, "9900")
            XCTAssertEqual(last.records.last?.requestID, "9999")
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
    var requestCount = 1
    var bodyDelay: UInt64 = 0
    var bodyIDs: [String] = []
    var summaries = 0
    var activeBodies = 0
    var peakBodies = 0
    func configure(complete: Bool? = nil, restart: Bool = false, missing: Bool = false, oversized: Bool = false, delay: Bool = false, supported: Bool = true, clockJitter: Int = 0, requestCount: Int = 1, bodyDelay: UInt64 = 0) {
        if let complete { self.complete = complete }; if restart { start += 1 }
        missingBodies = missing; self.oversized = oversized; self.delay = delay; self.supported = supported
        self.clockJitter = clockJitter; self.requestCount = requestCount; self.bodyDelay = bodyDelay
    }
    func counts() -> (Int, Int, Int) { (bodyCalls, clears, resumes) }
    func cursorValues() -> [String] { cursors }
    func work() -> (summaries: Int, bodyIDs: [String], peakBodies: Int) { (summaries, bodyIDs, peakBodies) }
    private func request(_ id: Int) -> [String: Any] {
        var response: [String: Any] = ["statusCode": 200, "contentLength": 2]
        if complete { response["endTime"] = 2_010_000 + id * 100 }
        return ["id": String(id), "method": "POST", "uri": "http://example.test/echo", "startTime": 2_000_000 + id * 100,
                "endTime": 2_000_100 + id * 100, "response": response]
    }
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
            summaries += 1
            result = ["timestamp": 3_000_000, "requests": parameters["updatedSince"] == String(Int64.max) ? [] : (1...requestCount).map { request($0) }]
        case "ext.dart.io.getHttpProfileRequest":
            bodyCalls += 1; activeBodies += 1; peakBodies = max(peakBodies, activeBodies)
            defer { activeBodies -= 1 }
            let id = parameters["id"] ?? "1"; bodyIDs.append(id)
            if bodyDelay > 0 { try await Task.sleep(nanoseconds: bodyDelay) }
            result = request(Int(id) ?? 1)
            if !missingBodies { result["requestBody"] = [123, 125]; result["responseBody"] = [91, 93] }
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
    func testResponseCompletionAndLegacyTiming() throws {
        var value: [String: Any] = ["id": "timing", "uri": "http://example.test/slow", "method": "POST",
                                    "startTime": 1_000_000, "endTime": 1_000_100,
                                    "response": ["startTime": 1_100_000, "statusCode": 200]]
        let pending = try NetworkRecord.parse(value, epoch: "epoch", isolate: "main")
        XCTAssertFalse(pending.isComplete); XCTAssertNil(pending.durationMS); XCTAssertNil(pending.endMicros)
        value["response"] = ["startTime": 1_100_000, "endTime": 1_250_000, "statusCode": 200]
        let completed = try NetworkRecord.parse(value, epoch: "epoch", isolate: "main")
        XCTAssertTrue(completed.isComplete); XCTAssertEqual(completed.durationMS, 250)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(completed)) as? [String: Any])
        legacy.removeValue(forKey: "timingVersion"); legacy["endMicros"] = 1_000_100
        let old = try JSONDecoder().decode(NetworkRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.durationMS); XCTAssertFalse(old.isComplete)
        value.removeValue(forKey: "response"); value["request"] = ["error": "connection failed"]
        let failed = try NetworkRecord.parse(value, epoch: "epoch", isolate: "main")
        XCTAssertTrue(failed.isComplete); XCTAssertEqual(failed.durationMS, 0.1)
    }
    func testBacklogDrainsWithoutNewSummariesAndSelectedRequestHasPriority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = FakeNetworkVM(), endpoint = try XCTUnwrap(VMServiceEndpoint("http://localhost:5555/auth/"))
        await vm.configure(complete: true, requestCount: 100, bodyDelay: 20_000_000)
        let capture = NetworkCaptureSession(directory: root, endpoint: endpoint, transport: vm)
        let metadata = try await capture.poll(cacheBodies: false)
        XCTAssertEqual(metadata.pendingBodies, 100)
        let reader = NetworkCacheReader()
        let page = try await reader.page(directory: root, query: NetworkQuery(), page: 0)
        let newest = try XCTUnwrap(page.records.last), oldest = try XCTUnwrap(page.records.first)
        let background = Task { try await capture.drainPendingBodies() }
        try await Task.sleep(for: .milliseconds(5))
        let duplicate = try await capture.cacheBody(oldest.id)
        XCTAssertFalse(duplicate)
        let selected = try await capture.cacheBody(newest.id)
        XCTAssertTrue(selected)
        let selectedPage = try await reader.page(directory: root, query: NetworkQuery(), page: 0)
        XCTAssertEqual(selectedPage.records.last?.bodyState, .saved)
        let batch = try await background.value
        XCTAssertEqual(batch.processed, 8); XCTAssertEqual(batch.pending, 91)
        let before = await vm.work()
        // A paused intake never asks for another summary, but bodies still catch up.
        await vm.configure(complete: true, requestCount: 130)
        var remaining = batch.pending
        while remaining > 0 { remaining = try await capture.drainPendingBodies().pending }
        let after = await vm.work()
        XCTAssertEqual(after.summaries, before.summaries)
        XCTAssertEqual(after.bodyIDs.count, 100)
        XCTAssertEqual(Set(after.bodyIDs).count, 100)
        XCTAssertLessThanOrEqual(after.peakBodies, 2)
        let saved = try await reader.page(directory: root, query: NetworkQuery(), page: 0)
        XCTAssertEqual(saved.total, 100); XCTAssertTrue(saved.records.allSatisfy { $0.bodyState == .saved })
        try await capture.finish()
    }
    func testUploadingFinishedDoesNotCacheIncompleteResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = FakeNetworkVM(), endpoint = try XCTUnwrap(VMServiceEndpoint("http://localhost:5555/auth/"))
        let capture = NetworkCaptureSession(directory: root, endpoint: endpoint, transport: vm)
        _ = try await capture.poll()
        let counts = await vm.counts(); XCTAssertEqual(counts.0, 0)
        let reader = NetworkCacheReader()
        let page = try await reader.page(directory: root, query: NetworkQuery(), page: 0)
        let record = try XCTUnwrap(page.records.first)
        XCTAssertNil(record.durationMS); XCTAssertEqual(record.bodyState, .pending)
        _ = try await capture.cacheBody(record.id)
        let stillPending = try await reader.page(directory: root, query: NetworkQuery(), page: 0)
        XCTAssertEqual(stillPending.records.first?.bodyState, .pending)
        await vm.configure(complete: true)
        let before = await vm.work()
        _ = try await capture.drainPendingBodies(refreshIncomplete: true)
        let after = await vm.work()
        XCTAssertEqual(after.summaries, before.summaries)
        let completed = try await reader.page(directory: root, query: NetworkQuery(), page: 0)
        XCTAssertEqual(completed.records.first?.bodyState, .saved)
        XCTAssertEqual(completed.records.first?.durationMS, 10)
        try await capture.finish()
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
        _ = try await transport.call(endpoint: connection.1, method: "trigger", parameters: ["value": "SWIFT_FIRST", "delay": "160"])
        _ = try await capture.poll()
        _ = try await transport.call(endpoint: connection.1, method: "trigger", parameters: ["value": "SWIFT_SECOND"])
        _ = try await capture.poll()
        let reader = NetworkCacheReader()
        let page = try await reader.page(directory: root, query: NetworkQuery(), page: 0)
        XCTAssertEqual(page.total, 2, page.records.map { "\($0.requestID) \($0.isolateID) \($0.method) \($0.url)" }.joined(separator: "\n"))
        XCTAssertTrue(page.records.allSatisfy { $0.status == 200 && $0.bodyState == .saved })
        let first = try XCTUnwrap(page.records.first)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(first.durationMS), 140)
        let request = try await reader.body(directory: root, record: first, response: false, page: 0)
        let response = try await reader.body(directory: root, record: first, response: true, page: 0)
        XCTAssertTrue(request.text.contains("SWIFT_FIRST")); XCTAssertTrue(response.text.contains("SWIFT_FIRST"))
        let streaming = Task {
            try await transport.call(endpoint: connection.1, method: "trigger", parameters: ["value": "SWIFT_STREAMING", "delay": "1000"])
        }
        var partial: NetworkRecord?
        for _ in 0..<8 {
            _ = try await capture.poll(cacheBodies: false)
            let current = try await reader.page(directory: root, query: NetworkQuery(), page: 0)
            partial = current.records.first { record in !page.records.contains { $0.id == record.id } }
            if partial != nil { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        let unfinished = try XCTUnwrap(partial)
        XCTAssertNil(unfinished.endMicros); XCTAssertNil(unfinished.durationMS)
        XCTAssertEqual(unfinished.bodyState, .pending)
        _ = try await streaming.value
        // No new summaries: complete this already-recorded response while paused.
        _ = try await capture.drainPendingBodies(refreshIncomplete: true)
        let completed = try await reader.page(directory: root, query: NetworkQuery(), page: 0)
        let cached = try XCTUnwrap(completed.records.first { $0.id == unfinished.id })
        XCTAssertEqual(cached.bodyState, .saved)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(cached.durationMS), 900)
        let limited = HTTPVMServiceTransport(limit: 1024)
        do { _ = try await limited.call(endpoint: connection.1, method: "oversized", parameters: [:]); XCTFail("Expected wire size limit") }
        catch VMServiceError.responseTooLarge {} catch { XCTFail("Unexpected size error") }
        do { _ = try await transport.call(endpoint: connection.1, method: "redirect", parameters: [:]); XCTFail("Expected redirect rejection") }
        catch VMServiceError.unavailable {} catch { XCTFail("Unexpected redirect error") }
        _ = try await transport.call(endpoint: connection.1, method: "stop", parameters: [:])
        process.waitUntilExit(); try await capture.finish()
        let history = try await reader.page(directory: root, query: NetworkQuery(), page: 0)
        XCTAssertEqual(history.total, 3)
        let offline = try await reader.body(directory: root, record: first, response: true, page: 0)
        XCTAssertEqual(offline.text, response.text)
    }
}
