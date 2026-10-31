import XCTest
import CSQLite
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
    func testVirtualListFarJumpsHaveFullRangeAndBoundedSummaries() throws {
        var limits = NetworkLimits(); limits.databasePages = 32768
        try networkFixture({ _, store in
            for batch in 0..<25 {
                try autoreleasepool {
                    let records = try (0..<2000).map { index -> NetworkRecord in
                        let number = batch * 2000 + index
                        var record = try sampleRecord(String(number), start: Int64(number), url: "http://example.test/\(number)")
                        record.requestHeaders = ""; record.responseHeaders = ""; return record
                    }
                    try store.upsert(records)
                }
            }
            for anchor in [0, 255, 256, 12_345, 49_999, Int.max, -100] {
                let window = try store.listWindow(around: anchor)
                XCTAssertEqual(window.total, 50_000); XCTAssertEqual(window.matching, 50_000)
                XCTAssertEqual(window.rows.count, NetworkListWindow.capacity)
                let expected = min(49_999, max(0, anchor))
                XCTAssertEqual(window.row(at: expected)?.url, "http://example.test/\(expected)")
                XCTAssertNil(window.row(at: window.offset - 1))
                XCTAssertNil(window.row(at: window.offset + window.rows.count))
            }
            // Selection reads any global row, even outside the loaded window.
            XCTAssertEqual(try store.request(query: NetworkQuery(), row: 40_001)?.requestID, "40001")
            XCTAssertNil(try store.request(query: NetworkQuery(), row: 50_000))
        }, limits: limits)
    }
    func testVirtualFiltersEqualTimestampsAndLegacyDurations() throws {
        try networkFixture { _, store in
            var records = try (0..<600).map { try sampleRecord(String($0), url: $0.isMultiple(of: 2) ? "http://example.test/100%_MATCH" : "http://example.test/other", status: $0.isMultiple(of: 3) ? 500 : 200) }
            records[0].timingVersion = nil
            records[1].requestHeaders = String(repeating: "h", count: 32_768)
            try store.upsert(records)
            var query = NetworkQuery(); query.text = "100%_match"; query.status = .serverError
            let filtered = try store.listWindow(query: query, around: 99)
            XCTAssertEqual(filtered.total, 600); XCTAssertEqual(filtered.matching, 100)
            XCTAssertEqual(filtered.rows.count, 100)
            for (index, row) in filtered.rows.enumerated() {
                let selected = try store.request(query: query, row: index)
                XCTAssertEqual(selected?.id, row.id)
                XCTAssertEqual(selected?.durationMS, row.durationMS)
                XCTAssertEqual(selected?.status, 500)
            }
            let first = try store.listWindow(around: 0), second = try store.listWindow(around: 255)
            for row in second.rows {
                if let overlap = first.rows.first(where: { $0.id == row.id }) { XCTAssertEqual(overlap, row) }
            }
            let earliest = try store.listWindow(around: 0), latest = try store.listWindow(around: Int.max)
            XCTAssertEqual(earliest.rows.first?.id, records.map(\.id).max())
            XCTAssertEqual(latest.rows.last?.id, records.map(\.id).min())
            query.text = "absent"
            let empty = try store.listWindow(query: query, around: Int.max)
            XCTAssertEqual(empty.offset, 0); XCTAssertEqual(empty.matching, 0); XCTAssertTrue(empty.rows.isEmpty)
        }
    }
    func testVirtualReaderRefreshesCountsAndKeepsSelectedBodyIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runbar-network-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NetworkStore(directory: root); defer { store.close() }
        let reader = NetworkCacheReader(), query = NetworkQuery()
        let initial = try await reader.listWindow(directory: root, query: query, around: 0)
        XCTAssertEqual(initial.total, 0)
        let record = try sampleRecord("saved", start: 0)
        try store.upsert([record]); try store.saveBodies(record.id, request: Data("{}".utf8), response: Data("{\"result\":true}".utf8))
        let refreshed = try await reader.listWindow(directory: root, query: query, around: Int.max)
        XCTAssertEqual(refreshed.matching, 1)
        try store.upsert((1..<301).map { try sampleRecord(String($0), start: Int64($0)) })
        let scrolling = try await reader.listWindow(directory: root, query: query, around: 0, refreshCounts: false)
        XCTAssertEqual(scrolling.matching, 1) // Scrolling reuses one count snapshot.
        let latest = try await reader.listWindow(directory: root, query: query, around: Int.max)
        XCTAssertEqual(latest.matching, 301); XCTAssertEqual(latest.rows.count, 256)
        XCTAssertNil(latest.rows.first(where: { $0.id == record.id }))
        let loaded = try await reader.request(directory: root, query: query, row: 0)
        let selected = try XCTUnwrap(loaded)
        XCTAssertEqual(selected.bodyState, .saved)
        let body = try await reader.body(directory: root, record: selected, response: true, page: 0)
        XCTAssertEqual(body.text, "{\"result\":true}")
        var filter = query; filter.text = "missing"
        let changed = try await reader.listWindow(directory: root, query: filter, around: 0, refreshCounts: false)
        XCTAssertEqual(changed.matching, 0) // A different filter cannot reuse stale counts.
    }
    func testDatabaseCapacityFailureRollsBackBatch() throws {
        var limits = NetworkLimits(); limits.databasePages = 32
        try networkFixture({ root, store in
            let records = try (0..<100).map { index -> NetworkRecord in
                var record = try sampleRecord(String(index)); record.requestHeaders = String(repeating: "a", count: 4096); return record
            }
            XCTAssertThrowsError(try store.upsert(records)) { error in
                XCTAssertEqual((error as? NetworkStorageError)?.code, SQLITE_FULL)
                XCTAssertFalse((error as? NetworkStorageError)?.isTransient ?? true)
            }
            XCTAssertEqual(try store.page().total, 0)
            let diagnostic = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("last-error.json"))) as? [String: Any]
            XCTAssertEqual(diagnostic?["code"] as? Int, Int(SQLITE_FULL))
        }, limits: limits)
    }
    func testExternalReaderContentionPreservesCodeRollsBackAndCanRecover() throws {
        try networkFixture { root, store in
            let first = try sampleRecord("initial")
            try store.upsert([first])
            var reader: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(root.appendingPathComponent("requests.sqlite").path, &reader, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
            defer { sqlite3_close_v2(reader) }
            // A separate connection bypasses Runbar's in-process gate, as an
            // external SQLite browser would. Keep its read transaction open.
            XCTAssertEqual(sqlite3_exec(reader, "BEGIN; SELECT count(*) FROM requests;", nil, nil, nil), SQLITE_OK)
            let next = try sampleRecord("after-contention")
            XCTAssertThrowsError(try store.upsert([next])) { error in
                let failure = error as? NetworkStorageError
                XCTAssertEqual(failure?.code, SQLITE_BUSY)
                XCTAssertTrue(failure?.isTransient == true)
                XCTAssertTrue(failure?.localizedDescription.contains("SQLite 5") == true)
            }
            XCTAssertEqual(sqlite3_exec(reader, "ROLLBACK", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(try store.page().total, 1)
            let diagnostic = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("last-error.json"))) as? [String: Any]
            XCTAssertEqual(diagnostic?["code"] as? Int, Int(SQLITE_BUSY))
            // Retry the same record after the failed transaction, rather than
            // advancing its cursor or leaving a partial insert in the cache.
            try store.upsert([next]); XCTAssertEqual(try store.page().total, 2)
        }
    }
}

