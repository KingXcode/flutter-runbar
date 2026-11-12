import XCTest
@testable import RunbarCore

final class ProjectKindTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Runbar project \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ contents: String = "", to name: String, in root: URL) throws {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }
    func testEmptyDirectoryAndMissingDirectoryAreCustomOnly() throws {
        let root = try fixture()
        for path in [root.path, root.appendingPathComponent("missing").path] {
            let project = Project(path: path)
            XCTAssertEqual(project.kind, .generic)
            XCTAssertTrue(project.presets.isEmpty)
            XCTAssertTrue(project.availablePresets.isEmpty)
            XCTAssertNil(project.selectedPreset)
            XCTAssertTrue(CommandTemplate.templates(for: project).isEmpty)
        }
        XCTAssertTrue(CommandPreset().command.isEmpty)
    }
    func testRootMarkersAndFlutterPriority() throws {
        let cases: [(String, String, ProjectKind)] = [
            ("pubspec.yaml", "name: demo\ndependencies:\n  flutter:\n    sdk: 'flutter'\n", .flutter),
            ("Demo.xcodeproj/project.pbxproj", "", .xcode),
            ("Demo.xcworkspace/contents.xcworkspacedata", "", .xcode),
            ("app/src/main/AndroidManifest.xml", "", .android),
            ("build.gradle.kts", "plugins { id(\"com.android.application\") }", .android),
            ("Package.swift", "", .swiftPackage), ("package.json", "{}", .node),
            ("pyproject.toml", "[project]", .python), ("Cargo.toml", "", .rust),
            ("go.mod", "", .go), ("pubspec.yaml", "name: dart_library\n", .dart),
            ("settings.gradle", "", .gradle)
        ]
        for (name, contents, expected) in cases {
            let root = try fixture(); try write(contents, to: name, in: root)
            XCTAssertEqual(Project(path: root.path).kind, expected, name)
            XCTAssertTrue(Project(path: root.path).presets.isEmpty)
        }
        let mixed = try fixture()
        try write("dependencies:\n  flutter:\n    sdk: flutter # SDK\n", to: "pubspec.yaml", in: mixed)
        try write("", to: "App.xcodeproj/project.pbxproj", in: mixed)
        try write("", to: "android/app/src/main/AndroidManifest.xml", in: mixed)
        XCTAssertEqual(ProjectDetector.detect(at: mixed.path), .flutter)
        let nested = try fixture()
        try write("{}", to: "docs/package.json", in: nested)
        XCTAssertEqual(ProjectDetector.detect(at: nested.path), .generic)
    }
    func testManualTypePersistsAndLegacyCommandsAreUntouched() throws {
        let root = try fixture()
        try write("dependencies:\n  flutter:\n    sdk: flutter\n", to: "pubspec.yaml", in: root)
        var original = Project(path: root.path, presets: [CommandPreset(name: "Custom", command: "echo keep-me")])
        original.selectedPresetID = original.presets[0].id
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "kind")
        let restored = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.kind, .flutter)
        XCTAssertEqual(restored.presets, original.presets)
        XCTAssertEqual(restored.selectedPresetID, original.selectedPresetID)
        var custom = restored; custom.kind = .generic
        let reloaded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(reloaded.kind, .generic)
        XCTAssertEqual(reloaded.presets, original.presets)
        XCTAssertTrue(CommandTemplate.templates(for: reloaded).isEmpty)
    }
    func testOnlyFlutterOffersItsNativeSandboxActionAndFVM() throws {
        for kind in ProjectKind.allCases {
            let project = Project(path: try fixture().path, kind: kind)
            XCTAssertTrue(project.presets.isEmpty)
            XCTAssertEqual(project.availablePresets.contains { $0.builtInAction == .resetMacOSSandbox }, kind == .flutter)
            for template in CommandTemplate.templates(for: project) {
                XCTAssertEqual(template.supportsFVM, kind == .flutter)
                XCTAssertFalse(template.detail.isEmpty)
                if kind != .flutter { XCTAssertEqual(template.command(useFVM: true), template.command(useFVM: false)) }
            }
        }
    }
    func testNodeTemplatesFollowActualScriptsAndPackageManager() throws {
        let root = try fixture()
        try write(#"{"packageManager":"pnpm@10.0.0","scripts":{"dev":"vite","test":null,"strange'$(touch nope)":"echo safe"}}"#, to: "package.json", in: root)
        let templates = CommandTemplate.templates(for: Project(path: root.path))
        XCTAssertEqual(templates.first?.command(), "pnpm install")
        XCTAssertTrue(templates.contains { $0.command() == "pnpm run 'dev'" })
        XCTAssertFalse(templates.contains { $0.id == "node-script-build" || $0.id == "node-script-test" })
        XCTAssertTrue(templates.contains { $0.command() == "pnpm run 'strange'\\''$(touch nope)'" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("nope").path))
        XCTAssertTrue(Project(path: root.path).presets.isEmpty)
        try write("{}", to: "package.json", in: root)
        try write("", to: "yarn.lock", in: root)
        XCTAssertEqual(CommandTemplate.templates(for: Project(path: root.path)).first?.command(), "yarn install")
    }
    func testXcodeTemplatesUseRealQuotedContainerAndSharedSchemes() throws {
        let root = try fixture()
        try write("", to: "Demo App.xcodeproj/project.pbxproj", in: root)
        try write("", to: "Demo App.xcodeproj/xcshareddata/xcschemes/App's Scheme.xcscheme", in: root)
        let templates = CommandTemplate.templates(for: Project(path: root.path))
        XCTAssertEqual(templates.first?.command(), "xcodebuild -project 'Demo App.xcodeproj' -list")
        XCTAssertTrue(templates.contains { $0.command() == "xcodebuild -project 'Demo App.xcodeproj' -scheme 'App'\\''s Scheme' -configuration Debug build" })
        try write("", to: "Second.xcodeproj/project.pbxproj", in: root)
        let ambiguous = CommandTemplate.templates(for: Project(path: root.path))
        XCTAssertFalse(ambiguous.contains { $0.id.hasPrefix("xcode-build-") })
        try write("", to: "Demo.xcworkspace/contents.xcworkspacedata", in: root)
        let workspace = CommandTemplate.templates(for: Project(path: root.path))
        XCTAssertTrue(workspace.contains { $0.command() == "xcodebuild -workspace 'Demo.xcworkspace' -scheme 'App'\\''s Scheme' -configuration Debug build" })
    }
    func testAndroidUsesWrapperWhenPresentAndGenericGradleOtherwise() throws {
        let root = try fixture()
        try write("", to: "app/src/main/AndroidManifest.xml", in: root)
        XCTAssertEqual(CommandTemplate.templates(for: Project(path: root.path)).first?.command(), "gradle tasks --all")
        try write("exit 99", to: "gradlew", in: root)
        let templates = CommandTemplate.templates(for: Project(path: root.path))
        XCTAssertEqual(templates.first?.command(), "./gradlew tasks --all")
        XCTAssertTrue(templates.contains { $0.command() == "./gradlew assembleDebug" })
    }
    func testTemplateIDsAreUniqueAndCatalogueDoesNotModifySavedCommands() throws {
        let root = try fixture()
        try write(#"{"scripts":{"build":"echo build","test":"echo test"}}"#, to: "package.json", in: root)
        for kind in ProjectKind.allCases {
            let project = Project(path: root.path, presets: [CommandPreset(name: "Custom", command: "my own command")], kind: kind)
            let original = try JSONEncoder().encode(project)
            let templates = CommandTemplate.templates(for: project)
            XCTAssertEqual(Set(templates.map(\.id)).count, templates.count)
            XCTAssertEqual(project.presets[0].command, "my own command")
            XCTAssertEqual(try JSONDecoder().decode(Project.self, from: original), project)
        }
    }
}
