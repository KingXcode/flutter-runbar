import XCTest
import CSQLite
@testable import RunbarCore

final class ProxyCaptureTests: XCTestCase {
    func testCertificateGuideRejectsPrivateKeyFilesAndOversizedInput() throws {
        let publicWithPrivateKey = Data("-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----".utf8)
        XCTAssertThrowsError(try ProxyCertificate(data: publicWithPrivateKey))
        XCTAssertThrowsError(try ProxyCertificate(data: Data(repeating: 65, count: ProxyCertificate.maximumBytes + 1)))
        XCTAssertThrowsError(try ProxyCertificate(data: Data()))
        XCTAssertThrowsError(try ProxyCertificate(data: Data("not a certificate".utf8)))
        let sliced = Data([0xff, 0x30, 0x00])[1...]
        XCTAssertThrowsError(try ProxyCertificate(data: sliced))
    }
    func testMissingCertificateDoesNotClaimSystemTrust() throws {
        let status = ProxyCertificateStatus.read(from: try temporary().appendingPathComponent("missing.cer"))
        XCTAssertEqual(status.state, .missing)
        XCTAssertNil(status.certificate)
    }
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runbar-proxy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func event(_ id: Int64, kind: ProxyWebSocketEvent.Kind = .receive, payload: Data = Data(), opcode: Int = 1) -> ProxyWebSocketEvent {
        ProxyWebSocketEvent(id: id, flowID: "connection-1", url: "wss://example.invalid/quotes",
            timestamp: 1_700_000_000_000_000 + id, kind: kind, opcode: opcode,
            bytes: Int64(payload.count), payload: payload, note: "", closeCode: nil,
            requestHeaders: kind == .open ? "{\"Origin\":[\"test\"]}" : nil,
            responseHeaders: kind == .open ? "{\"Upgrade\":[\"websocket\"]}" : nil)
    }
    func testBundledEngineSelectionAndExplicitOverrideWithoutLaunchingEitherExecutable() throws {
        let directory = try temporary(), app = directory.appendingPathComponent("Runbar.app")
        let architecture = ProxyLaunchConfiguration.currentArchitecture
        let relative = "Helpers/RunbarProxy-\(architecture).app/Contents/MacOS/mitmdump"
        let executable = app.appendingPathComponent("Contents/" + relative)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let manifest = app.appendingPathComponent("Contents/Resources/ProxyEngine/manifest.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        func writeManifest(_ path: String) throws {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "product": "mitmproxy", "version": "12.3.1",
                "architectures": [architecture: ["executable": path]]]).write(to: manifest)
        }
        try writeManifest(relative)
        let bundled = try XCTUnwrap(ProxyLaunchConfiguration.bundledEngine(in: app))
        XCTAssertEqual(bundled.version, "12.3.1")
        XCTAssertEqual(bundled.architecture, architecture)
        XCTAssertEqual(ProxyLaunchConfiguration.findExecutable(bundle: app), executable)
        let custom = directory.appendingPathComponent("custom-mitmdump")
        try FileManager.default.copyItem(at: executable, to: custom)
        XCTAssertEqual(ProxyLaunchConfiguration.findExecutable(preferred: custom.path, bundle: app), custom)
        XCTAssertNil(ProxyLaunchConfiguration.findExecutable(preferred: directory.appendingPathComponent("missing").path, bundle: app))
        try writeManifest("../../untrusted-mitmdump")
        XCTAssertNil(ProxyLaunchConfiguration.bundledEngine(in: app))
        try writeManifest(relative)
        try FileManager.default.removeItem(at: executable)
        XCTAssertNil(ProxyLaunchConfiguration.bundledEngine(in: app))
    }
    func testOldProjectAndHistoryDecodeWithoutProxyAndNewSettingsRoundTrip() throws {
        var project = Project(path: "/tmp/example", kind: .flutter)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        object.removeValue(forKey: "proxyCapture")
        let legacy = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.proxyCapture)
        project.proxyCapture = ProxyProjectOptions(enabled: true, decryptTLS: false)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)).proxyCapture, project.proxyCapture)
        let session = RunSession(projectPath: project.path, command: "fvm flutter run -d macos")
        XCTAssertNil(try JSONDecoder().decode(RunSession.self, from: JSONEncoder().encode(session)).proxyCapture)
    }
    func testIncrementalPipeDecoderHandlesSplitUnicodeBase64AndUnrelatedOutput() throws {
        var decoder = ProxyWireDecoder()
        let socket = event(1, kind: .send, payload: Data("{\"订阅\":\"行情\"}".utf8))
        let encoded = try JSONEncoder().encode(socket)
        var input = Data("engine diagnostic\nRUNBAR_CAPTURE_V1 {\"type\":\"websocket\",\"socket\":".utf8)
        input.append(encoded); input.append(Data("}\nRUNBAR_CAPTURE_V1 {\"type\":\"ready\",\"port\":32123}\n".utf8))
        var result: [ProxyWireEvent] = []
        for offset in stride(from: 0, to: input.count, by: 7) {
            try decoder.consume(input.subdata(in: offset..<min(offset + 7, input.count))) { result.append($0) }
        }
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.socket, socket)
        XCTAssertEqual(result.last?.port, 32123)
    }
    func testOversizedPipeLineFailsWithoutAccumulatingAnUnboundedBuffer() throws {
        var decoder = ProxyWireDecoder()
        let chunk = Data(repeating: 65, count: 16_384)
        for _ in 0..<(ProxyWireDecoder.lineLimit / chunk.count) { try decoder.consume(chunk) { _ in XCTFail("not a complete line") } }
        XCTAssertThrowsError(try decoder.consume(Data([65])) { _ in })
    }
    func testWebSocketWindowStartsAtLatestAndLoadsAnyEarlierRange() throws {
        let store = try ProxyWebSocketStore(directory: temporary())
        defer { store.close() }
        for id in 1...600 { try store.append(event(Int64(id), kind: id == 1 ? .open : .receive)) }
        let latest = try store.window(url: "", kind: "", around: .max)
        XCTAssertEqual(latest.total, 600)
        XCTAssertEqual(latest.rows.count, 256)
        XCTAssertEqual(latest.offset, 344)
        XCTAssertEqual(latest.rows.first?.id, 345)
        XCTAssertEqual(latest.rows.last?.id, 600)
        let earliest = try store.window(url: "", kind: "", around: 0)
        XCTAssertEqual(earliest.rows.first?.id, 1)
        let filtered = try store.window(url: "QUOTES", kind: "open", around: .max)
        XCTAssertEqual(filtered.total, 1)
        XCTAssertEqual(filtered.rows.first?.id, 1)
    }
    func testSummaryDoesNotReadPayloadAndDetailRejectsOversizedCache() throws {
        let directory = try temporary(), store = try ProxyWebSocketStore(directory: directory)
        defer { store.close() }
        try store.append(event(1))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("websockets.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE events SET payload=zeroblob(1048577) WHERE id=1", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try store.window(url: "", kind: "", around: .max).rows.count, 1)
        XCTAssertThrowsError(try store.event(1))
    }
    func testSelectedMessageFormatsJSONAndBinaryIsExplicitBase64() async throws {
        let directory = try temporary(), store = try ProxyWebSocketStore(directory: directory)
        try store.append(event(1, kind: .open))
        try store.append(event(2, kind: .send, payload: Data("{\"subscribe\":\"quotes\",\"large\":9007199254740993}".utf8)))
        let binary = Data([0, 255, 128])
        try store.append(event(3, payload: binary, opcode: 2)); store.close()
        let reader = ProxyWebSocketReader()
        let json = try await reader.detail(directory: directory, id: 2, metadata: false, format: .json, page: 0)
        XCTAssertTrue(json.text.contains("\n"))
        XCTAssertTrue(json.text.contains("9007199254740993"))
        let raw = try await reader.detail(directory: directory, id: 3, metadata: false, format: .json, page: 0)
        XCTAssertEqual(raw.text, binary.base64EncodedString())
        XCTAssertTrue(raw.note.contains("Base64"))
        let metadata = try await reader.detail(directory: directory, id: 2, metadata: true, format: .json, page: 0)
        XCTAssertTrue(metadata.text.contains("Origin"))
        XCTAssertTrue(metadata.text.contains("connection-1"))
    }
    func testConnectionsGroupReconnectsByExactURLAndMessagesOnlyIncludeSendReceive() async throws {
        let directory = try temporary(), store = try ProxyWebSocketStore(directory: directory)
        let url = "wss://example.invalid/quotes?channel='A'"
        var opened = event(1, kind: .open); opened.url = url
        var sent = event(2, kind: .send, payload: Data("{\"subscribe\":true}".utf8)); sent.url = url
        var other = event(3, payload: Data("other".utf8)); other.url = url + "-other"; other.flowID = "other"
        var reconnected = event(4); reconnected.url = url; reconnected.flowID = "connection-2"
        var received = event(5, payload: Data("{\"price\":12.34}".utf8)); received.url = url
        var closed = event(6, kind: .close); closed.url = url; closed.closeCode = 1000; closed.note = "normal closure"
        for value in [opened, sent, other, reconnected, received, closed] { try store.append(value) }
        store.close()
        let reader = ProxyWebSocketReader()
        let connections = try await reader.connections(directory: directory, filter: "QUOTES", around: 0)
        XCTAssertEqual(connections.total, 2)
        XCTAssertEqual(Set(connections.urls), [url, other.url])
        let messages = try await reader.messages(directory: directory, url: url, kind: "", around: .max)
        XCTAssertEqual(messages.rows.map(\.id), [2, 4, 5])
        XCTAssertEqual(messages.rows.first?.preview, "{\"subscribe\":true}")
        let sends = try await reader.messages(directory: directory, url: url, kind: "send", around: .max)
        XCTAssertEqual(sends.rows.map(\.id), [2])
        let receives = try await reader.messages(directory: directory, url: url, kind: "receive", around: .max)
        XCTAssertEqual(receives.rows.map(\.id), [4, 5])
        let metadata = try await reader.detail(directory: directory, id: 2, metadata: true, format: .json, page: 0)
        XCTAssertTrue(metadata.text.contains("normal closure"))
        XCTAssertTrue(metadata.text.contains("1000"))
        let differentConnection = try await reader.detail(directory: directory, id: 4, metadata: true, format: .json, page: 0)
        XCTAssertFalse(differentConnection.text.contains("normal closure"))
    }
    func testMessagePreviewIsBoundedAndFullJSONRemainsAvailableOnSelection() async throws {
        let directory = try temporary(), store = try ProxyWebSocketStore(directory: directory)
        let payload = Data(("{\"value\":\"" + String(repeating: "x", count: 2000) + "tail-only\"}").utf8)
        try store.append(event(1, payload: payload))
        try store.append(event(2, payload: Data([0, 255]), opcode: 2)); store.close()
        let reader = ProxyWebSocketReader()
        let messages = try await reader.messages(directory: directory, url: "wss://example.invalid/quotes", kind: "", around: .max)
        XCTAssertLessThan(try XCTUnwrap(messages.rows.first?.preview.utf8.count), 600)
        XCTAssertFalse(try XCTUnwrap(messages.rows.first?.preview.contains("tail-only")))
        XCTAssertTrue(try XCTUnwrap(messages.rows.last?.preview.contains("二进制 / Base64")))
        let detail = try await reader.detail(directory: directory, id: 1, metadata: false, format: .json, page: 0)
        XCTAssertTrue(detail.text.contains("tail-only"))
        XCTAssertTrue(detail.text.contains("\n"))
    }
    func testMessageWindowsRemainBoundedAcrossEntireHistoryOfSelectedURL() async throws {
        let directory = try temporary(), store = try ProxyWebSocketStore(directory: directory)
        for id in 1...600 { try store.append(event(Int64(id), payload: Data("row \(id)".utf8))) }
        store.close()
        let reader = ProxyWebSocketReader(), url = "wss://example.invalid/quotes"
        let latest = try await reader.messages(directory: directory, url: url, kind: "", around: .max)
        XCTAssertEqual(latest.total, 600)
        XCTAssertEqual(latest.rows.count, 256)
        XCTAssertEqual(latest.rows.first?.id, 345)
        XCTAssertEqual(latest.rows.last?.id, 600)
        let earliest = try await reader.messages(directory: directory, url: url, kind: "", around: 0)
        XCTAssertEqual(earliest.rows.count, 256)
        XCTAssertEqual(earliest.rows.first?.id, 1)
    }
    private func searched(_ reader: ProxyWebSocketReader, directory: URL, filter: ProxyWebSocketFilter,
                          url: String = "wss://example.invalid/quotes", kind: String = "") async throws -> ProxyWebSocketWindow {
        for _ in 0..<2000 {
            let result = try await reader.messages(directory: directory, url: url, kind: kind, around: .max, filter: filter)
            if result.isComplete { return result }
        }
        XCTFail("WebSocket search did not finish its bounded slices")
        return .empty
    }
    func testWebSocketSearchReadsBeyondPreviewAndAcrossUTF8ChunkBoundaries() async throws {
        let directory = try temporary(), store = try ProxyWebSocketStore(directory: directory)
        let payload = String(repeating: "x", count: 63 * 1024 - 2) + "跨界关键词" + String(repeating: "z", count: 80_000) + "尾部 Match"
        try store.append(event(1, payload: Data(payload.utf8)))
        try store.append(event(2, payload: Data("preview-only Match".utf8))); store.close()
        var filter = ProxyWebSocketFilter(); filter.search = "跨界关键词"; filter.includes = "尾部, mAtCh"
        let reader = ProxyWebSocketReader()
        let result = try await searched(reader, directory: directory, filter: filter)
        XCTAssertEqual(result.rows.map(\.id), [1])
        XCTAssertEqual(result.sourceTotal, 2)
        XCTAssertFalse(try XCTUnwrap(result.rows.first?.preview).contains("尾部"))
        XCTAssertLessThan(try XCTUnwrap(result.rows.first?.preview.utf8.count), 600)
        filter.excludes = "尾部"
        let excluded = try await searched(reader, directory: directory, filter: filter)
        XCTAssertEqual(excluded.total, 0)
    }
    func testWebSocketIncludesAnyAllAndExclusionPrecedence() async throws {
        let directory = try temporary(), store = try ProxyWebSocketStore(directory: directory)
        for (index, text) in ["quote stock heartbeat", "QUOTE STOCK ok", "quote future", "other"].enumerated() {
            try store.append(event(Int64(index + 1), payload: Data(text.utf8)))
        }
        var other = event(5, kind: .send, payload: Data("quote stock".utf8)); other.url += "/other"
        try store.append(other); store.close()
        var filter = ProxyWebSocketFilter(); filter.includes = "quote，stock"; filter.excludes = "heartbeat; ping"
        let reader = ProxyWebSocketReader()
        let all = try await searched(reader, directory: directory, filter: filter)
        XCTAssertEqual(all.rows.map(\.id), [2])
        XCTAssertEqual(all.sourceTotal, 4)
        filter.mode = .any
        let any = try await searched(reader, directory: directory, filter: filter)
        XCTAssertEqual(any.rows.map(\.id), [2, 3])
        filter.includes = ""
        let exclusionOnly = try await searched(reader, directory: directory, filter: filter)
        XCTAssertEqual(exclusionOnly.rows.map(\.id), [2, 3, 4])
        filter.search = "future"
        let search = try await searched(reader, directory: directory, filter: filter)
        XCTAssertEqual(search.rows.map(\.id), [3])
        let sends = try await searched(reader, directory: directory, filter: filter, kind: "send")
        XCTAssertEqual(sends.total, 0)
        let otherURL = try await searched(reader, directory: directory, filter: ProxyWebSocketFilter(), url: other.url)
        XCTAssertEqual(otherURL.rows.map(\.id), [5])
    }
    func testBinaryWebSocketSearchUsesDisplayedBase64AcrossChunkBoundaries() async throws {
        let directory = try temporary(), store = try ProxyWebSocketStore(directory: directory)
        var bytes = Data(repeating: 1, count: 63 * 1024 - 3)
        bytes.append(contentsOf: [254, 253, 252, 251, 250, 249, 248])
        try store.append(event(1, payload: bytes, opcode: 2)); store.close()
        let base64 = bytes.base64EncodedString()
        var filter = ProxyWebSocketFilter()
        filter.search = String(base64.dropFirst(63 * 1024 / 3 * 4 - 8).prefix(16))
        let result = try await searched(ProxyWebSocketReader(), directory: directory, filter: filter)
        XCTAssertEqual(result.rows.map(\.id), [1])
    }
    func testWebSocketSearchIndexIsBoundedIncrementalAndAnchorsOlderMatches() throws {
        let directory = try temporary(), store = try ProxyWebSocketStore(directory: directory)
        defer { store.close() }
        for id in 1...600 { try store.append(event(Int64(id), payload: Data("needle \(id)".utf8))) }
        var filter = ProxyWebSocketFilter(); filter.search = "needle"
        let index = try ProxyWebSocketSearchIndex(directory: directory, url: "wss://example.invalid/quotes", kind: "", filter: filter)
        try index.scanSlice(store)
        XCTAssertFalse(index.isComplete)
        XCTAssertLessThanOrEqual(index.scannedMessages, 512)
        let first = try index.window(around: .max, anchorID: nil)
        XCTAssertEqual(first.ids.last, 600)
        XCTAssertLessThanOrEqual(first.ids.count, 256)
        let anchorID = try XCTUnwrap(first.ids.first)
        for _ in 0..<100 where !index.isComplete { try index.scanSlice(store) }
        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.scannedMessages, 600)
        let anchored = try index.window(around: 0, anchorID: anchorID)
        XCTAssertEqual(anchored.anchor, Int(anchorID - 1))
        let earliest = try index.window(around: 0, anchorID: nil)
        XCTAssertEqual(earliest.ids.first, 1)
        try index.scanSlice(store)
        XCTAssertEqual(index.scannedMessages, 600)
        try store.append(event(601, payload: Data("needle newest".utf8)))
        try store.append(event(602, payload: Data("ignored".utf8)))
        for _ in 0..<100 {
            try index.scanSlice(store)
            if index.isComplete { break }
        }
        XCTAssertEqual(index.sourceTotal, 602)
        XCTAssertEqual(index.scannedMessages, 602)
        let latest = try index.window(around: .max, anchorID: nil)
        XCTAssertEqual(latest.total, 601)
        XCTAssertEqual(latest.ids.last, 601)
        XCTAssertEqual(latest.ids.count, 256)
    }
    func testWebSocketFiltersAreCodableBoundedAndTreatSearchLiterally() async throws {
        var filter = ProxyWebSocketFilter(); filter.includes = "key,值"; filter.excludes = "heartbeat"; filter.mode = .any
        XCTAssertEqual(try JSONDecoder().decode(ProxyWebSocketFilter.self, from: JSONEncoder().encode(filter)), filter)
        XCTAssertEqual(filter.conditionCount, 3)
        filter.includes = (0..<17).map { "word\($0)" }.joined(separator: ",")
        XCTAssertThrowsError(try filter.validate())
        filter.includes = String(repeating: "a", count: 1025)
        XCTAssertThrowsError(try filter.validate())
        let directory = try temporary(), store = try ProxyWebSocketStore(directory: directory)
        try store.append(event(1, payload: Data("a.* b' OR 1=1 --".utf8)))
        try store.append(event(2, payload: Data("aaa".utf8))); store.close()
        filter = ProxyWebSocketFilter(); filter.search = "a.* b' OR 1=1 --"
        let literal = try await searched(ProxyWebSocketReader(), directory: directory, filter: filter)
        XCTAssertEqual(literal.rows.map(\.id), [1])
    }
    func testDuplicateEventRollbackDoesNotAddAnUnrelatedConnectionURL() throws {
        let store = try ProxyWebSocketStore(directory: temporary())
        defer { store.close() }
        try store.append(event(1))
        var duplicate = event(1); duplicate.url = "wss://not-inserted.invalid"
        XCTAssertThrowsError(try store.append(duplicate))
        let connections = try store.connections(filter: "", around: 0)
        XCTAssertEqual(connections.total, 1)
        XCTAssertEqual(connections.urls, ["wss://example.invalid/quotes"])
    }
    func testSameURLFlowsKeepSeparateStatusAndMessagesInCurrentAndLegacyCaches() async throws {
        let directory = try temporary(), store = try ProxyWebSocketStore(directory: directory)
        let url = event(1).url
        for (id, flow, kind) in [(1, "first", ProxyWebSocketEvent.Kind.open), (2, "second", .open),
                                 (3, "first", .receive), (4, "second", .receive), (5, "first", .close)] {
            var row = event(Int64(id), kind: kind, payload: Data("shared payload".utf8))
            row.flowID = flow
            try store.append(row)
        }
        store.close()
        let reader = ProxyWebSocketReader()
        for legacy in [false, true] {
            if legacy {
                var db: OpaquePointer?
                XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("websockets.sqlite").path, &db), SQLITE_OK)
                XCTAssertEqual(sqlite3_exec(db, "DROP TABLE connection_flows", nil, nil, nil), SQLITE_OK)
                sqlite3_close(db)
            }
            let live = try await reader.flows(directory: directory, filter: "quotes", around: 0, running: true)
            XCTAssertEqual(live.rows.map(\.id), ["second", "first"])
            XCTAssertEqual(live.rows.map(\.state), [.connected, .closed])
            let history = try await reader.flows(directory: directory, filter: "", around: 0, running: false)
            XCTAssertEqual(history.rows.map(\.state), [.closed, .closed])

            let messages = try await reader.messages(directory: directory, url: url, kind: "", around: .max, flowID: "first")
            XCTAssertEqual(messages.rows.map(\.id), [3])
            var filter = ProxyWebSocketFilter()
            filter.search = "shared payload"
            for (flow, id) in [("second", Int64(4)), ("first", Int64(3))] {
                let matches = try await reader.messages(directory: directory, url: url, kind: "receive",
                    around: .max, filter: filter, flowID: flow)
                XCTAssertEqual(matches.sourceTotal, 1)
                XCTAssertEqual(matches.rows.map(\.id), [id])
            }
        }
    }
    func testGroupedTimelineKeepsLifecycleEventsDuringMessageFiltering() async throws {
        let directory = try temporary(), store = try ProxyWebSocketStore(directory: directory)
        let url = event(1).url
        for (id, flow, kind) in [(1, "first", ProxyWebSocketEvent.Kind.open), (2, "first", .send),
                                 (3, "first", .close), (4, "second", .open), (5, "second", .receive)] {
            var row = event(Int64(id), kind: kind, payload: Data("message".utf8))
            row.flowID = flow
            if kind == .close { row.closeCode = 1000; row.note = "normal closure" }
            try store.append(row)
        }
        store.close()
        let reader = ProxyWebSocketReader()
        let flows = try await reader.flows(directory: directory, filter: "", around: 0, running: false)
        let first = try XCTUnwrap(flows.rows.first { $0.id == "first" })
        XCTAssertEqual(first.openedAt, event(1).date)
        XCTAssertEqual(first.closedAt, event(3).date)
        XCTAssertEqual(first.closeCode, 1000)
        XCTAssertEqual(first.closeReason, "normal closure")

        let groups = try await reader.flows(directory: directory, filter: "", around: 0, running: false, grouped: true)
        XCTAssertEqual(groups.total, 1)
        XCTAssertEqual(groups.rows.map(\.url), [url])
        let timeline = try await reader.messages(directory: directory, url: url, kind: "receive",
            around: .max, includeLifecycle: true)
        XCTAssertEqual(timeline.rows.map(\.id), [1, 3, 4, 5])
        var filter = ProxyWebSocketFilter()
        filter.search = "unmatched"
        let filtered = try await reader.messages(directory: directory, url: url, kind: "receive",
            around: .max, filter: filter, includeLifecycle: true)
        XCTAssertEqual(filtered.rows.map(\.id), [1, 3, 4])
        let individual = try await reader.messages(directory: directory, url: url, kind: "receive",
            around: .max, filter: filter, flowID: "second")
        XCTAssertTrue(individual.rows.isEmpty)
    }
    func testLegacyReadOnlyCacheListsConnectionsWithoutWritingAnIndex() async throws {
        let directory = try temporary(), store = try ProxyWebSocketStore(directory: directory)
        try store.append(event(1, kind: .open)); try store.append(event(2)); store.close()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("websockets.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE connection_urls", nil, nil, nil), SQLITE_OK)
        let reader = ProxyWebSocketReader()
        let connections = try await reader.connections(directory: directory, filter: "", around: 0)
        XCTAssertEqual(connections.urls, ["wss://example.invalid/quotes"])
        let messages = try await reader.messages(directory: directory, url: "wss://example.invalid/quotes", kind: "", around: .max)
        XCTAssertEqual(messages.rows.map(\.id), [2])
        var filter = ProxyWebSocketFilter(); filter.excludes = "heartbeat"
        let filtered = try await searched(reader, directory: directory, filter: filter)
        XCTAssertEqual(filtered.rows.map(\.id), [2])
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE name='connection_urls'", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
    func testMacOSLaunchPreflightDoesNotTreatAttachBuildMobileOrCompoundCommandsAsLaunches() {
        for command in ["fvm flutter run -d macos", "flutter run --device-id=macos --profile", "env TEST=1 fvm exec flutter -v run -dmacos"] {
            XCTAssertTrue(FlutterMacOSLaunch.isRequested(by: command), command)
        }
        for command in ["flutter attach -d macos", "flutter build macos", "flutter run -d android", "flutter run -d macos --help",
                        "flutter run -d macos; echo done", "flutter run -- --device-id=macos", "flutter run -d macos --device-id=android"] {
            XCTAssertFalse(FlutterMacOSLaunch.isRequested(by: command), command)
        }
    }
}