final class NetworkStorageRetryTests: XCTestCase {
    func testOnlyContentionRetriesAndTheBudgetIsFinite() {
        let busy = NetworkStorageError(code: SQLITE_BUSY, extendedCode: SQLITE_BUSY | (3 << 8), operation: "提交缓存事务", detail: "database is locked")
        let locked = NetworkStorageError(code: SQLITE_LOCKED, extendedCode: SQLITE_LOCKED, operation: "读取", detail: "locked")
        for failure in 1...5 {
            XCTAssertEqual(NetworkStorageRetry.delay(for: busy, failure: failure), .milliseconds(100 << (failure - 1)))
            XCTAssertNotNil(NetworkStorageRetry.delay(for: locked, failure: failure))
            XCTAssertNotNil(NetworkStorageRetry.delay(for: NetworkStorageError.accessTimeout, failure: failure))
        }
        XCTAssertNil(NetworkStorageRetry.delay(for: busy, failure: 0))
        XCTAssertNil(NetworkStorageRetry.delay(for: busy, failure: 6))
        for code in [SQLITE_FULL, SQLITE_READONLY, SQLITE_PERM, SQLITE_CANTOPEN, SQLITE_CORRUPT, SQLITE_IOERR] {
            let failure = NetworkStorageError(code: code, extendedCode: code, operation: "读取", detail: "test")
            XCTAssertNil(NetworkStorageRetry.delay(for: failure, failure: 1))
        }
        XCTAssertNil(NetworkStorageRetry.delay(for: CancellationError(), failure: 1))
    }
    func testDirectoryAliasesShareAGateWhileSeparateCachesDoNot() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = NetworkCacheAccess.shared(for: root)
        let alias = NetworkCacheAccess.shared(for: root.appendingPathComponent("unused/.."))
        XCTAssertTrue(first === alias)
        XCTAssertFalse(first === NetworkCacheAccess.shared(for: root.appendingPathComponent("other")))
    }
}

