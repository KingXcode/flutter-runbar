import XCTest
@testable import RunbarCore

final class SkillInstallationTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runbar-skill-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func payload(_ root: URL, version: String = "1.0.0", text: String = "first") throws -> RunbarSkillPayload {
        let directory = root.appendingPathComponent("bundle-" + UUID().uuidString)
        let content = ["SKILL.md": "---\nname: runbar-diagnostics\nmetadata:\n  version: \"\(version)\"\n---\n\(text)",
                       "agents/openai.yaml": "interface:\n  display_name: Runbar\n", "references/setup.md": "Connect MCP"]
        var hashes: [String: String] = [:]
        for (name, value) in content {
            let file = directory.appendingPathComponent(name), data = Data(value.utf8)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file); hashes[name] = RunbarSkillPayload.hash(data)
        }
        let manifest = RunbarSkillManifest(version: version, files: hashes)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        return try RunbarSkillPayload(directory: directory)
    }
    func testDefaultAgentDirectoriesAndXDGOverride() {
        let home = URL(fileURLWithPath: "/fixture/home")
        let paths = [".agents/skills", ".claude/skills", ".qoder/skills", ".qoder-cn/skills", ".workbuddy/skills", ".config/opencode/skills"]
        XCTAssertEqual(RunbarSkillAgent.allCases.map { $0.defaultDirectory(home: home).path }, paths.map { home.appendingPathComponent($0).path })
        XCTAssertEqual(RunbarSkillAgent.opencode.defaultDirectory(home: home, xdgConfigHome: "/fixture/config").path, "/fixture/config/opencode/skills")
    }
    func testTamperedBundleAndRedirectedResourceAreRejected() throws {
        let root = try fixture(), original = try payload(root)
        try Data("changed".utf8).write(to: original.directory.appendingPathComponent("SKILL.md"))
        XCTAssertThrowsError(try RunbarSkillPayload(directory: original.directory))
        let redirected = try payload(root), file = redirected.directory.appendingPathComponent("references/setup.md")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original.directory.appendingPathComponent("SKILL.md"))
        XCTAssertThrowsError(try RunbarSkillPayload(directory: redirected.directory))
    }
    func testInstallIsIdempotentAndPreservesOtherSkills() async throws {
        let root = try fixture(), bundled = try payload(root), agentRoot = root.appendingPathComponent("agent/skills")
        let other = agentRoot.appendingPathComponent("other/SKILL.md")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("custom".utf8).write(to: other)
        let installer = RunbarSkillInstaller(payload: bundled, backupRoot: root.appendingPathComponent("backups"))
        let result = try await installer.install(root: agentRoot)
        XCTAssertTrue(result.changed); XCTAssertNil(result.backup)
        XCTAssertEqual(try Data(contentsOf: other), Data("custom".utf8))
        let state = await installer.inspect(root: agentRoot)
        XCTAssertEqual(state.state, .current)
        let second = try await installer.install(root: agentRoot)
        XCTAssertFalse(second.changed); XCTAssertNil(second.backup)
    }
    func testUpdateDetectsContentChangeEvenWithSameVersionAndBacksUpOldSkill() async throws {
        let root = try fixture(), first = try payload(root), latest = try payload(root, text: "updated")
        let agentRoot = root.appendingPathComponent("agent/skills"), backups = root.appendingPathComponent("backups")
        _ = try await RunbarSkillInstaller(payload: first, backupRoot: backups).install(root: agentRoot)
        let installer = RunbarSkillInstaller(payload: latest, backupRoot: backups)
        let state = await installer.inspect(root: agentRoot)
        XCTAssertEqual(state.state, .updateAvailable); XCTAssertTrue(state.hasUpdate)
        let result = try await installer.install(root: agentRoot), backup = try XCTUnwrap(result.backup)
        XCTAssertTrue(backup.path.hasPrefix(backups.path + "/"))
        XCTAssertFalse(backup.path.hasPrefix(agentRoot.path + "/"))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("SKILL.md")), first.content["SKILL.md"])
        XCTAssertEqual(try Data(contentsOf: result.destination.appendingPathComponent("SKILL.md")), latest.content["SKILL.md"])
    }
    func testCustomChangesRequireApprovalAndAreIncludedInBackup() async throws {
        let root = try fixture(), first = try payload(root), latest = try payload(root, version: "1.1.0")
        let agentRoot = root.appendingPathComponent("agent/skills"), backups = root.appendingPathComponent("backups")
        let result = try await RunbarSkillInstaller(payload: first, backupRoot: backups).install(root: agentRoot)
        let custom = result.destination.appendingPathComponent("custom.md"), value = Data("preserve this".utf8)
        try value.write(to: custom)
        let installer = RunbarSkillInstaller(payload: latest, backupRoot: backups)
        let state = await installer.inspect(root: agentRoot)
        XCTAssertEqual(state.state, .modified); XCTAssertTrue(state.requiresReplacementApproval)
        do { _ = try await installer.install(root: agentRoot); XCTFail("custom content must be kept without approval") } catch {}
        XCTAssertEqual(try Data(contentsOf: custom), value)
        let updated = try await installer.install(root: agentRoot, allowReplacingCustom: true), backup = try XCTUnwrap(updated.backup)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("custom.md")), value)
    }
    func testManualInstallationCanBeCheckedAndNewerVersionsAreNotOfferedForDowngrade() async throws {
        let root = try fixture(), first = try payload(root), latest = try payload(root, version: "1.1.0")
        let agentRoot = root.appendingPathComponent("agent/skills"), backups = root.appendingPathComponent("backups")
        let result = try await RunbarSkillInstaller(payload: first, backupRoot: backups).install(root: agentRoot)
        try FileManager.default.removeItem(at: result.destination.appendingPathComponent(RunbarSkillInstaller.receiptName))
        let installer = RunbarSkillInstaller(payload: latest, backupRoot: backups)
        let manual = await installer.inspect(root: agentRoot)
        XCTAssertEqual(manual.state, .unmanaged); XCTAssertTrue(manual.hasUpdate); XCTAssertEqual(manual.installedVersion, "1.0.0")
        _ = try await installer.install(root: agentRoot, allowReplacingCustom: true)
        let older = await RunbarSkillInstaller(payload: first, backupRoot: backups).inspect(root: agentRoot)
        XCTAssertFalse(older.hasUpdate); XCTAssertTrue(older.requiresReplacementApproval)
    }
    func testSymbolicSkillFolderAndBackupCollisionAreNeverOverwritten() async throws {
        let root = try fixture(), bundled = try payload(root), agentRoot = root.appendingPathComponent("agent/skills")
        try FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: agentRoot.appendingPathComponent(RunbarSkillPayload.name), withDestinationURL: bundled.directory)
        let installer = RunbarSkillInstaller(payload: bundled, backupRoot: root.appendingPathComponent("backups"))
        let linked = await installer.inspect(root: agentRoot)
        XCTAssertEqual(linked.state, .unavailable)
        do { _ = try await installer.install(root: agentRoot, allowReplacingCustom: true); XCTFail("symlink must not be replaced") } catch {}
        let conflicting = RunbarSkillInstaller(payload: bundled, backupRoot: root.appendingPathComponent("new-agent/skills/runbar-diagnostics"))
        do { _ = try await conflicting.install(root: root.appendingPathComponent("new-agent/skills")); XCTFail("backup and destination must differ") } catch {}
    }
}
