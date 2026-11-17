import Foundation
import XCTest
@testable import RunbarCore

final class CurlWorkspaceTests: XCTestCase {
    func testBrowserCurlAndHTTPBlocksUseCaretAndFileVariables() throws {
        let text = #"""
        @base = https://example.test
        @path = {{base}}/quotes
        ### Quote
        curl '{{path}}?a=1&b=2' \
          -H 'accept: application/json' --compressed \
          --data-raw $'{"name":"浦发","line":"a\\nb"}'
        ### Health
        GET {{base}}/health HTTP/1.1
        Authorization: Bearer example

        """#
        let document = CurlDocument(text)
        XCTAssertEqual(document.blocks.count, 2)
        let post = try XCTUnwrap(document.block(at: (text as NSString).range(of: "--data-raw").location)?.request)
        XCTAssertEqual(post.method, "POST")
        XCTAssertEqual(post.url.absoluteString, "https://example.test/quotes?a=1&b=2")
        XCTAssertEqual(post.options.last?.value, #"{"name":"浦发","line":"a\nb"}"#)
        XCTAssertEqual(CurlDocument(post.curlText).blocks.first?.request, post)
        XCTAssertEqual(document.blocks.last?.title, "Health")
        XCTAssertEqual(document.block(at: text.utf16.count)?.request?.url.path, "/health")
    }

    func testRejectsShellProtocolsLocalFileOptionsAndExpandedHeaderInjection() {
        let invalid = [
            "curl https://example.test; open /tmp",
            "curl \"https://example.test/$(whoami)\"",
            "curl file:///private/etc/hosts",
            "curl https://example.test -K /tmp/options",
            "curl https://example.test --output /tmp/file",
            "curl https://example.test -b cookies.txt",
            "curl https://example.test -H @headers.txt",
            "curl https://example.test --data-binary @/tmp/file",
            "curl https://example.test --data-urlencode field@/tmp/file",
            "curl https://example.test -F 'foo=@/tmp/file'",
            "curl https://example.test --next https://other.test",
            "curl https://example.test -H $'X-Test: first\\nContent-Length: 0'",
            "@a = {{b}}\n@b = {{a}}\ncurl '{{a}}'",
            "curl '{{unresolved}}'",
        ]
        for text in invalid {
            let block = CurlDocument(text).blocks.first
            XCTAssertNil(block?.request, text)
            XCTAssertNotNil(block?.error, text)
        }
        XCTAssertNotNil(CurlDocument("curl https://example.test --data-raw '@/tmp/file'").blocks.first?.request)
        XCTAssertNotNil(CurlDocument("curl https://example.test -F 'name=literal'").blocks.first?.request)
    }

    func testHistoryRetainsResponseBytesAndPrunesOldRuns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CurlWorkspaceStore(root: root)
        let project = CurlProject(name: "接口示例", text: "curl https://example.test")
        try store.save(project)
        let request = try XCTUnwrap(CurlDocument(project.text).blocks.first?.request)
        let body = Data([0, 0x80, 0xff])
        let head = CurlResponseHead(status: 200, statusLine: "HTTP/1.1 200 OK", headers: "HTTP/1.1 200 OK",
                                    contentType: "application/octet-stream", disposition: nil, duration: 0.125, bytes: body.count)
        for i in 0...CurlWorkspaceStore.historyLimit {
            try store.record(CurlRun(date: Date(timeIntervalSince1970: Double(i)), request: request, response: head),
                             body: body, project: project.id)
        }
        let reopened = CurlWorkspaceStore(root: root)
        XCTAssertEqual(try reopened.projects().first?.text, project.text)
        let history = try reopened.history(project.id)
        XCTAssertEqual(history.count, CurlWorkspaceStore.historyLimit)
        XCTAssertEqual(history.last?.date, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(try reopened.response(XCTUnwrap(history.first), project: project.id)?.body, body)
        XCTAssertEqual(try history.first?.request.validatedForSending(), request)
    }

    func testCurlSendsExactBodyHeadersAndKeepsHTTPErrorResponse() async throws {
        let server = try HTTPFixture()
        defer { server.stop() }
        let body = "{\"line\":\"quote '\\quoted\"}\n\noutput = \"/tmp/unused\""
        let raw = "PATCH \(server.url)/echo\nContent-Type: text/plain\nX-Runbar-Test: café\n\n" + body
        let request = try XCTUnwrap(CurlDocument(raw).blocks.first?.request)
        let result = try await CurlClient.send(request)
        XCTAssertEqual(result.head.status, 418)
        XCTAssertEqual(result.head.contentType, "application/json")
        XCTAssertTrue(result.head.headers.contains("X-Runbar-Fixture: yes"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body) as? [String: String])
        XCTAssertEqual(object["data"], body)
        XCTAssertEqual(object["header"], "cafÃ©") // HTTP/1.x field bytes are decoded as Latin-1 by the fixture.
        XCTAssertEqual(object["method"], "PATCH")
    }

    func testCapturedRequestCanBeSavedInProjectAndReplayedWithOriginalBytes() async throws {
        let server = try HTTPFixture()
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = root.appendingPathComponent("capture")
        let network = try NetworkStore(directory: capture)
        let body = "@start\r\n### {{item}}\r\n中文 'name'"
        let record = capturedRequest(url: server.url + "/echo?symbol=600000&market=1", bytes: Int64(body.utf8.count),
                                     headers: #"{"Content-Type":"text/plain","X-Runbar-Test":["one","two"],"Cookie":["sid=fixture"],"Authorization":"Bearer fixture","Connection":"X-Hop","X-Hop":"old","Content-Length":"999","Proxy-Authorization":"Basic fixture"}"#)
        try network.upsert([record])
        try network.saveBodies(record.id, request: Data(body.utf8), response: Data())

        let imported = try await NetworkCacheReader().curlRequest(directory: capture, id: record.id)
        let workspace = CurlWorkspaceStore(root: root.appendingPathComponent("workspace"))
        let project = CurlProject(name: "请求回放", text: "@item = replaced\n\nGET \(server.url)/json\n\n" + imported.projectBlock)
        try workspace.save(project)
        let reopened = try XCTUnwrap(workspace.projects().first)
        let document = CurlDocument(reopened.text)
        XCTAssertEqual(document.blocks.count, 2)
        let request = try XCTUnwrap(document.blocks.last?.request, document.blocks.last?.error ?? "")
        XCTAssertEqual(request.url.query, "symbol=600000&market=1")
        XCTAssertEqual(request.options.filter { $0.value?.hasPrefix("X-Runbar-Test: ") == true }.compactMap(\.value),
                       ["X-Runbar-Test: one", "X-Runbar-Test: two"])
        XCTAssertFalse(request.curlText.contains("Proxy-Authorization"))
        XCTAssertFalse(request.curlText.contains("X-Hop"))
        XCTAssertTrue(request.curlText.contains("Authorization: Bearer fixture"))
        XCTAssertTrue(request.curlText.contains("Cookie: sid=fixture"))
        let result = try await CurlClient.send(request)
        XCTAssertEqual(result.head.status, 418)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body) as? [String: String])
        XCTAssertEqual(decoded["method"], "PATCH")
        XCTAssertEqual(decoded["data"], body)
    }

    func testCapturedRequestImportRejectsTruncatedBodyAndAllowsBodylessRequestWithoutResponseCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try NetworkStore(directory: root)
        var incomplete = capturedRequest(url: "https://example.test/patch", bytes: 10)
        let empty = capturedRequest(url: "https://example.test/health", bytes: 0, method: "GET")
        try network.upsert([incomplete, empty])
        try network.saveBodies(incomplete.id, request: Data("abc".utf8), response: Data(),
                               note: "request 正文仅保留部分内容（单正文 1 MB / 全局预览预算）")
        try network.markBody(empty.id, state: .unavailable, note: "response 未缓存")
        let reader = NetworkCacheReader()
        do {
            _ = try await reader.curlRequest(directory: root, id: incomplete.id)
            XCTFail("Truncated requests must not produce replayable text")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("正文"), error.localizedDescription)
        }
        let imported = try await reader.curlRequest(directory: root, id: empty.id)
        XCTAssertEqual(imported.method, "GET")
        XCTAssertFalse(imported.curlText.contains("--data"))

        incomplete.id = NetworkRecord.identity(epoch: "fixture", isolate: "proxy", request: "gzip")
        incomplete.requestBytes = 31
        incomplete.requestHeaders = #"{"Content-Encoding":["gzip"],"Content-Type":["application/json"]}"#
        try network.upsert([incomplete])
        try network.saveBodies(incomplete.id, request: Data("{}".utf8), response: Data(), note: "response 仅保留部分内容")
        let decoded = try await reader.curlRequest(directory: root, id: incomplete.id)
        XCTAssertFalse(decoded.curlText.contains("Content-Encoding"))
        XCTAssertEqual(decoded.options.last?.value, "{}")
    }

    private func capturedRequest(url: String, bytes: Int64, method: String = "PATCH", headers: String = "{}") -> NetworkRecord {
        let id = NetworkRecord.identity(epoch: "fixture", isolate: "proxy", request: url)
        return NetworkRecord(id: id, epoch: "fixture", isolateID: "proxy", requestID: url, method: method, url: url,
                             startMicros: 1, endMicros: 2, status: 200, contentType: "",
                             requestBytes: bytes, responseBytes: 0, requestHeaders: headers, responseHeaders: "{}",
                             failure: nil, timingVersion: 2)
    }

    func testRedirectsAndSizeLimitAndCancellation() async throws {
        let server = try HTTPFixture()
        defer { server.stop() }
        func request(_ suffix: String, _ flags: String = "") throws -> CurlRequest {
            try XCTUnwrap(CurlDocument("curl '\(server.url)/\(suffix)' \(flags)").blocks.first?.request)
        }
        let initial = try await CurlClient.send(request("redirect"))
        XCTAssertEqual(initial.head.status, 302)
        let redirected = try await CurlClient.send(request("redirect", "-L"))
        XCTAssertEqual(redirected.head.status, 200)
        let headersOnly = try await CurlClient.send(request("json", "-I"))
        XCTAssertEqual(headersOnly.head.status, 200)
        XCTAssertEqual(headersOnly.body.count, 0)
        do {
            _ = try await CurlClient.send(request("oversize", "--compressed"))
            XCTFail("Should limit the received bytes after gzip decoding")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("16 MiB"), error.localizedDescription)
        }
        let slow = try request("slow")
        let task = Task { try await CurlClient.send(slow) }
        try await Task.sleep(for: .milliseconds(150))
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { _ = try await task.value; XCTFail("Request should cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
    }
}

/// Real HTTP, entirely on loopback. Python comes with the Xcode command-line
/// tools also used by the app's own macOS build scripts.
private final class HTTPFixture {
    private let process = Process()
    private let lifetime = Pipe()
    let url: String
    init() throws {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", #"""
        import gzip, json, sys, threading, time
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def send(self, data, status=200, encoding=None):
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("X-Runbar-Fixture", "yes")
                self.send_header("Content-Length", str(len(data)))
                if encoding: self.send_header("Content-Encoding", encoding)
                self.end_headers()
                if self.command != "HEAD": self.wfile.write(data)
            def do_PATCH(self):
                data=self.rfile.read(int(self.headers["Content-Length"])).decode()
                self.send(json.dumps(dict(data=data, method=self.command, header=self.headers.get("X-Runbar-Test"))).encode(), 418)
            def do_GET(self):
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", "/json")
                    self.end_headers()
                elif self.path == "/oversize":
                    self.send(gzip.compress(b"a"*(16*1024*1024+128)), encoding="gzip")
                elif self.path == "/slow": time.sleep(8)
                else: self.send(b'{"result":"loopback OK"}')
            do_HEAD=do_GET
        server=ThreadingHTTPServer(("127.0.0.1",0),Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        print(server.server_port,flush=True)
        sys.stdin.buffer.read()
        """#]
        process.standardInput = lifetime
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = pipe.fileHandleForReading.availableData
        guard let port = Int(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(port) else {
            try? lifetime.fileHandleForWriting.close()
            throw RunbarError.message("无法启动本机 HTTP 测试服务。")
        }
        url = "http://127.0.0.1:\(port)"
    }
    func stop() {
        // Async tests can resume on another thread. Closing stdin lets the
        // server exit without waiting on Foundation's process run loop.
        try? lifetime.fileHandleForWriting.close()
    }
}