private func completedNetworkSearch(_ reader: NetworkCacheReader, directory: URL, query: NetworkQuery) async throws -> NetworkListWindow {
    for _ in 0..<200 {
        let window = try await reader.listWindow(directory: directory, query: query, around: Int.max)
        if window.counts.isComplete { return window }
        try Task.checkCancellation(); await Task.yield()
    }
    throw RunbarError.message("测试筛选未能完成。")
}

final class NetworkContentSearchTests: XCTestCase {
    func testGlobalSearchAndIndependentFieldsCombineAcrossCachedBodies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NetworkStore(directory: root); defer { store.close() }
        let reader = NetworkCacheReader()
        var a = try sampleRecord("a", start: 1, url: "http://example.test/orders")
        a.requestHeaders = "{\"Authorization\":[\"TOKEN-A\"]}"
        var b = try sampleRecord("b", start: 2, url: "http://example.test/orders"); b.requestHeaders = a.requestHeaders
        var c = try sampleRecord("c", start: 3, url: "http://example.test/other"); c.requestHeaders = "{\"Authorization\":[\"TOKEN-B\"]}"
        try store.upsert([a, b, c])
        try store.saveBodies(a.id, request: Data("{\"symbol\":\"alpha\"}".utf8), response: Data("{\"message\":\"accepted\"}".utf8))
        try store.saveBodies(b.id, request: Data("{\"symbol\":\"alpha\"}".utf8), response: Data("{\"message\":\"denied\"}".utf8))
        try store.saveBodies(c.id, request: Data("{\"symbol\":\"alpha\"}".utf8), response: Data("{\"message\":\"accepted\"}".utf8))
        var query = NetworkQuery(); query.search = "ACCEPTED"
        let global = try await completedNetworkSearch(reader, directory: root, query: query)
        XCTAssertEqual(global.rows.map(\.id), [a.id, c.id])
        query.text = "/orders"; query.headers = "token-a"; query.requestBody = "ALPHA"; query.responseBody = "accepted"
        let combined = try await completedNetworkSearch(reader, directory: root, query: query)
        XCTAssertEqual(combined.rows.map(\.id), [a.id])
        let selected = try await reader.request(directory: root, query: query, row: 0)
        XCTAssertEqual(selected?.id, a.id)
        query.search = "denied"
        let excluded = try await completedNetworkSearch(reader, directory: root, query: query)
        XCTAssertEqual(excluded.matching, 0)
        query = NetworkQuery(); query.headers = "TOKEN-A"
        let headers = try await reader.listWindow(directory: root, query: query, around: 0)
        XCTAssertEqual(headers.rows.map(\.id), [a.id, b.id])
    }
    func testIncrementalIndexSeesNewBodiesAndRemovesRowsThatStopMatching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NetworkStore(directory: root); defer { store.close() }
        let reader = NetworkCacheReader()
        var record = try sampleRecord("later")
        try store.upsert([record])
        var query = NetworkQuery(); query.responseBody = "ready"; query.status = .success
        let missing = try await completedNetworkSearch(reader, directory: root, query: query)
        XCTAssertEqual(missing.matching, 0)
        try store.saveBodies(record.id, request: Data(), response: Data("{\"state\":\"ready\"}".utf8))
        let saved = try await completedNetworkSearch(reader, directory: root, query: query)
        XCTAssertEqual(saved.matching, 1)
        record.status = 500; record.url = "http://example.test/changed"
        try store.upsert([record])
        let removed = try await completedNetworkSearch(reader, directory: root, query: query)
        XCTAssertEqual(removed.matching, 0)
        XCTAssertEqual(try store.request(record.id)?.url, record.url)
    }
    func testStreamingUTF8BoundaryFormDecodingAndURLParameters() throws {
        try networkFixture { root, store in
            var record = try sampleRecord("boundary", url: "http://example.test/api?q=hello+world")
            record.requestHeaders = "{\"Content-Type\":[\"application/x-www-form-urlencoded\"]}"
            try store.upsert([record])
            let body = String(repeating: "x", count: 65527) + "&name=%E4%BD%A0%E5%A5%BD&value=spaced+value"
            try store.saveBodies(record.id, request: Data(body.utf8), response: Data((String(repeating: "a", count: 65535) + "跨界关键词").utf8))
            record.bodyState = .saved
            var query = NetworkQuery(); query.requestBody = "你好"; query.responseBody = "跨界关键词"
            XCTAssertTrue(try NetworkContentMatcher(query: query).matches(record, directory: root))
            query.search = "hello world"
            XCTAssertTrue(try NetworkContentMatcher(query: query).matches(record, directory: root))
            query.search = "spaced value"
            XCTAssertTrue(try NetworkContentMatcher(query: query).matches(record, directory: root))
        }
    }
    func testLegacyCacheSearchIsReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NetworkStore(directory: root)
        let record = try sampleRecord("legacy")
        try store.upsert([record]); try store.saveBodies(record.id, request: Data(), response: Data("legacy-response".utf8)); store.close()
        let file = root.appendingPathComponent("requests.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER requests_search_insert; DROP TRIGGER requests_search_update; DROP INDEX requests_search_revision; ALTER TABLE requests DROP COLUMN search_revision; DELETE FROM cache_info WHERE key='search_revision';", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(db)
        let original = try Data(contentsOf: file)
        var query = NetworkQuery(); query.responseBody = "legacy-response"
        let result = try await completedNetworkSearch(NetworkCacheReader(), directory: root, query: query)
        XCTAssertEqual(result.matching, 1)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testMatchingIndexKeepsOnlyABoundedWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let index = try NetworkContentIndex(directory: root, query: NetworkQuery())
        try index.prepare(NetworkSearchSnapshot(total: 400, lastRow: 400, revision: 400, modified: .distantPast))
        for base in stride(from: 0, to: 400, by: 20) {
            let entries = try (base..<(base + 20)).map { number in
                (NetworkSearchCandidate(record: try sampleRecord(String(number), start: Int64(number)), row: Int64(number + 1), revision: Int64(number + 1)), true)
            }
            try index.apply(entries)
        }
        index.finishPass()
        let (counts, offset, ids) = try index.window(around: Int.max)
        XCTAssertEqual(counts.matching, 400); XCTAssertEqual(offset, 144); XCTAssertEqual(ids.count, 256)
    }
}

