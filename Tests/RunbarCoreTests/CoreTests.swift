import XCTest
@testable import RunbarCore

final class CoreTests: XCTestCase {
    func testUTF8AndANSISplitAtEveryByte() {
        var parser = OutputParser()
        let input = "你好\u{1b}[31m Flutter \u{1b}[0m🚀\n"
        var output = ""
        for byte in input.utf8 { output += parser.consume(Data([byte])).text }
        output += parser.consume(Data(), final: true).text
        XCTAssertEqual(output, "你好 Flutter 🚀\n")
    }
    func testDevToolsURLSplitAndVMServiceRejected() {
        var parser = OutputParser()
        let input = "Dart VM service is listening on http://127.0.0.1:1234/token=/\nThe Flutter DevTools debugger and profiler is available at:\nhttp://127.0.0.1:9100/?uri=http://127.0.0.1:1234/token=/\n"
        var urls: [String] = []
        for byte in input.utf8 { urls += parser.consume(Data([byte])).urls }
        XCTAssertEqual(urls, ["http://127.0.0.1:9100/?uri=http://127.0.0.1:1234/token=/"])
    }
    func testLegacyURLNoNewlineAndUnsafeHost() {
        var parser = OutputParser()
        let result = parser.consume(Data("http://127.0.0.1:1234/token=/devtools/?uri=ws://localhost:1234/token=/ws".utf8), final: true)
        XCTAssertEqual(result.urls.count, 1)
        var unsafe = OutputParser()
        XCTAssertTrue(unsafe.consume(Data("DevTools http://example.com/devtools/?uri=secret\n".utf8)).urls.isEmpty)
    }
    func testURLNotEmittedPrematurely() {
        var parser = OutputParser()
        XCTAssertTrue(parser.consume(Data("http://localhost:9100/devtools/?uri=http://local".utf8)).urls.isEmpty)
        XCTAssertEqual(parser.consume(Data("host:1234/abc=/\n".utf8)).urls, ["http://localhost:9100/devtools/?uri=http://localhost:1234/abc=/"])
    }
    func testTruncatedUTF8DoesNotDisappear() {
        var parser = OutputParser()
        XCTAssertEqual(parser.consume(Data([0xE4, 0xBD])).text, "")
        XCTAssertEqual(parser.consume(Data(), final: true).text, "�")
    }
    func testStoreRoundTripAndRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var config = Configuration(); config.projects = [Project(path: "/tmp/a project")]
        try store.saveConfiguration(config)
        XCTAssertEqual(try store.loadConfiguration().projects, config.projects)
        let session = RunSession(projectPath: "/tmp/a project", command: "echo hello")
        try store.save(session); try store.recoverInterrupted()
        XCTAssertEqual(try store.sessions().first?.status, .interrupted)
        XCTAssertNil(try store.sessions().first?.endedAt)
    }
    func testExactLogBytesAndTimestampOffsets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = try RunLog(directory: root)
        let first = Data([0, 255, 0xE4]), second = Data([0xBD, 0xA0, 10])
        try log.append(first, at: Date(timeIntervalSince1970: 1)); try log.append(second, at: Date(timeIntervalSince1970: 2)); try log.close()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("output.raw")), first + second)
        let lines = try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let entries = try lines.map { try decoder.decode(OutputEvent.self, from: Data($0.utf8)) }
        XCTAssertEqual(entries.map(\.offset), [0, 3]); XCTAssertEqual(entries.map(\.sequence), [0, 1]); XCTAssertEqual(entries.map(\.byteCount), [3, 3])
    }
    func testLogFailurePropagates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = try RunLog(directory: root); try log.close()
        XCTAssertThrowsError(try log.append(Data("must fail".utf8)))
    }
    func testConfigurationCorruptionIsNotSilentlyOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        try Data("broken".utf8).write(to: root.appendingPathComponent("configuration.json"))
        XCTAssertThrowsError(try store.loadConfiguration())
    }
    func testCorruptHistoryDoesNotDisableValidSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let session = RunSession(projectPath: "/tmp", command: "true")
        try store.save(session)
        let damaged = root.appendingPathComponent("sessions/damaged")
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: damaged.appendingPathComponent("session.json"))
        XCTAssertEqual(try store.sessions().map(\.id), [session.id])
        XCTAssertEqual(store.warnings.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.appendingPathComponent("session.json").path))
    }

}
