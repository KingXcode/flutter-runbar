import XCTest
@testable import RunbarCore

final class ResponseRewriteControlTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testWriteIsIndependentOfSessionHistoryAndRoundTripsTypedRules() throws {
        let directory = try directory()
        var settings = ResponseRewriteSettings(); settings.revision = 2; settings.enabled = true
        var rule = ResponseRewriteRule(); rule.name = "清盘场景"; rule.notes = "下次回归\n继续使用"; rule.urlPattern = "/dfc/stock/rt"
        rule.requestJSON = "{\"blocks\":[2000]}"; settings.rules = [rule]
        try ResponseRewriteControl.write(settings, directory: directory)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("control/rewrite-rules.json"))
        XCTAssertEqual(try JSONDecoder().decode(ResponseRewriteSettings.self, from: bytes), settings)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("control/rewrite-rules.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
    func testPublishWaitsForMatchingRevisionNotOldAcknowledgement() async throws {
        let directory = try directory()
        var settings = ResponseRewriteSettings(); settings.revision = 7
        try ResponseRewriteControl.write(settings, directory: directory)
        let ack = directory.appendingPathComponent("control/rewrite-ack.json")
        try Data(#"{"revision":6,"error":null}"#.utf8).write(to: ack)
        let responder = Task {
            try await Task.sleep(for: .milliseconds(180))
            try Data(#"{"revision":7,"error":null}"#.utf8).write(to: ack, options: .atomic)
        }
        try await ResponseRewriteControl.publish(settings, directory: directory)
        let acknowledgement = try JSONSerialization.jsonObject(with: Data(contentsOf: ack)) as? [String: Any]
        XCTAssertEqual(acknowledgement?["revision"] as? Int, 7)
        try await responder.value
    }
    func testPublishReportsEngineRejectionWithoutDeletingSavedRules() async throws {
        let directory = try directory()
        var settings = ResponseRewriteSettings(); settings.revision = 4
        try ResponseRewriteControl.write(settings, directory: directory)
        try Data(#"{"revision":4,"error":"字段路径无效"}"#.utf8)
            .write(to: directory.appendingPathComponent("control/rewrite-ack.json"))
        do { try await ResponseRewriteControl.publish(settings, directory: directory); XCTFail("Must report rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("字段路径无效")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("control/rewrite-rules.json").path))
    }
}
