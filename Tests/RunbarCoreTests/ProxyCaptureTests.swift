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
}