final class NetworkDetailPresentationTests: XCTestCase {
    func testJSONDefaultsAndIndependentRememberedFormatsRoundTrip() throws {
        var preferences = NetworkDetailPreferences()
        for section in NetworkDetailSection.allCases { XCTAssertEqual(preferences.format(for: section), .json) }
        preferences.setFormat(.xml, for: .request); preferences.setFormat(.raw, for: .response); preferences.wrapsLines = true
        let restored = try JSONDecoder().decode(NetworkDetailPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.format(for: .request), .xml); XCTAssertEqual(restored.format(for: .response), .raw)
        XCTAssertEqual(restored.format(for: .headers), .json); XCTAssertTrue(restored.wrapsLines)
    }
    func testHeaderAndQueryMetadataHaveJSONXMLAndRawRepresentations() throws {
        var record = try sampleRecord("formats", url: "http://example.test/a?x=1&x=2&empty")
        record.requestHeaders = "{\"x-value\":[\"a < b & c\"]}"
        for section in [NetworkDetailSection.overview, .headers, .request] {
            let json = try NetworkDetailPresentation.page(record: record, section: section, format: .json, page: 0)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.text.utf8)))
            let xml = try NetworkDetailPresentation.page(record: record, section: section, format: .xml, page: 0)
            XCTAssertNoThrow(try XMLDocument(xmlString: xml.text))
            let raw = try NetworkDetailPresentation.page(record: record, section: section, format: .raw, page: 0)
            XCTAssertFalse(raw.text.isEmpty)
        }
        try networkFixture { _, store in
            try store.upsert([record]); try store.saveBodies(record.id, request: Data(), response: Data())
            let stored = try XCTUnwrap(store.request(record.id))
            let empty = try store.bodyPage(stored, response: true, page: 0, format: .json)
            XCTAssertEqual(empty.text, ""); XCTAssertEqual(empty.bytes, 0)
        }
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

