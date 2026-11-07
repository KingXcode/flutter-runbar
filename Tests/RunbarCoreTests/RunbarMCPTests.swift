import XCTest
import CSQLite
@testable import RunbarCore

final class RunbarMCPTests: XCTestCase {
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func object(_ value: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: value) as? [String: Any]) }
    private func fixture() throws -> (URL, SessionStore, RunSession, RunbarMCPDataSource) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runbar-mcp-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = RunSession(projectPath: "/fixture", command: "echo fixture")
        session.status = .succeeded; try store.save(session)
        let snapshot = RunbarMCPSnapshot(sources: [RunbarMCPSource(id: "project:fixture", key: "/fixture", name: "fixture", path: "/fixture", kind: "generic")], sessions: [session])
        let source = RunbarMCPDataSource(root: root) { snapshot }
        return (root, store, session, source)
    }
    func testInitializeNegotiatesVersionAndAdvertisesOnlyReadOnlyTools() async throws {
        let request = try data(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2099-01-01", "capabilities": [:], "clientInfo": ["name": "fixture", "version": "1"]]])
        let reply = await RunbarMCPProtocol.respond(to: request, protocolVersion: nil, serverVersion: "fixture") { _, _ in XCTFail("no tool invocation"); return Data() }
        let result = try XCTUnwrap(object(reply.body)["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
        XCTAssertTrue((result["instructions"] as? String)?.contains("untrusted data") == true)
        XCTAssertEqual(RunbarMCPProtocol.tools().count, 12)
        XCTAssertTrue(Set(RunbarMCPWebSocketDataSource.names).isSubset(of: Set(RunbarMCPProtocol.names)))
        for tool in RunbarMCPProtocol.tools() {
            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Bool])
            XCTAssertEqual(annotations["readOnlyHint"], true); XCTAssertEqual(annotations["openWorldHint"], false)
            XCTAssertEqual(annotations["destructiveHint"], false)
        }
    }
    func testNotificationsMalformedRequestsAndUnknownToolsNeverDispatch() async throws {
        for request in [["jsonrpc": "2.0", "method": "tools/call", "params": ["name": "runbar_read_logs"]],
                        ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "run_command"]]] as [[String: Any]] {
            let reply = await RunbarMCPProtocol.respond(to: try data(request), protocolVersion: nil, serverVersion: "fixture") { _, _ in XCTFail("must not execute"); return Data() }
            XCTAssertTrue(reply.status == 202 || (try? object(reply.body)["error"]) != nil)
        }
        let invalid = await RunbarMCPProtocol.respond(to: Data("[{}]".utf8), protocolVersion: nil, serverVersion: "fixture") { _, _ in Data() }
        XCTAssertEqual(invalid.status, 400)
        let tooLarge = await RunbarMCPProtocol.respond(to: Data(repeating: 32, count: RunbarMCPProtocol.requestLimit + 1), protocolVersion: nil, serverVersion: "fixture") { _, _ in Data() }
        XCTAssertEqual(tooLarge.status, 413)
    }
    private func frame(body: Data, host: String = "127.0.0.1:47821", token: String = "fixture-token", origin: String? = nil, chunked: Bool = false) -> Data {
        var text = "POST /mcp HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\n"
        if let origin { text += "Origin: \(origin)\r\n" }
        if chunked { return Data((text + "Transfer-Encoding: chunked\r\n\r\n" + String(body.count, radix: 16) + "\r\n").utf8) + body + Data("\r\n0\r\n\r\n".utf8) }
        return Data((text + "Content-Length: \(body.count)\r\n\r\n").utf8) + body
    }
    func testHTTPAuthenticationOriginFramingAndChunkedCompatibility() throws {
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}".utf8)
        XCTAssertEqual(try RunbarMCPHTTP.request(frame(body: body), port: 47821, token: "fixture-token")?.body, body)
        XCTAssertEqual(try RunbarMCPHTTP.request(frame(body: body, chunked: true), port: 47821, token: "fixture-token")?.body, body)
        XCTAssertNil(try RunbarMCPHTTP.request(Data(frame(body: body).dropLast()), port: 47821, token: "fixture-token"))
        for (value, status) in [(frame(body: body, token: "wrong"), 401), (frame(body: body, host: "evil.example:47821"), 403), (frame(body: body, origin: "https://evil.example"), 403)] {
            XCTAssertThrowsError(try RunbarMCPHTTP.request(value, port: 47821, token: "fixture-token")) { XCTAssertEqual(($0 as? RunbarMCPHTTPError)?.status, status) }
        }
        let ambiguous = String(decoding: frame(body: body, chunked: true), as: UTF8.self).replacingOccurrences(of: "Transfer-Encoding:", with: "Content-Length: 1\r\nTransfer-Encoding:")
        XCTAssertThrowsError(try RunbarMCPHTTP.request(Data(ambiguous.utf8), port: 47821, token: "fixture-token"))
        XCTAssertThrowsError(try RunbarMCPHTTP.request(Data(repeating: 32, count: RunbarMCPHTTP.frameLimit + 1), port: 47821, token: "fixture-token"))
    }
    func testLogPagingAndSearchAcrossReadBoundaryPreserveOriginal() async throws {
        let (_, store, session, source) = try fixture(), file = store.directory(session.id).appendingPathComponent("output.raw")
        let bytes = Data((String(repeating: "x", count: 65_534) + "中MATCH_END\nsecond MATCH_END\n").utf8)
        try bytes.write(to: file)
        let args: [String: Any] = ["sessionId": session.id.uuidString, "query": "中MATCH_END"]
        let search = try object(await source.call("runbar_search_logs", arguments: data(args)))
        let hits = try XCTUnwrap(search["matches"] as? [[String: Any]])
        XCTAssertEqual(hits.count, 1); XCTAssertEqual((hits.first?["offset"] as? NSNumber)?.intValue, 65_534)
        let first = try object(await source.call("runbar_read_logs", arguments: data(["sessionId": session.id.uuidString, "position": "first", "maxBytes": 1024])))
        XCTAssertEqual((first["startOffset"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((first["endOffset"] as? NSNumber)?.intValue, 1024)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        await source.shutdown()
    }
    func testLogSearchReturnsContinuationInsteadOfScanningUnboundedFile() async throws {
        let (_, store, session, source) = try fixture(), file = store.directory(session.id).appendingPathComponent("output.raw")
        var bytes = Data(repeating: 120, count: 8 * 1024 * 1024 - 2)
        bytes.append(Data("NEEDLE".utf8)); try bytes.write(to: file)
        let first = try object(await source.call("runbar_search_logs", arguments: data(["sessionId": session.id.uuidString, "query": "NEEDLE"])))
        XCTAssertEqual(first["complete"] as? Bool, false)
        let next = try XCTUnwrap(first["nextOffset"] as? NSNumber)
        let second = try object(await source.call("runbar_search_logs", arguments: data(["sessionId": session.id.uuidString, "query": "NEEDLE", "offset": next])))
        XCTAssertEqual((second["matches"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(second["complete"] as? Bool, true)
        await source.shutdown()
    }
    func testNetworkListsAndBodyPagesStayBoundToSessionAndDoNotWriteCache() async throws {
        let (_, store, session, source) = try fixture()
        let directory = store.directory(session.id).appendingPathComponent("network")
        let cache = try NetworkStore(directory: directory, diskSpace: { _ in Int64.max / 2 })
        let record = try NetworkRecord.parse(["id": "fixture", "method": "POST", "uri": "https://example.test/data", "startTime": 1_000_000,
                                             "request": ["headers": ["content-type": ["application/json"]]],
                                             "response": ["statusCode": 200, "endTime": 1_050_000]], epoch: "fixture", isolate: "isolates/1")
        try cache.upsert([record])
        let response = Data(("{\"value\":\"" + String(repeating: "中🚀", count: 12_000) + "\"}").utf8)
        try cache.saveBodies(record.id, request: Data("{}".utf8), response: response); cache.close()
        let before = try Data(contentsOf: directory.appendingPathComponent("requests.sqlite"))
        let list = try object(await source.call("runbar_list_network_requests", arguments: data(["sessionId": session.id.uuidString, "url": ["/data"]])))
        XCTAssertEqual((list["requests"] as? [[String: Any]])?.count, 1)
        var combined = "", page = 0
        repeat {
            let body = try object(await source.call("runbar_read_network_body", arguments: data(["sessionId": session.id.uuidString, "requestId": record.id, "page": page])))
            combined += try XCTUnwrap(body["text"] as? String)
            guard let next = body["nextPage"] as? Int else { break }; page = next
        } while page < 10
        XCTAssertEqual(combined, String(decoding: response, as: UTF8.self)); XCTAssertFalse(combined.contains("�"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("requests.sqlite")), before)
        await source.shutdown()
    }
    func testInvalidArgumentsAndSessionSymlinkCannotReadArbitraryFiles() async throws {
        let (root, store, session, source) = try fixture()
        for arguments: [String: Any] in [["sessionId": "../../configuration.json"], ["sessionId": session.id.uuidString, "position": "first", "maxBytes": true], ["sessionId": session.id.uuidString, "unexpected": 1]] {
            do { _ = try await source.call("runbar_read_logs", arguments: data(arguments)); XCTFail("invalid arguments must fail") } catch {}
        }
        try FileManager.default.removeItem(at: store.directory(session.id))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("must stay private".utf8).write(to: outside.appendingPathComponent("output.raw"))
        try FileManager.default.createSymbolicLink(at: store.directory(session.id), withDestinationURL: outside)
        do { _ = try await source.call("runbar_read_logs", arguments: data(["sessionId": session.id.uuidString])); XCTFail("symlink must be rejected") } catch {}
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("output.raw"), encoding: .utf8), "must stay private")
        await source.shutdown()
    }
    func testMCPQueryDeadlineIsOptInAndNeverChangesCache() throws {
        let (root, _, _, _) = try fixture()
        let directory = root.appendingPathComponent("deadline-network")
        let writer = try NetworkStore(directory: directory, diskSpace: { _ in Int64.max / 2 }); writer.close()
        let before = try Data(contentsOf: directory.appendingPathComponent("requests.sqlite"))
        XCTAssertThrowsError(try NetworkStore(directory: directory, readOnly: true, queryTimeLimit: 0))
        let normal = try NetworkStore(directory: directory, readOnly: true); defer { normal.close() }
        XCTAssertEqual(try normal.listCounts(query: NetworkQuery()).total, 0)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("requests.sqlite")), before)
    }

    private var socketURL: String { "wss://example.test/quotes?channel='A'" }
    private func socket(_ id: Int64, kind: ProxyWebSocketEvent.Kind = .receive, payload: Data = Data(),
                        url: String? = nil, flow: String = "connection-1", opcode: Int = 1) -> ProxyWebSocketEvent {
        ProxyWebSocketEvent(id: id, flowID: flow, url: url ?? socketURL, timestamp: 1_700_000_000_000_000 + id,
            kind: kind, opcode: opcode, bytes: Int64(payload.count), payload: payload, note: "", closeCode: nil,
            requestHeaders: kind == .open ? "{\"Origin\":[\"fixture\"]}" : nil,
            responseHeaders: kind == .open ? "{\"Upgrade\":[\"websocket\"]}" : nil)
    }
    private func socketCall(_ source: RunbarMCPDataSource, _ session: RunSession, _ name: String,
                            _ values: [String: Any] = [:]) async throws -> [String: Any] {
        var arguments = values; arguments["sessionId"] = session.id.uuidString
        return try object(await source.call("runbar_" + name, arguments: data(arguments)))
    }
    private func messageIDs(_ result: [String: Any]) -> [String] {
        (result["messages"] as? [[String: Any]] ?? []).compactMap { $0["messageId"] as? String }
    }
    func testWebSocketMCPDefaultsToLatestAndUsesStableExclusiveCursors() async throws {
        let (_, store, session, source) = try fixture(), directory = store.directory(session.id).appendingPathComponent("proxy")
        let writer = try ProxyWebSocketStore(directory: directory)
        try writer.append(socket(1, kind: .open))
        try writer.append(socket(2, kind: .send, payload: Data("subscribe".utf8)))
        try writer.append(socket(3, payload: Data("push 1".utf8)))
        try writer.append(socket(4, payload: Data("push 2".utf8), flow: "connection-2"))
        try writer.append(socket(5, url: "wss://other.test/"))
        var close = socket(6, kind: .close); close.closeCode = 1000; close.note = "normal closure"
        try writer.append(close); writer.close()
        let urls = try await socketCall(source, session, "list_websocket_connections", ["url": "QUOTES"])
        let connections = try XCTUnwrap(urls["connections"] as? [[String: Any]])
        XCTAssertEqual(connections.count, 1); XCTAssertEqual(connections.first?["url"] as? String, socketURL)
        XCTAssertEqual(connections.first?["receiveCount"] as? Int, 2)
        let latest = try await socketCall(source, session, "list_websocket_messages", ["url": socketURL, "limit": 2])
        XCTAssertEqual(messageIDs(latest), ["3", "4"])
        XCTAssertEqual(latest["nextPosition"] as? String, "before"); XCTAssertEqual(latest["nextCursor"] as? String, "3")
        XCTAssertEqual(latest["throughMessageId"] as? String, "4"); XCTAssertEqual(latest["scannedBytes"] as? Int, 0)
        let append = try ProxyWebSocketStore(directory: directory)
        try append.append(socket(7, payload: Data("newest".utf8))); append.close()
        let before = try Data(contentsOf: directory.appendingPathComponent("websockets.sqlite"))
        let earlier = try await socketCall(source, session, "list_websocket_messages", ["url": socketURL,
            "position": "before", "cursor": "3", "throughMessageId": "4"])
        XCTAssertEqual(messageIDs(earlier), ["2"]); XCTAssertEqual(earlier["hasMore"] as? Bool, false)
        let next = try await socketCall(source, session, "list_websocket_messages", ["url": socketURL, "position": "after",
            "cursor": try XCTUnwrap(latest["pollAfterMessageId"] as? String)])
        XCTAssertEqual(messageIDs(next), ["7"])
        let oneConnection = try await socketCall(source, session, "list_websocket_messages", ["url": socketURL, "connectionId": "connection-2"])
        XCTAssertEqual(messageIDs(oneConnection), ["4"])
        let metadata = try await socketCall(source, session, "get_websocket_message", ["messageId": "2"])
        XCTAssertNil(metadata["payload"]); XCTAssertNil(metadata["text"])
        XCTAssertNotNil((metadata["requestHeaders"] as? [String: Any])?["Origin"])
        XCTAssertEqual((metadata["observedClose"] as? [String: Any])?["code"] as? Int, 1000)
        let sessionInfo = try await socketCall(source, session, "get_session")
        XCTAssertEqual((sessionInfo["webSocketCache"] as? [String: Any])?["messageCount"] as? Int, 5)
        _ = try await socketCall(source, session, "read_websocket_body", ["messageId": "2"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("websockets.sqlite")), before)
        await source.shutdown()
    }
    func testWebSocketMCPFullPayloadFiltersPreserveLiteralArrayKeywordsAndExcludeWins() async throws {
        let (_, store, session, source) = try fixture(), directory = store.directory(session.id).appendingPathComponent("proxy")
        let writer = try ProxyWebSocketStore(directory: directory)
        let text = String(repeating: "x", count: 63 * 1024 - 2) + "跨界关键词" + String(repeating: "y", count: 4000) + "hello,world; Tail"
        try writer.append(socket(1, payload: Data(text.utf8)))
        try writer.append(socket(2, payload: Data((text + " heartbeat").utf8)))
        try writer.append(socket(3, kind: .send, payload: Data("subscribe hello,world;".utf8))); writer.close()
        let filters: [String: Any] = ["url": socketURL, "query": "跨界关键词", "include": ["hello,world;", "tAiL"],
                                      "exclude": ["heartbeat"], "direction": "receive", "keywordMode": "all"]
        let result = try await socketCall(source, session, "list_websocket_messages", filters)
        XCTAssertEqual(messageIDs(result), ["1"])
        XCTAssertFalse(try XCTUnwrap((result["messages"] as? [[String: Any]])?.first?["preview"] as? String).contains("Tail"))
        let any = try await socketCall(source, session, "list_websocket_messages", ["url": socketURL,
            "include": ["does not exist", "SUBSCRIBE"], "keywordMode": "any"])
        XCTAssertEqual(messageIDs(any), ["3"])
        let excluded = try await socketCall(source, session, "list_websocket_messages", ["url": socketURL, "exclude": ["heartbeat"]])
        XCTAssertEqual(messageIDs(excluded), ["1", "3"])
        await source.shutdown()
    }
    func testWebSocketMCPEmptyFilteredPagesContinueWithinFrozenSnapshot() async throws {
        let (_, store, session, source) = try fixture(), directory = store.directory(session.id).appendingPathComponent("proxy")
        let writer = try ProxyWebSocketStore(directory: directory)
        for id in 1...600 { try writer.append(socket(Int64(id), payload: Data((id == 600 ? "needle" : "other").utf8))) }
        writer.close()
        let first = try await socketCall(source, session, "list_websocket_messages", ["url": socketURL, "position": "first", "query": "needle"])
        XCTAssertEqual(messageIDs(first), []); XCTAssertEqual(first["hasMore"] as? Bool, true)
        XCTAssertLessThanOrEqual(try XCTUnwrap(first["scannedMessages"] as? Int), 512)
        let more = try ProxyWebSocketStore(directory: directory)
        try more.append(socket(601, payload: Data("needle new".utf8))); more.close()
        var page = first, found: [String] = []
        for _ in 0..<100 {
            page = try await socketCall(source, session, "list_websocket_messages", ["url": socketURL,
                "position": try XCTUnwrap(page["nextPosition"] as? String), "cursor": try XCTUnwrap(page["nextCursor"] as? String),
                "throughMessageId": "600", "query": "needle"])
            found += messageIDs(page)
            if page["hasMore"] as? Bool == false { break }
        }
        XCTAssertEqual(found, ["600"]); XCTAssertEqual(page["hasMore"] as? Bool, false)
        let next = try await socketCall(source, session, "list_websocket_messages", ["url": socketURL, "position": "after",
            "cursor": try XCTUnwrap(page["pollAfterMessageId"] as? String), "query": "needle"])
        XCTAssertEqual(messageIDs(next), ["601"])
        await source.shutdown()
    }
    func testWebSocketMCPLongURLsAndUTF8BodyPagingDoNotChangeCache() async throws {
        let (_, store, session, source) = try fixture(), directory = store.directory(session.id).appendingPathComponent("proxy")
        let writer = try ProxyWebSocketStore(directory: directory), url = socketURL + String(repeating: "x", count: 6000)
        let payload = Data(("{\"number\":12345678901234567890,\"text\":\"" + String(repeating: "中🚀", count: 12000) + "\"}").utf8)
        try writer.append(socket(1, kind: .open, url: url)); try writer.append(socket(2, payload: payload, url: url)); writer.close()
        let before = try Data(contentsOf: directory.appendingPathComponent("websockets.sqlite"))
        let listed = try await socketCall(source, session, "list_websocket_messages", ["url": url])
        XCTAssertEqual(messageIDs(listed), ["2"])
        XCTAssertEqual((listed["messages"] as? [[String: Any]])?.first?["urlTruncated"] as? Bool, true)
        let metadata = try await socketCall(source, session, "get_websocket_message", ["messageId": "2"])
        XCTAssertEqual(metadata["url"] as? String, url)
        var joined = "", page = 0
        repeat {
            let body = try await socketCall(source, session, "read_websocket_body", ["messageId": "2", "page": page])
            joined += try XCTUnwrap(body["text"] as? String)
            guard let next = body["nextPage"] as? Int else { break }; page = next
        } while page < 20
        XCTAssertEqual(joined, String(decoding: payload, as: UTF8.self)); XCTAssertFalse(joined.contains("�"))
        let formatted = try await socketCall(source, session, "read_websocket_body", ["messageId": "2", "format": "json"])
        XCTAssertTrue(try XCTUnwrap(formatted["text"] as? String).contains("12345678901234567890"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("websockets.sqlite")), before)
        await source.shutdown()
    }
    func testWebSocketMCPBinaryPagesExplicitlyReportTruncationAndRequireRaw() async throws {
        let (_, store, session, source) = try fixture(), directory = store.directory(session.id).appendingPathComponent("proxy")
        let writer = try ProxyWebSocketStore(directory: directory), payload = Data(repeating: 65, count: 80_000)
        var event = socket(1, payload: payload, opcode: 2); event.bytes = 120_000; event.note = "fixture truncated"
        try writer.append(event); writer.close()
        var joined = Data(), page = 0
        repeat {
            let body = try await socketCall(source, session, "read_websocket_body", ["messageId": "1", "page": page])
            XCTAssertEqual(body["encoding"] as? String, "base64"); XCTAssertEqual(body["truncated"] as? Bool, true)
            joined.append(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(body["text"] as? String))))
            guard let next = body["nextPage"] as? Int else { break }; page = next
        } while page < 10
        XCTAssertEqual(joined, payload)
        do { _ = try await socketCall(source, session, "read_websocket_body", ["messageId": "1", "format": "json"]); XCTFail("binary must remain explicit") } catch {}
        let search = try await socketCall(source, session, "list_websocket_messages", ["url": socketURL, "query": "QUFBQUFB"])
        XCTAssertEqual(messageIDs(search), ["1"])
        await source.shutdown()
    }
    func testWebSocketMCPValidatesArgumentsBeforeMissingCacheAndNeverCreatesIt() async throws {
        let (_, store, session, source) = try fixture(), directory = store.directory(session.id).appendingPathComponent("proxy")
        let empty = try await socketCall(source, session, "list_websocket_connections")
        XCTAssertEqual(empty["available"] as? Bool, false)
        let messages = try await socketCall(source, session, "list_websocket_messages", ["url": socketURL])
        XCTAssertEqual(messages["available"] as? Bool, false)
        for values: [String: Any] in [["url": socketURL, "position": "after"], ["url": socketURL, "position": "before", "cursor": "0"],
            ["url": socketURL, "cursor": "1"], ["url": socketURL, "limit": true], ["url": socketURL, "unknown": "x"],
            ["url": socketURL, "include": Array(repeating: "word", count: 17)],
            ["url": socketURL, "position": "after", "cursor": "2", "throughMessageId": "1"]] {
            do { _ = try await socketCall(source, session, "list_websocket_messages", values); XCTFail("invalid arguments") }
            catch { XCTAssertTrue(error is RunbarMCPToolError) }
        }
        do { _ = try await socketCall(source, session, "get_websocket_message", ["messageId": "../../output.raw"]); XCTFail("path must fail") }
        catch { XCTAssertTrue(error is RunbarMCPToolError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        await source.shutdown()
    }
    func testWebSocketMCPRejectsDatabaseAndJournalSymlinks() async throws {
        let (root, store, session, source) = try fixture(), directory = store.directory(session.id).appendingPathComponent("proxy")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside-sqlite")
        try Data("private fixture".utf8).write(to: outside)
        for name in ["websockets.sqlite", "websockets.sqlite-wal", "websockets.sqlite-shm"] {
            let link = directory.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            do { _ = try await socketCall(source, session, "list_websocket_connections"); XCTFail("must reject symlink") } catch {}
            try FileManager.default.removeItem(at: link)
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("private fixture".utf8))
        await source.shutdown()
    }
    func testWebSocketMCPLegacyCatalogueIsReadOnly() async throws {
        let (_, store, session, source) = try fixture(), directory = store.directory(session.id).appendingPathComponent("proxy")
        let writer = try ProxyWebSocketStore(directory: directory)
        try writer.append(socket(1, kind: .open)); try writer.append(socket(2, payload: Data("legacy".utf8))); writer.close()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("websockets.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE connection_urls", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: directory.appendingPathComponent("websockets.sqlite"))
        let urls = try await socketCall(source, session, "list_websocket_connections")
        XCTAssertEqual((urls["connections"] as? [[String: Any]])?.first?["receiveCount"] as? Int, 1)
        let messages = try await socketCall(source, session, "list_websocket_messages", ["url": socketURL, "query": "legacy"])
        XCTAssertEqual(messageIDs(messages), ["2"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("websockets.sqlite")), before)
        await source.shutdown()
    }
    func testWebSocketMCPPreservesLargeStringIDsAndRejectsUnsafeXMLFormatting() async throws {
        let (_, store, session, source) = try fixture(), directory = store.directory(session.id).appendingPathComponent("proxy")
        let writer = try ProxyWebSocketStore(directory: directory), id: Int64 = 9_007_199_254_740_993
        try writer.append(socket(id, payload: Data("<root><value>42</value></root>".utf8)))
        try writer.append(socket(id + 1, payload: Data("<!DOCTYPE root [<!ENTITY external SYSTEM 'file:///fixture'>]><root>&external;</root>".utf8)))
        writer.close()
        let list = try await socketCall(source, session, "list_websocket_messages", ["url": socketURL])
        XCTAssertEqual(messageIDs(list), [String(id), String(id + 1)])
        let formatted = try await socketCall(source, session, "read_websocket_body", ["messageId": String(id), "format": "xml"])
        XCTAssertTrue(try XCTUnwrap(formatted["text"] as? String).contains("<value>42</value>"))
        do {
            _ = try await socketCall(source, session, "read_websocket_body", ["messageId": String(id + 1), "format": "xml"])
            XCTFail("DTD and entities must never be resolved")
        } catch {}
        let raw = try await socketCall(source, session, "read_websocket_body", ["messageId": String(id + 1)])
        XCTAssertTrue(try XCTUnwrap(raw["text"] as? String).contains("<!DOCTYPE"))
        do { _ = try await socketCall(source, session, "get_websocket_message", ["messageId": id]); XCTFail("ID must be a string") }
        catch { XCTAssertTrue(error is RunbarMCPToolError) }
        await source.shutdown()
    }
}
