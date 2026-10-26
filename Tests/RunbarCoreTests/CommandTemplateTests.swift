import XCTest
@testable import RunbarCore

final class CommandTemplateTests: XCTestCase {
    func testCatalogueHasUniqueIDsCommandsAndDocumentedEffects() {
        let templates = CommandTemplate.all
        XCTAssertEqual(templates.count, 15)
        XCTAssertEqual(Set(templates.map(\.id)).count, templates.count)
        XCTAssertEqual(Set(templates.map { $0.command() }).count, templates.count)
        for template in templates {
            XCTAssertFalse(template.detail.isEmpty)
            XCTAssertEqual(template.command(), "fvm " + template.command(useFVM: false))
        }
        XCTAssertEqual(templates.first { $0.id == "format" }?.command(), "fvm dart format .")
        XCTAssertEqual(templates.first { $0.id == "build-ios" }?.command(), "fvm flutter build ios --release --no-codesign")
    }
    func testOptInAddEditAndDuplicateRejection() throws {
        var project = Project(path: "/fictional/project")
        let original = project.presets
        let template = try XCTUnwrap(CommandTemplate.all.first { $0.id == "pub-get" })
        try project.savePreset(name: template.name, command: template.command())
        XCTAssertEqual(project.presets.count, 2)
        XCTAssertEqual(project.presets.first, original.first)
        let added = try XCTUnwrap(project.selectedPreset)
        XCTAssertNotEqual(added.id, original[0].id)
        XCTAssertThrowsError(try project.savePreset(name: "duplicate", command: " \(template.command())\n"))
        XCTAssertEqual(project.presets.count, 2)
        try project.savePreset(name: "自定义依赖", command: "fvm flutter pub get --offline", id: added.id)
        XCTAssertEqual(project.selectedPresetID, added.id)
        XCTAssertEqual(project.selectedPreset?.command, "fvm flutter pub get --offline")
        XCTAssertEqual(template.command(), "fvm flutter pub get")
        XCTAssertThrowsError(try project.savePreset(name: "", command: "echo ok"))
        XCTAssertThrowsError(try project.savePreset(name: "missing", command: "echo ok", id: UUID()))
        XCTAssertThrowsError(try project.savePreset(name: "duplicate edit", command: original[0].command, id: added.id))
    }
    func testExistingAndLegacyConfigurationNotPopulatedOrReSelected() throws {
        var project = Project(path: "/fictional/legacy")
        project.presets = [CommandPreset(name: "Custom", command: "flutter test --coverage")]
        project.selectedPresetID = project.presets[0].id
        let encoded = try JSONEncoder().encode(project)
        let restored = try JSONDecoder().decode(Project.self, from: encoded)
        XCTAssertEqual(restored, project)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "selectedPresetID")
        let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.presets, project.presets)
        XCTAssertNil(decoded.selectedPresetID)
        XCTAssertEqual(decoded.selectedPreset?.id, project.presets[0].id)
        XCTAssertEqual(Project(path: "/new").presets.count, 1)
    }
    func testBuiltInIsTypedSelectableAndPreservesLegacyShellPresets() throws {
        var project = Project(path: "/fixture")
        let shellID = project.presets[0].id
        XCTAssertEqual(project.availablePresets.count, 2)
        XCTAssertEqual(project.selectedPreset?.id, shellID)
        project.selectedPresetID = CommandPreset.sandboxReset.id
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(restored.selectedPreset?.builtInAction, .resetMacOSSandbox)
        XCTAssertEqual(restored.presets.count, 1)
        XCTAssertEqual(restored.presets[0].id, shellID)
        XCTAssertTrue(CommandPreset.sandboxReset.command.isEmpty)
        XCTAssertThrowsError(try project.savePreset(name: "unsafe", command: "echo no", id: CommandPreset.sandboxReset.id))
        let legacy = "{\"id\":\"00000000-0000-4000-8000-000000000001\",\"name\":\"Old\",\"command\":\"echo old\"}"
        let decoded = try JSONDecoder().decode(CommandPreset.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.builtInAction)
        XCTAssertEqual(decoded.command, "echo old")
    }
}
