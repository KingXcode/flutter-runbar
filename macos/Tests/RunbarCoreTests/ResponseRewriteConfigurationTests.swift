import XCTest
@testable import RunbarCore

final class ResponseRewriteConfigurationTests: XCTestCase {
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func configuredProject(_ path: String) -> Project {
        var rule = ResponseRewriteRule()
        rule.name = "行情 · 模拟清盘中"
        rule.notes = "仅测试 blocks=2000。\n下次回归继续使用。"
        rule.method = "POST"; rule.urlPattern = "/dfc/stock/rt"
        rule.requestJSON = "{\"blocks\":[2000]}"
        rule.actions[0].kind = .table
        rule.actions[0].path = "$.body.symbols"
        var settings = ResponseRewriteSettings()
        settings.enabled = true; settings.revision = 7; settings.rules = [rule]
        var project = Project(path: path, kind: .flutter)
        project.responseRewrite = settings
        return project
    }
    func testLegacyProjectHasNoRewriteRules() throws {
        let project = Project(path: "/tmp/legacy", kind: .flutter)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        json.removeValue(forKey: "responseRewrite")
        let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.responseRewrite)
        XCTAssertFalse((decoded.responseRewrite ?? ResponseRewriteSettings()).enabled)
    }
    func testRulesNamesNotesAndEnabledStateSurviveReload() throws {
        let root = try temporary(), first = try SessionStore(root: root)
        var configuration = Configuration()
        configuration.projects = [configuredProject("/tmp/quotes")]
        try first.saveConfiguration(configuration)

        let reopened = try SessionStore(root: root).loadConfiguration()
        let original = try XCTUnwrap(configuration.projects[0].responseRewrite)
        let loaded = try XCTUnwrap(reopened.projects.first?.responseRewrite)
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.revision, 7)
        XCTAssertEqual(loaded.rules[0].notes, "仅测试 blocks=2000。\n下次回归继续使用。")
        XCTAssertEqual(loaded.rules[0].id, original.rules[0].id)
        XCTAssertTrue(loaded.enabled)
    }
    func testRulesRemainProjectScoped() throws {
        let root = try temporary(), store = try SessionStore(root: root)
        var configuration = Configuration()
        configuration.projects = [configuredProject("/tmp/first"), Project(path: "/tmp/second", kind: .generic)]
        try store.saveConfiguration(configuration)
        let loaded = try store.loadConfiguration()
        XCTAssertEqual(loaded.projects[0].responseRewrite?.rules.count, 1)
        XCTAssertNil(loaded.projects[1].responseRewrite)
    }
    func testDeletingCapturedSessionPreservesProjectRules() throws {
        let root = try temporary()
        let store = try SessionStore(root: root, trashDirectory: { try FileManager.default.removeItem(at: $0) })
        var configuration = Configuration()
        configuration.projects = [configuredProject("/tmp/quotes")]
        try store.saveConfiguration(configuration)
        var session = RunSession(projectPath: "/tmp/quotes", command: "sample")
        session.status = .succeeded; session.endedAt = Date()
        try store.save(session)
        try store.trashSessions([session.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(session.id).path))
        XCTAssertEqual(try store.loadConfiguration().projects.first?.responseRewrite, configuration.projects.first?.responseRewrite)
    }
}
