import XCTest
@testable import RunbarCore

final class CommandWorkflowTests: XCTestCase {
    private func run(_ command: String, workflow: CommandWorkflow) throws -> (RunSession, String, [CommandVariable]?) {
        let store = try SessionStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("Runbar workflow \(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let shell = store.root.appendingPathComponent("fixture-shell")
        try Data("#!/bin/sh\nexec /bin/zsh -f \"$@\"\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        var project = Project(path: store.root.path, kind: .generic)
        try project.savePreset(name: "Fixture", command: command, workflow: workflow)
        let preset = try XCTUnwrap(project.selectedPreset)
        let finished = expectation(description: "workflow finished")
        var result: RunSession?
        var values: [CommandVariable]?
        let runner = ProcessRunner(store: store) { event in
            switch event {
            case .variablesChanged(let id, let updates):
                XCTAssertEqual(id, preset.id)
                XCTAssertNil(result, "Values arrive before the run is marked complete")
                values = updates
            case .finished(let session): result = session; finished.fulfill()
            case .failure(let message), .rejected(let message): XCTFail(message)
            default: break
            }
        }
        runner.run(project: project, preset: preset, extraPath: "/usr/bin:/bin", shell: shell.path)
        wait(for: [finished], timeout: 10)
        let session = try XCTUnwrap(result)
        let directory = store.directory(session.id)
        let output = try String(contentsOf: directory.appendingPathComponent("output.raw"), encoding: .utf8)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("workflow-") })
        if let values {
            project.presets[0].workflow?.variables = values
            var configuration = Configuration()
            configuration.projects = [project]
            try store.saveConfiguration(configuration)
            XCTAssertEqual(try store.loadConfiguration().projects[0].presets[0].workflow?.variables, values)
        }
        return (session, output, values)
    }

    func testRunsHooksInOrderAndPreservesLiteralArguments() throws {
        let label = "一 二 ' \" $HOME $(printf injected)"
        let workflow = CommandWorkflow(variables: [CommandVariable(name: "build-number", defaultValue: "0009"),
                                                    CommandVariable(name: "label", defaultValue: label),
                                                    CommandVariable(name: "empty", defaultValue: "default", overrideValue: "")],
            before: "{{build-number}}++\nexport READY=ready\nprintf 'pre:%s\\n' {{build-number}}",
            after: "{{build-number}}++\nprintf 'post:%s\\n' {{build-number}}")
        let command = #"printf 'main:%s|%s|%s|%s|%s\n' "{{build-number}}" '{{label}}' --opt={{label}} {{empty}} "$READY""#
        let (session, output, values) = try run(command, workflow: workflow)
        XCTAssertEqual(session.status, .succeeded, output)
        XCTAssertEqual(output, "[Runbar] 前置脚本\npre:10\n[Runbar] 主命令\nmain:10|\(label)|--opt=\(label)||ready\n[Runbar] 后置脚本\npost:11\n")
        XCTAssertEqual(values?.first?.defaultValue, "0009")
        XCTAssertEqual(values?.first?.currentValue, "11")
        XCTAssertEqual(values?.last?.currentValue, "")
        XCTAssertEqual(session.command, command)
    }

    func testFailureStopsLaterStagesAndDoesNotPersistChanges() throws {
        let count = CommandVariable(name: "count", defaultValue: "5")
        let cases = [
            ("{{count}}++\nreturn 4", "printf 'main ran'", "printf 'post ran'", Int32(4), false, false),
            ("{{count}}++", "printf 'main ran'; exit 7", "printf 'post ran'", Int32(7), true, false),
            ("{{count}}++", "printf 'main ran'", "{{count}}++\nprintf 'post ran'\nreturn 9", Int32(9), true, true)
        ]
        for (before, command, after, code, ranMain, ranPost) in cases {
            let (session, output, values) = try run(command, workflow: CommandWorkflow(variables: [count], before: before, after: after))
            XCTAssertEqual(session.status, .failed, output)
            XCTAssertEqual(session.exitCode, code)
            XCTAssertEqual(output.contains("main ran"), ranMain)
            XCTAssertEqual(output.contains("post ran"), ranPost)
            XCTAssertNil(values)
        }
    }

    func testSkipsNonIntegerAndOverflowAndSupportsDateAssignment() throws {
        let workflow = CommandWorkflow(variables: [CommandVariable(name: "text", defaultValue: "1.0.5"),
                                                    CommandVariable(name: "max", defaultValue: String(Int64.max)),
                                                    CommandVariable(name: "min", defaultValue: String(Int64.min)),
                                                    CommandVariable(name: "build-number")],
            before: "{{text}}++\n{{max}}++\n{{min}}--\n{{min}}++\n{{build-number}}={{Data-yyyyMMdd}}001")
        let (session, output, values) = try run("printf '%s|%s|%s|%s|%s' {{text}} {{max}} {{min}} {{build-number}} {{Date-yyyyMMdd}}", workflow: workflow)
        XCTAssertEqual(session.status, .succeeded, output)
        XCTAssertTrue(output.contains("当前值不是整数"))
        XCTAssertTrue(output.contains("超过整数范围"))
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyyMMdd"
        let day = date.string(from: session.startedAt)
        XCTAssertTrue(output.hasSuffix("1.0.5|\(Int64.max)|-9223372036854775807|\(day)001|\(day)"), output)
        XCTAssertEqual(values?.last?.currentValue, day + "001")
    }

    func testValidatesUnknownReferencesAndPreservesLegacyShellTemplates() throws {
        var project = Project(path: "/fixture", kind: .generic)
        try project.savePreset(name: "Old", command: "docker inspect --format '{{.State.Status}}' item")
        XCTAssertNil(project.selectedPreset?.workflow)
        let workflow = CommandWorkflow(variables: [CommandVariable(name: "count", defaultValue: "1")])
        XCTAssertThrowsError(try project.savePreset(name: "Unknown", command: "echo {{missing}}", workflow: workflow))
        XCTAssertThrowsError(try project.savePreset(name: "Main mutation", command: "{{count}}++", workflow: workflow))
        XCTAssertThrowsError(try project.savePreset(name: "Unsafe context", command: "echo $(({{count}}))", workflow: workflow))
        XCTAssertThrowsError(try project.savePreset(name: "Read only", command: "echo ready", workflow: CommandWorkflow(before: "{{ProjectPath}}=/tmp")))
    }
}
