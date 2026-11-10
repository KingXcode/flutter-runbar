import XCTest
@testable import RunbarCore

final class MCPInstallationTests: XCTestCase {
    private let connection = RunbarMCPConnection(address: "http://127.0.0.1:47821/mcp", token: "fixture-token")

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runbar-mcp-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func json(_ file: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private func permissions(_ file: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    func testUserConfigurationPathsRespectAbsoluteOverrides() throws {
        let root = try fixture(), home = root.appendingPathComponent("home")
        XCTAssertEqual(RunbarMCPAgent.codex.configurationFile(home: home, environment: [:]).path, home.appendingPathComponent(".codex/config.toml").path)
        XCTAssertEqual(RunbarMCPAgent.claudeCode.configurationFile(home: home, environment: [:]).path, home.appendingPathComponent(".claude.json").path)
        XCTAssertEqual(RunbarMCPAgent.cursor.configurationFile(home: home, environment: [:]).path, home.appendingPathComponent(".cursor/mcp.json").path)
        XCTAssertEqual(RunbarMCPAgent.qoderCLI.configurationFile(home: home, environment: [:]).path, home.appendingPathComponent(".qoder/settings.json").path)
        XCTAssertEqual(RunbarMCPAgent.qoderCNCLI.configurationFile(home: home, environment: [:]).path, home.appendingPathComponent(".qoder-cn/settings.json").path)
        XCTAssertEqual(RunbarMCPAgent.workbuddy.configurationFile(home: home, environment: [:]).path, home.appendingPathComponent(".workbuddy/mcp.json").path)
        let override = root.appendingPathComponent("override")
        XCTAssertEqual(RunbarMCPAgent.codex.configurationFile(home: home, environment: ["CODEX_HOME": override.path]).path, override.appendingPathComponent("config.toml").path)
        XCTAssertEqual(RunbarMCPAgent.claudeCode.configurationFile(home: home, environment: ["CLAUDE_CONFIG_DIR": override.path]).path, override.appendingPathComponent(".claude.json").path)
        XCTAssertEqual(RunbarMCPAgent.qoderCLI.configurationFile(home: home, environment: ["QODER_CONFIG_DIR": override.path]).path, override.appendingPathComponent("settings.json").path)
        XCTAssertEqual(RunbarMCPAgent.qoderCNCLI.configurationFile(home: home, environment: ["QODERCN_CONFIG_DIR": override.path]).path, override.appendingPathComponent("settings.json").path)
        XCTAssertEqual(RunbarMCPAgent.codex.configurationFile(home: home, environment: ["CODEX_HOME": "relative"]).path, home.appendingPathComponent(".codex/config.toml").path)
    }

    func testFreshInstallAllClientsIsIdempotentAndUninstallsWithoutConnection() async throws {
        let root = try fixture(), installer = RunbarMCPInstaller(backupRoot: root.appendingPathComponent("backups"))
        for agent in RunbarMCPAgent.allCases {
            let file = agent.configurationFile(home: root.appendingPathComponent(agent.rawValue), environment: [:])
            let missing = await installer.inspect(agent: agent, file: file, connection: connection)
            XCTAssertEqual(missing.state, .missing, agent.rawValue)
            let result = try await installer.install(agent: agent, file: file, connection: connection)
            XCTAssertTrue(result.changed, agent.rawValue)
            XCTAssertNil(result.backup, agent.rawValue)
            XCTAssertEqual(try permissions(file), 0o600, agent.rawValue)
            if agent == .codex {
                let text = try String(contentsOf: file, encoding: .utf8)
                XCTAssertTrue(text.contains("[mcp_servers.runbar]"))
                XCTAssertTrue(text.contains("url = \"http://127.0.0.1:47821/mcp\""))
                XCTAssertTrue(text.contains("Authorization = \"Bearer fixture-token\""))
                XCTAssertTrue(text.contains("tool_timeout_sec = 45"))
            }
            let installed = await installer.inspect(agent: agent, file: file, connection: connection)
            XCTAssertEqual(installed.state, .installed, agent.rawValue)
            XCTAssertTrue(installed.canUninstall, agent.rawValue)
            let bytes = try Data(contentsOf: file)
            let again = try await installer.install(agent: agent, file: file, connection: connection)
            XCTAssertFalse(again.changed, agent.rawValue)
            XCTAssertNil(again.backup, agent.rawValue)
            XCTAssertEqual(try Data(contentsOf: file), bytes, agent.rawValue)
            let offline = await installer.inspect(agent: agent, file: file)
            XCTAssertEqual(offline.state, .installed, agent.rawValue)
            XCTAssertTrue(offline.canUninstall, agent.rawValue)
            let removed = try await installer.uninstall(agent: agent, file: file)
            XCTAssertTrue(removed.changed, agent.rawValue)
            let after = await installer.inspect(agent: agent, file: file)
            XCTAssertEqual(after.state, .missing, agent.rawValue)
            let secondRemoval = try await installer.uninstall(agent: agent, file: file)
            XCTAssertFalse(secondRemoval.changed, agent.rawValue)
        }
    }

    func testJSONClientSchemasAndUnrelatedSettingsSurviveRoundTrip() async throws {
        let root = try fixture(), installer = RunbarMCPInstaller(backupRoot: root.appendingPathComponent("backups"))
        for agent in [RunbarMCPAgent.claudeCode, .cursor, .qoderCLI, .qoderCNCLI, .workbuddy] {
            let file = agent.configurationFile(home: root.appendingPathComponent(agent.rawValue), environment: [:])
            let key = "mcpServers"
            let original: [String: Any] = ["theme": "custom", "nested": ["enabled": true, "values": [1, 2, 3]], key: ["other": ["command": "keep-me", "args": ["--test"]]]]
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let originalBytes = try JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted, .sortedKeys])
            try originalBytes.write(to: file)
            let installed = try await installer.install(agent: agent, file: file, connection: connection)
            let backup = try XCTUnwrap(installed.backup)
            XCTAssertEqual(try Data(contentsOf: backup), originalBytes)
            XCTAssertEqual(try permissions(backup), 0o600)
            let object = try json(file), servers = try XCTUnwrap(object[key] as? [String: Any]), runbar = try XCTUnwrap(servers["runbar"] as? [String: Any])
            XCTAssertEqual(runbar["url"] as? String, connection.address)
            XCTAssertEqual((runbar["headers"] as? [String: String])?["Authorization"], "Bearer fixture-token")
            if agent == .qoderCLI || agent == .qoderCNCLI {
                XCTAssertEqual(runbar["type"] as? String, "http")
                XCTAssertEqual(runbar["timeout"] as? Int, 45000)
            } else if agent == .claudeCode {
                XCTAssertEqual(runbar["type"] as? String, "http")
            } else {
                XCTAssertNil(runbar["type"], "Cursor identifies HTTP servers by url")
            }
            XCTAssertEqual(object["theme"] as? String, "custom")
            XCTAssertEqual((servers["other"] as? [String: Any])?["command"] as? String, "keep-me")
            _ = try await installer.uninstall(agent: agent, file: file)
            XCTAssertEqual(try json(file) as NSDictionary, original as NSDictionary)
        }
    }

