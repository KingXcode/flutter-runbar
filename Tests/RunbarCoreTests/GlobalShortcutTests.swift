import XCTest
@testable import RunbarCore

final class GlobalShortcutTests: XCTestCase {
    func testDefaultF3AndSavedCustomShortcutRoundTrip() throws {
        XCTAssertEqual(try GlobalShortcut.f3.validated().displayName, "F3")
        let shortcut = GlobalShortcut(keyCode: 15, modifiers: [.command, .option], keyName: "R")
        XCTAssertEqual(try shortcut.validated().displayName, "⌥⌘R")
        let preferences = GlobalShortcutPreferences(enabled: true, shortcut: shortcut)
        XCTAssertEqual(try JSONDecoder().decode(GlobalShortcutPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
        XCTAssertFalse(GlobalShortcutPreferences(enabled: false).enabled)
    }
    func testRejectsKeysThatWouldStealOrdinaryTypingAndAcceptsFunctionKeys() throws {
        XCTAssertThrowsError(try GlobalShortcut(keyCode: 0, modifiers: [], keyName: "A").validated())
        XCTAssertThrowsError(try GlobalShortcut(keyCode: 0, modifiers: [.shift], keyName: "A").validated())
        XCTAssertThrowsError(try GlobalShortcut(keyCode: 53, modifiers: [.command], keyName: "Esc").validated())
        XCTAssertThrowsError(try GlobalShortcut(keyCode: 200, modifiers: [.command], keyName: "Invalid").validated())
        for code in GlobalShortcut.functionKeys.keys { XCTAssertNoThrow(try GlobalShortcut(keyCode: code, modifiers: [], keyName: "Fn").validated()) }
        XCTAssertNoThrow(try GlobalShortcut(keyCode: 0, modifiers: [.control], keyName: "A").validated())
    }
    func testProcessOwnershipChecksPrivateGroupOrAncestryAndStopsCycles() {
        let parents: [Int32: Int32] = [100: 50, 101: 100, 102: 101, 200: 1, 300: 301, 301: 300]
        let groups: [Int32: Int32] = [100: 100, 101: 100, 102: 102, 200: 200]
        let parent: (Int32) -> Int32 = { parents[$0] ?? 0 }
        let group: (Int32) -> Int32 = { groups[$0] ?? -1 }
        XCTAssertTrue(ProcessOwnership.belongsToRun(100, roots: [100], parent: parent, group: group))
        XCTAssertTrue(ProcessOwnership.belongsToRun(101, roots: [100], parent: parent, group: group))
        XCTAssertTrue(ProcessOwnership.belongsToRun(102, roots: [100], parent: parent, group: group))
        XCTAssertFalse(ProcessOwnership.belongsToRun(200, roots: [100], parent: parent, group: group))
        XCTAssertFalse(ProcessOwnership.belongsToRun(300, roots: [100], parent: parent, group: group))
        XCTAssertFalse(ProcessOwnership.belongsToRun(0, roots: [0, 1], parent: parent, group: group))
    }
    func testReparentedApplicationsRequireMatchingProjectAndRecentLaunch() {
        let started = Date(timeIntervalSince1970: 100)
        let bundle = URL(fileURLWithPath: "/tmp/project/build/My.app")
        XCTAssertTrue(ProcessOwnership.isNewProjectApplication(bundle, launchedAt: started, projectPath: "/tmp/project", startedAt: started))
        XCTAssertFalse(ProcessOwnership.isNewProjectApplication(bundle, launchedAt: Date(timeIntervalSince1970: 99), projectPath: "/tmp/project", startedAt: started))
        XCTAssertFalse(ProcessOwnership.isNewProjectApplication(URL(fileURLWithPath: "/tmp/project-other/My.app"), launchedAt: started, projectPath: "/tmp/project", startedAt: started))
        XCTAssertFalse(ProcessOwnership.isNewProjectApplication(bundle, launchedAt: nil, projectPath: "/tmp/project", startedAt: started))
    }
}
