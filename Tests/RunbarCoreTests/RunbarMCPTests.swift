import XCTest
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
        XCTAssertEqual(RunbarMCPProtocol.tools().count, 8)
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
}