    func testStalePortAndTokenAreDetectedAndUpdatedWithoutChangingOtherServer() async throws {
        let root = try fixture(), installer = RunbarMCPInstaller(backupRoot: root.appendingPathComponent("backups"))
        let updated = RunbarMCPConnection(address: "http://127.0.0.1:49800/mcp", token: "new-fixture-token")
        for agent in RunbarMCPAgent.allCases {
            let file = agent.configurationFile(home: root.appendingPathComponent(agent.rawValue), environment: [:])
            _ = try await installer.install(agent: agent, file: file, connection: connection)
            let before = try Data(contentsOf: file)
            let stale = await installer.inspect(agent: agent, file: file, connection: updated)
            XCTAssertEqual(stale.state, .needsUpdate, agent.rawValue)
            XCTAssertTrue(stale.canInstall, agent.rawValue)
            let result = try await installer.install(agent: agent, file: file, connection: updated)
            XCTAssertTrue(result.changed, agent.rawValue)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.backup)), before, agent.rawValue)
            let current = await installer.inspect(agent: agent, file: file, connection: updated)
            XCTAssertEqual(current.state, .installed, agent.rawValue)
        }
    }

    func testExistingUnknownRunbarIsNotOverwrittenOrRemoved() async throws {
        let root = try fixture(), installer = RunbarMCPInstaller(backupRoot: root.appendingPathComponent("backups"))
        for agent in RunbarMCPAgent.allCases {
            let file = agent.configurationFile(home: root.appendingPathComponent(agent.rawValue), environment: [:])
            let text: String
            if agent == .codex {
                text = "[mcp_servers.runbar]\ncommand = \"some-other-server\"\nargs = [\"preserve\"]\n"
            } else {
                let key = "mcpServers"
                text = "{\"\(key)\": {\"runbar\": {\"command\": \"some-other-server\", \"args\": [\"preserve\"]}}}"
            }
            try write(text, to: file)
            let state = await installer.inspect(agent: agent, file: file, connection: connection)
            XCTAssertEqual(state.state, .conflict, agent.rawValue)
            XCTAssertFalse(state.canInstall, agent.rawValue)
            XCTAssertFalse(state.canUninstall, agent.rawValue)
            do { _ = try await installer.install(agent: agent, file: file, connection: connection); XCTFail("Must preserve unrelated runbar server: \(agent)") } catch {}
            do { _ = try await installer.uninstall(agent: agent, file: file); XCTFail("Must preserve unrelated runbar server: \(agent)") } catch {}
            XCTAssertEqual(try Data(contentsOf: file), Data(text.utf8), agent.rawValue)
        }
    }

    func testMalformedConfigurationNeverChangesOriginal() async throws {
        let root = try fixture(), installer = RunbarMCPInstaller(backupRoot: root.appendingPathComponent("backups"))
        let cases: [(RunbarMCPAgent, String)] = [(.claudeCode, "{\"mcpServers\": "), (.cursor, "[]"), (.qoderCLI, "{\"mcpServers\": []}"), (.codex, "[mcp_servers.runbar\nurl = \"broken\"\n"), (.codex, "model =\n"), (.codex, "array = [}\n")]
        for (index, item) in cases.enumerated() {
            let file = root.appendingPathComponent("bad-\(index)")
            try write(item.1, to: file)
            let state = await installer.inspect(agent: item.0, file: file, connection: connection)
            XCTAssertEqual(state.state, .unavailable, item.0.rawValue)
            do { _ = try await installer.install(agent: item.0, file: file, connection: connection); XCTFail("Must reject malformed configuration") } catch {}
            XCTAssertEqual(try Data(contentsOf: file), Data(item.1.utf8))
        }
    }

    func testSymbolicConfigurationAndParentAreRejected() async throws {
        let root = try fixture(), installer = RunbarMCPInstaller(backupRoot: root.appendingPathComponent("backups"))
        let original = root.appendingPathComponent("original.json")
        try write("{\"preserve\": true}", to: original)
        let linked = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: original)
        let linkedParent = root.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: root)
        for file in [linked, linkedParent.appendingPathComponent("original.json")] {
            let state = await installer.inspect(agent: .cursor, file: file, connection: connection)
            XCTAssertEqual(state.state, .unavailable)
            do { _ = try await installer.install(agent: .cursor, file: file, connection: connection); XCTFail("Must reject symbolic path") } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: original), Data("{\"preserve\": true}".utf8))
    }

    func testCommentedJSONRequiresManualHandlingAndNeverLeaksFileContents() async throws {
        let root = try fixture(), file = root.appendingPathComponent("settings.json")
        let installer = RunbarMCPInstaller(backupRoot: root.appendingPathComponent("backups"))
        let text = "{\n// private-existing-token\n\"mcpServers\": {}\n}\n"
        try write(text, to: file)
        let state = await installer.inspect(agent: .qoderCLI, file: file, connection: connection)
        XCTAssertEqual(state.state, .unavailable)
        XCTAssertFalse(state.message.contains("private-existing-token"))
        do {
            _ = try await installer.install(agent: .qoderCLI, file: file, connection: connection)
            XCTFail("Commented JSON must not be rewritten as strict JSON")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("private-existing-token"))
        }
        XCTAssertEqual(try Data(contentsOf: file), Data(text.utf8))
    }

    func testDuplicateJSONKeysAreRejectedWithoutDiscardingValuesOrExposingContents() async throws {
        let root = try fixture(), installer = RunbarMCPInstaller(backupRoot: root.appendingPathComponent("backups"))
        let originals = [
            "{\"mcpServers\": {\"other\": {\"command\": \"private-command\"}}, \"mcpServers\": {}}",
            "{\"mcpServers\": {\"runbar\": {\"url\": \"private-url\", \"url\": \"http://127.0.0.1:47821/mcp\"}}}",
            "{\"mcpServers\": {}, \"other\": {\"credential\": \"private-value\", \"credential\": \"second-value\"}}"
        ]
        for (index, original) in originals.enumerated() {
            let file = root.appendingPathComponent("duplicate-\(index).json")
            try write(original, to: file)
            let state = await installer.inspect(agent: .cursor, file: file, connection: connection)
            XCTAssertEqual(state.state, .unavailable)
            XCTAssertFalse(state.message.contains("private-"))
            do {
                _ = try await installer.install(agent: .cursor, file: file, connection: connection)
                XCTFail("Duplicate keys must not be collapsed by rewriting")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("private-"))
            }
            XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
        }
    }

    func testJSONUnrelatedNumericLiteralsAndWhitespaceArePreserved() async throws {
        let root = try fixture(), installer = RunbarMCPInstaller(backupRoot: root.appendingPathComponent("backups"))
        let before = "{\n  \"huge\" : 1234567890123456789012345678901234567890,\n\t\"precise\":1.2345678901234567890123456789,\n  \"mcpServers\" : { \"other\" : {\"command\":\"keep\"}"
        let after = " },\n  \"negativeZero\": -0.00000000000000000000000000001\n}\n"
        for agent in [RunbarMCPAgent.claudeCode, .cursor, .qoderCLI, .qoderCNCLI, .workbuddy] {
            let file = root.appendingPathComponent(agent.rawValue + ".json")
            try write(before + after, to: file)
            _ = try await installer.install(agent: agent, file: file, connection: connection)
            let installed = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(installed.hasPrefix(before), agent.rawValue)
            XCTAssertTrue(installed.hasSuffix(after), agent.rawValue)
            _ = try await installer.uninstall(agent: agent, file: file)
            let removed = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(removed.hasPrefix(before), agent.rawValue)
            XCTAssertTrue(removed.hasSuffix(after), agent.rawValue)
        }
    }

    func testCodexCommentsQuotedSectionsAndMultilineStringsSurvive() async throws {
        let root = try fixture(), file = root.appendingPathComponent("config.toml")
        let installer = RunbarMCPInstaller(backupRoot: root.appendingPathComponent("backups"))
        let original = #"""
        # Preserve this user comment.
        model = "custom-model"
        instructions = """
        [mcp_servers.runbar]
        url = "http://unrelated.test/mcp"
        """

        [mcp_servers."other.server"] # dotted server name
        command = "keep-me"
        [mcp_servers."other.server".env]
        CUSTOM = "value"

        [projects."/fixture/project"]
        trust_level = "trusted"
        """# + "\n"
        try write(original, to: file)
        _ = try await installer.install(agent: .codex, file: file, connection: connection)
        let installed = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(installed.contains(original), "Existing TOML text and comments should remain byte-for-byte")
        let state = await installer.inspect(agent: .codex, file: file, connection: connection)
        XCTAssertEqual(state.state, .installed)
        _ = try await installer.uninstall(agent: .codex, file: file)
        let removed = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(removed.contains(original.trimmingCharacters(in: .newlines)))
        XCTAssertTrue(removed.contains("[mcp_servers.runbar]\nurl = \"http://unrelated.test/mcp\""), "Fake table inside multiline value must survive")
    }

    func testCodexQuotedRunbarAndNestedHeadersAreManagedWithoutRemovingNeighbor() async throws {
        let root = try fixture(), file = root.appendingPathComponent("config.toml")
        let installer = RunbarMCPInstaller(backupRoot: root.appendingPathComponent("backups"))
        let other = "[mcp_servers.other]\ncommand = \"preserve\"\n"
        let original = "# user settings\nmodel = \"custom\"\n\n[mcp_servers.\"runbar\"]\nurl = \"http://127.0.0.1:47821/mcp\"\ntool_timeout_sec = 45\n[mcp_servers.\"runbar\".http_headers]\nAuthorization = \"Bearer fixture-token\"\n\n" + other
        try write(original, to: file)
        let state = await installer.inspect(agent: .codex, file: file, connection: connection)
        XCTAssertTrue(state.canUninstall)
        _ = try await installer.uninstall(agent: .codex, file: file)
        let remaining = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(remaining.contains(other))
        XCTAssertTrue(remaining.contains("model = \"custom\""))
        XCTAssertFalse(remaining.contains("fixture-token"))
    }

    func testCodexCommentBelongingToNextTableSurvivesUninstall() async throws {
        let root = try fixture(), file = root.appendingPathComponent("config.toml")
        let installer = RunbarMCPInstaller(backupRoot: root.appendingPathComponent("backups"))
        let following = "# Credentials for the other MCP server\n[mcp_servers.other]\ncommand = \"preserve\"\n"
        let original = "[mcp_servers.runbar]\nurl = \"http://127.0.0.1:47821/mcp\"\nhttp_headers = { Authorization = \"Bearer fixture-token\" }\n\n" + following
        try write(original, to: file)
        _ = try await installer.uninstall(agent: .codex, file: file)
        let removed = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(removed.contains(following))
        XCTAssertFalse(removed.contains("fixture-token"))
    }
}