final class NetworkAdvancedFilterTests: XCTestCase {
    func testKeywordTagsPreservePhrasesAndDoNotChangeEffectiveQuery() throws {
        var query = NetworkQuery()
        query.search = "orders, hello world；accepted\nORDERS"
        let draft = query
        try query.commitKeywords(in: .everywhere)
        XCTAssertEqual(query.globalKeywords, ["orders", "hello world", "accepted"])
        XCTAssertTrue(query.hasSameConditions(as: draft))
        query.setDraft("heartbeat,error", in: .everywhere, excluding: true)
        let exclusionDraft = query
        try query.commitKeywords(in: .everywhere, excluding: true)
        XCTAssertTrue(query.hasSameConditions(as: exclusionDraft))
        XCTAssertEqual(query.keywords(in: .everywhere, excluding: true), ["heartbeat", "error"])
        query.removeKeyword("heartbeat", in: .everywhere, excluding: true)
        XCTAssertEqual(query.keywords(in: .everywhere, excluding: true), ["error"])
        query.search = (0..<17).map { "term\($0)" }.joined(separator: ",")
        XCTAssertThrowsError(try query.commitKeywords(in: .everywhere))
    }
    func testSQLMultipleIncludesThenAnyExclusion() throws {
        try networkFixture { _, store in
            var a = try sampleRecord("keep", url: "http://example.test/orders/ready")
            a.requestHeaders = "token-a application/json"
            var b = try sampleRecord("skip", url: "http://example.test/orders/heartbeat")
            b.requestHeaders = a.requestHeaders
            let c = try sampleRecord("other", url: "http://example.test/users")
            try store.upsert([a, b, c])
            var query = NetworkQuery(); query.urlKeywords = ["orders", "ready"]
            XCTAssertEqual(try store.page(query: query).records.map(\.id), [a.id])
            query.keywordMode = .any
            query.setDraft("heartbeat,missing", in: .url, excluding: true)
            XCTAssertEqual(try store.page(query: query).records.map(\.id), [a.id])
            query.headerKeywords = ["token-a", "absent"]
            XCTAssertEqual(try store.page(query: query).records.map(\.id), [a.id])
            query.keywordMode = .all
            XCTAssertEqual(try store.page(query: query).matching, 0)
            query = NetworkQuery(); query.setDraft("heartbeat", in: .url, excluding: true)
            XCTAssertEqual(Set(try store.page(query: query).records.map(\.id)), Set([a.id, c.id]))
        }
    }
    func testGlobalWordsMaySpanFieldsButExcludedResponseAlwaysWins() throws {
        try networkFixture { root, store in
            var record = try sampleRecord("spread", url: "http://example.test/orders")
            try store.upsert([record])
            try store.saveBodies(record.id, request: Data("{\"symbol\":\"alpha\"}".utf8), response: Data("{\"state\":\"accepted\",\"kind\":\"heartbeat\"}".utf8))
            record.bodyState = .saved
            var query = NetworkQuery(); query.globalKeywords = ["orders", "alpha", "accepted"]
            XCTAssertTrue(try NetworkContentMatcher(query: query).matches(record, directory: root))
            query.globalKeywords.append("absent")
            XCTAssertFalse(try NetworkContentMatcher(query: query).matches(record, directory: root))
            query.keywordMode = .any
            XCTAssertTrue(try NetworkContentMatcher(query: query).matches(record, directory: root))
            query.setDraft("missing,heartbeat", in: .response, excluding: true)
            XCTAssertFalse(try NetworkContentMatcher(query: query).matches(record, directory: root))
        }
    }
    func testJSONFieldsIgnoreFormattingAndRespectTypesPathsAndExclusions() throws {
        try networkFixture { root, store in
            var record = try sampleRecord("json")
            try store.upsert([record])
            let response = #"{"reqtype":1,"status":0,"data":{"connectionid":1,"enabled":true,"name":"a\u0062","empty":"","nil":null},"items":[{"id":2},{"id":3}],"a.b":"literal"}"#
            try store.saveBodies(record.id, request: Data(#"{"symbol":"alpha"}"#.utf8), response: Data(response.utf8))
            record.bodyState = .saved
            func match(_ path: String, _ operation: NetworkJSONCondition.Operation = .equals, _ value: String = "", exclude: Bool = false) throws -> Bool {
                var query = NetworkQuery()
                query.jsonConditions = [NetworkJSONCondition(path: path, operation: operation, value: value, isExclusion: exclude)]
                return try NetworkContentMatcher(query: query).matches(record, directory: root)
            }
            XCTAssertTrue(try match("data.connectionid", .equals, "1"))
            XCTAssertFalse(try match("data.connectionid", .equals, #""1""#))
            XCTAssertTrue(try match("$.data.enabled", .equals, "true"))
            XCTAssertFalse(try match("data.enabled", .equals, "1"))
            XCTAssertTrue(try match("data.name", .equals, "ab"))
            XCTAssertTrue(try match("data.empty", .equals, #""""#))
            XCTAssertTrue(try match("data.nil", .equals, "null"))
            XCTAssertTrue(try match("items[1].id", .equals, "3"))
            XCTAssertTrue(try match("items[*].id", .equals, "2"))
            XCTAssertFalse(try match("items[*].id", .notEquals, "2"))
            XCTAssertTrue(try match(#"["a.b"]"#, .equals, "literal"))
            XCTAssertTrue(try match("missing", .notExists))
            XCTAssertTrue(try match("missing", .notEquals, "1"))
            XCTAssertFalse(try match("data.connectionid", .equals, "1", exclude: true))
            XCTAssertTrue(try match("data.connectionid", .equals, "2", exclude: true))
            XCTAssertTrue(try match("data", .contains, "AB"))
            record.bodyState = .pending
            XCTAssertFalse(try match("data.connectionid", .equals, "1"))
            XCTAssertTrue(try match("data.connectionid", .equals, "1", exclude: true))
        }
    }
    func testJSONValidationRejectsMalformedOrExcessiveRules() throws {
        for path in ["", "data.", "data..id", "items[-1]", "items[no]", "items[0", "data]id"] {
            XCTAssertThrowsError(try NetworkJSONCondition(path: path, value: "1").validate(), path)
        }
        XCTAssertThrowsError(try NetworkJSONCondition(path: "data", value: "{}").validate())
        XCTAssertThrowsError(try NetworkJSONCondition(path: "data", value: "").validate())
        XCTAssertThrowsError(try NetworkJSONCondition(path: String(repeating: "x", count: 1025), value: "1").validate())
        let deep = Data((String(repeating: "[", count: 129) + "1" + String(repeating: "]", count: 129)).utf8)
        XCTAssertThrowsError(try NetworkBodyFormatter.validateJSONInput(deep))
    }
    func testJSONIndexReevaluatesLateBodyWithKeepAndDropRules() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NetworkStore(directory: root); defer { store.close() }
        let a = try sampleRecord("keep-json", start: 1), b = try sampleRecord("drop-json", start: 2)
        try store.upsert([a, b])
        var query = NetworkQuery()
        query.jsonConditions = [NetworkJSONCondition(path: "reqtype", value: "1"),
                                NetworkJSONCondition(path: "data.connectionid", value: "1", isExclusion: true)]
        let reader = NetworkCacheReader()
        let before = try await completedNetworkSearch(reader, directory: root, query: query)
        XCTAssertEqual(before.matching, 0)
        try store.saveBodies(a.id, request: Data(), response: Data(#"{"reqtype":1,"data":{"connectionid":2}}"#.utf8))
        try store.saveBodies(b.id, request: Data(), response: Data(#"{"reqtype":1,"data":{"connectionid":1}}"#.utf8))
        let after = try await completedNetworkSearch(reader, directory: root, query: query)
        XCTAssertEqual(after.rows.map(\.id), [a.id])
    }
}

final class NetworkFilterPreferencesTests: XCTestCase {
    private func sampleQuery() -> NetworkQuery {
        var query = NetworkQuery()
        query.search = "accepted, hello world"
        query.urlKeywords = ["/orders"]
        query.headerKeywords = ["application/json"]
        query.requestBody = "symbol,alpha"
        query.responseBody = "state,ready"
        for scope in NetworkKeywordScope.allCases {
            query.setDraft("heartbeat,ping", in: scope, excluding: true)
        }
        query.keywordMode = .any; query.method = "POST"; query.status = .success
        query.jsonConditions = [NetworkJSONCondition(path: "reqtype", value: "1"),
                                NetworkJSONCondition(path: "data.connectionid", value: "1", isExclusion: true)]
        return query
    }
    func testRestartRoundTripRestoresEveryScopePolarityAndJSONRule() throws {
        let query = sampleQuery()
        var preferences = NetworkFilterPreferences()
        try preferences.remember(query)
        try preferences.savePreset(name: "常用网络请求", query: query)
        let restored = try NetworkFilterPreferences.load(preferences.data())
        XCTAssertTrue(restored.query.hasSameConditions(as: query))
        XCTAssertEqual(restored.presets, preferences.presets)
        XCTAssertEqual(restored.query.jsonConditions, query.jsonConditions)
        XCTAssertEqual(restored.query.method, "POST"); XCTAssertEqual(restored.query.status, .success)
        for scope in NetworkKeywordScope.allCases {
            XCTAssertEqual(restored.query.draft(in: scope), "")
            XCTAssertEqual(restored.query.draft(in: scope, excluding: true), "")
            XCTAssertEqual(restored.query.keywords(in: scope, excluding: true), ["heartbeat", "ping"])
        }
        XCTAssertEqual(restored.query.globalKeywords, ["accepted", "hello world"])
        XCTAssertEqual(restored.query.requestKeywords, ["symbol", "alpha"])
    }
    func testReplacingANameKeepsIdentityAndRemovingItKeepsLiveQuery() throws {
        var preferences = NetworkFilterPreferences()
        try preferences.savePreset(name: " API ", query: sampleQuery())
        let id = try XCTUnwrap(preferences.presets.first?.id)
        var changed = NetworkQuery(); changed.urlKeywords = ["/quotes"]; changed.status = .serverError
        try preferences.savePreset(name: "api", query: changed)
        XCTAssertEqual(preferences.presets.count, 1)
        XCTAssertEqual(preferences.presets.first?.id, id)
        try preferences.remember(sampleQuery())
        try preferences.usePreset(id)
        XCTAssertTrue(preferences.query.hasSameConditions(as: changed))
        preferences.removePreset(id)
        XCTAssertTrue(preferences.presets.isEmpty)
        XCTAssertTrue(preferences.query.hasSameConditions(as: changed))
        XCTAssertThrowsError(try preferences.usePreset(id))
    }
    func testResetCurrentQueryDoesNotEraseSavedSchemes() throws {
        var preferences = NetworkFilterPreferences()
        try preferences.savePreset(name: "Keep", query: sampleQuery())
        let id = try XCTUnwrap(preferences.presets.first?.id)
        try preferences.remember(NetworkQuery())
        let restored = try NetworkFilterPreferences.load(preferences.data())
        XCTAssertTrue(restored.query.isEmpty)
        XCTAssertEqual(restored.presets.first?.id, id)
    }
    func testInvalidNamesConditionsAndExcessiveSchemeCountsDoNotMutatePreferences() throws {
        var preferences = NetworkFilterPreferences()
        for number in 0..<32 { try preferences.savePreset(name: "方案\(number)", query: NetworkQuery()) }
        let original = preferences
        XCTAssertThrowsError(try preferences.savePreset(name: "额外", query: sampleQuery()))
        XCTAssertEqual(preferences, original)
        XCTAssertThrowsError(try preferences.savePreset(name: " ", query: sampleQuery()))
        XCTAssertThrowsError(try preferences.savePreset(name: String(repeating: "a", count: 81), query: sampleQuery()))
        var invalid = NetworkQuery(); invalid.search = (0..<17).map { "term\($0)" }.joined(separator: ",")
        XCTAssertThrowsError(try preferences.savePreset(name: "方案0", query: invalid))
        invalid = NetworkQuery(); invalid.jsonConditions = [NetworkJSONCondition(path: "data.", value: "1")]
        XCTAssertThrowsError(try preferences.remember(invalid))
        XCTAssertEqual(preferences, original)
        try preferences.savePreset(name: "方案0", query: sampleQuery())
        XCTAssertEqual(preferences.presets.count, 32)
    }
    func testPreferenceByteBudgetIsEnforcedWithoutDroppingExistingSchemes() throws {
        var query = NetworkQuery()
        let words = (0..<16).map { String(repeating: "🚀", count: 700) + String(format: "%02d", $0) }
        for scope in NetworkKeywordScope.allCases {
            query.setKeywords(words, in: scope); query.setKeywords(words, in: scope, excluding: true)
        }
        var preferences = NetworkFilterPreferences()
        try preferences.savePreset(name: "Large", query: query)
        let original = preferences
        XCTAssertThrowsError(try preferences.savePreset(name: "Second", query: query))
        XCTAssertEqual(preferences, original)
        XCTAssertThrowsError(try NetworkFilterPreferences.load(Data(repeating: 32, count: NetworkFilterPreferences.byteLimit + 1)))
        XCTAssertThrowsError(try NetworkFilterPreferences.load(Data(#"{"version":2}"#.utf8)))
        XCTAssertTrue(try NetworkFilterPreferences.load(Data("{}".utf8)).query.isEmpty)
    }
}

private final class NetworkDiskFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64?
    init(_ bytes: Int64?) { self.bytes = bytes }
    func set(_ bytes: Int64?) { lock.lock(); defer { lock.unlock() }; self.bytes = bytes }
    func available(_ directory: URL) -> Int64? { lock.lock(); defer { lock.unlock() }; return bytes }
}

final class NetworkDiskCapacityTests: XCTestCase {
    func testExistingCappedDatabaseCanGrowAfterReopeningWithDefaultsWithoutDataLoss() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var oldLimits = NetworkLimits(); oldLimits.databasePages = 32
        let original = try NetworkStore(directory: root, limits: oldLimits)
        let first = try sampleRecord("existing")
        try original.upsert([first])
        let batch = try (0..<100).map { number -> NetworkRecord in
            var record = try sampleRecord("new-\(number)")
            record.requestHeaders = String(repeating: "x", count: 4096)
            return record
        }
        XCTAssertThrowsError(try original.upsert(batch)) { error in
            XCTAssertEqual((error as? NetworkStorageError)?.code, SQLITE_FULL)
            XCTAssertEqual((error as? NetworkStorageError)?.databasePageLimit, 32)
        }
        XCTAssertEqual(try original.page().total, 1)
        original.close()
        let upgraded = try NetworkStore(directory: root); defer { upgraded.close() }
        try upgraded.upsert(batch)
        XCTAssertEqual(try upgraded.page().total, 101)
        XCTAssertEqual(try upgraded.request(first.id)?.url, first.url)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("requests.sqlite").path)[.size] as? NSNumber)
        XCTAssertGreaterThan(size.intValue, 32 * 4096)
    }
    func testActualDiskReservePausesBeforeBatchAndCanResumeAfterSpaceReturns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = NetworkDiskFixture(8 * 1024 * 1024 * 1024)
        let store = try NetworkStore(directory: root, diskSpace: { disk.available($0) }); defer { store.close() }
        let first = try sampleRecord("first"), second = try sampleRecord("later")
        try store.upsert([first])
        disk.set(100 * 1024 * 1024)
        XCTAssertThrowsError(try store.upsert([second])) { error in
            let failure = error as? NetworkStorageError
            XCTAssertTrue(failure?.spaceProtection == true)
            XCTAssertNil(failure?.code) // This guard did not get a SQLite FULL result.
            XCTAssertFalse(failure?.isTransient ?? true)
            XCTAssertNil(NetworkStorageRetry.delay(for: error, failure: 1))
            XCTAssertEqual(failure?.availableDiskBytes, 100 * 1024 * 1024)
        }
        XCTAssertEqual(try store.page().total, 1)
        let diagnostic = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("last-error.json"))) as? [String: Any]
        XCTAssertEqual(diagnostic?["spaceProtection"] as? Bool, true)
        XCTAssertEqual(diagnostic?["availableDiskBytes"] as? Int64, 100 * 1024 * 1024)
        let reader = try NetworkStore(directory: root, readOnly: true, diskSpace: { disk.available($0) })
        XCTAssertEqual(try reader.page().total, 1); reader.close()
        disk.set(8 * 1024 * 1024 * 1024)
        try store.upsert([second]); XCTAssertEqual(try store.page().total, 2)
    }
    func testBodyDiskCheckPreservesPendingStateAndCanRecover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = NetworkDiskFixture(8 * 1024 * 1024 * 1024)
        let store = try NetworkStore(directory: root, diskSpace: { disk.available($0) }); defer { store.close() }
        let record = try sampleRecord("body")
        try store.upsert([record])
        disk.set(0)
        XCTAssertThrowsError(try store.saveBodies(record.id, request: Data("{}".utf8), response: Data("{}".utf8)))
        XCTAssertEqual(try store.request(record.id)?.bodyState, .pending)
        disk.set(nil) // Unknown capacity must not be misreported as no free space.
        try store.saveBodies(record.id, request: Data("{}".utf8), response: Data("{}".utf8))
        XCTAssertEqual(try store.request(record.id)?.bodyState, .saved)
    }
}
