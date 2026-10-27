import XCTest
@testable import RunbarCore

final class CommandTemplateTests: XCTestCase {
    func testCatalogueHasUniqueIDsCommandsAndDocumentedEffects() {
        let templates = CommandTemplate.flutter
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
        var project = Project(path: "/fictional/project", presets: [CommandPreset(name: "自定义", command: "echo original")])
        let original = project.presets
        let template = try XCTUnwrap(CommandTemplate.flutter.first { $0.id == "pub-get" })
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
    func testFlutterRunModesGenerateIndependentEditablePresets() throws {
        for id in ["run-macos", "run-chrome"] {
            let template = try XCTUnwrap(CommandTemplate.flutter.first { $0.id == id })
            let device = id == "run-macos" ? "macos" : "chrome"
            var project = Project(path: "/fixture", kind: .flutter)
            for mode in FlutterRunMode.allCases {
                XCTAssertEqual(template.command(useFVM: false, runMode: mode), "flutter run -d \(device) --\(mode.rawValue)")
                XCTAssertEqual(template.command(runMode: mode), "fvm flutter run -d \(device) --\(mode.rawValue)")
                try project.savePreset(name: template.presetName(runMode: mode), command: template.command(runMode: mode))
            }
            XCTAssertEqual(project.presets.count, 3)
            let profile = project.presets[1]
            XCTAssertTrue(profile.name.contains("Profile"))
            // A generated mode is plain editable shell text after insertion.
            try project.savePreset(name: profile.name, command: profile.command + " --flavor staging -t lib/staging.dart", id: profile.id)
            XCTAssertTrue(project.presets[1].command.hasSuffix("--profile --flavor staging -t lib/staging.dart"))
            XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
        }
        let dependency = try XCTUnwrap(CommandTemplate.flutter.first { $0.id == "pub-get" })
        let build = try XCTUnwrap(CommandTemplate.flutter.first { $0.id == "build-macos" })
        XCTAssertFalse(dependency.supportsFlutterRunMode)
        XCTAssertEqual(dependency.command(runMode: .release), "fvm flutter pub get")
        XCTAssertEqual(build.command(runMode: .debug), "fvm flutter build macos --release")
        XCTAssertEqual(CommandTemplate.flutter[0].command(), "fvm flutter run -d macos --debug")
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
        XCTAssertEqual(Project(path: "/new").presets.count, 0)
    }
    func testBuiltInIsTypedSelectableAndPreservesLegacyShellPresets() throws {
        var project = Project(path: "/fixture", presets: [CommandPreset(name: "运行 macOS", command: "fvm flutter run -d macos")], kind: .flutter)
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
