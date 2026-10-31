import XCTest
@testable import RunbarCore

final class HistoryManagementTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Runbar deletion \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func record(_ store: SessionStore, status: RunStatus = .succeeded) throws -> RunSession {
        var value = RunSession(projectPath: "/fixture/project", command: "echo fixture")
        value.status = status; try store.save(value)
        try Data(value.id.uuidString.utf8).write(to: store.directory(value.id).appendingPathComponent("output.raw"))
        return value
    }
    func testRepeatedHistoryLoadsIgnoreMetadataAndLooseFilesWithoutRemovingThem() throws {
        let root = try fixture(), store = try SessionStore(root: root)
        let session = try record(store)
        let sessions = root.appendingPathComponent("sessions")
        let finderFile = sessions.appendingPathComponent(".DS_Store")
        let looseFile = sessions.appendingPathComponent("notes.txt")
        let hiddenFolder = sessions.appendingPathComponent(".metadata")
        try Data("Finder metadata".utf8).write(to: finderFile)
        try Data("not a session".utf8).write(to: looseFile)
        try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: false)
        for _ in 0..<2 {
            let reopened = try SessionStore(root: root)
            try reopened.recoverInterrupted()
            XCTAssertTrue(reopened.warnings.isEmpty)
            XCTAssertEqual(try reopened.sessions().map(\.id), [session.id])
            XCTAssertTrue(reopened.warnings.isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: finderFile), Data("Finder metadata".utf8))
        XCTAssertEqual(try Data(contentsOf: looseFile), Data("not a session".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenFolder.path))
        XCTAssertEqual(try Data(contentsOf: store.outputFile(for: session.id)), Data(session.id.uuidString.utf8))
    }
    func testSingleToggleAndCommandMultiSelectionPreserveFocus() {
        let a = UUID(), b = UUID(), c = UUID(); let visible = [a, b, c]
        var selection = HistorySelection()
        selection.select(a, visible: visible); XCTAssertEqual(selection.ids, [a])
        selection.select(a, visible: visible); XCTAssertTrue(selection.ids.isEmpty); XCTAssertNil(selection.focusedID)
        selection.select(a, visible: visible)
        selection.select(c, visible: visible, mode: .toggle)
        XCTAssertEqual(selection.ids, [a, c]); XCTAssertEqual(selection.focusedID, c)
        selection.select(a, visible: visible, mode: .toggle)
        XCTAssertEqual(selection.ids, [c]); XCTAssertEqual(selection.focusedID, c)
        selection.select(c, visible: visible, mode: .toggle)
        XCTAssertTrue(selection.ids.isEmpty); XCTAssertNil(selection.focusedID)
    }
    func testShiftRangeAndProjectSwitchDoNotKeepHiddenSelections() {
        let ids = (0..<5).map { _ in UUID() }
        var selection = HistorySelection()
        selection.select(ids[1], visible: ids)
        selection.select(ids[4], visible: ids, mode: .range)
        XCTAssertEqual(selection.ids, Set(ids[1...4]))
        selection.select(ids[0], visible: ids, mode: .range)
        XCTAssertEqual(selection.ids, Set(ids[0...1]))
        selection.select(UUID(), visible: ids, mode: .toggle)
        XCTAssertEqual(selection.ids, Set(ids[0...1]))
        let other = UUID(); selection.setSingle(other)
        XCTAssertEqual(selection.ids, [other]); XCTAssertEqual(selection.focusedID, other)
    }
    func testDeletingSelectionRestoresEmptyOutputFocus() {
        let a = UUID(), b = UUID(), c = UUID()
        var selection = HistorySelection()
        selection.selectAll([a, b, c]); selection.remove([a, b], visible: [c])
        XCTAssertEqual(selection.ids, [c]); XCTAssertEqual(selection.focusedID, c)
        selection.remove([c], visible: [])
        XCTAssertTrue(selection.ids.isEmpty); XCTAssertNil(selection.focusedID)
    }
    func testBatchTrashMovesOnlyChosenRecordsAndLogsTogether() throws {
        let root = try fixture(); let trash = root.appendingPathComponent("Fake Trash")
        let store = try SessionStore(root: root.appendingPathComponent("Store"), trashDirectory: { try FileManager.default.moveItem(at: $0, to: trash) })
        let a = try record(store), b = try record(store), c = try record(store)
        try store.trashSessions([a.id, b.id])
        XCTAssertEqual(try store.sessions().map(\.id), [c.id])
        for session in [a, b] {
            let folder = trash.appendingPathComponent(session.id.uuidString)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.json").path))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("output.raw")), Data(session.id.uuidString.utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(session.id).path))
        }
    }
    func testActiveAndPersistedRunningRecordsBlockTheWholeBatch() throws {
        let root = try fixture(); var trashed = false
        let store = try SessionStore(root: root, trashDirectory: { _ in trashed = true })
        let a = try record(store), live = try record(store, status: .running)
        XCTAssertThrowsError(try store.trashSessions([a.id, live.id]))
        XCTAssertThrowsError(try store.trashSessions([a.id], activeSessionIDs: [a.id]))
        XCTAssertFalse(trashed)
        XCTAssertEqual(Set(try store.sessions().map(\.id)), [a.id, live.id])
    }
    func testTrashFailureRollsBackTheEntireBatch() throws {
        let root = try fixture()
        let store = try SessionStore(root: root, trashDirectory: { _ in throw NSError(domain: "trash denied", code: 1) })
        let a = try record(store), b = try record(store)
        XCTAssertThrowsError(try store.trashSessions([a.id, b.id]))
        XCTAssertEqual(Set(try store.sessions().map(\.id)), [a.id, b.id])
        XCTAssertEqual(try Data(contentsOf: store.outputFile(for: a.id)), Data(a.id.uuidString.utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("Runbar Deleted Records") })
    }
    func testMissingOrMismatchedRecordsDoNotMoveAnyFiles() throws {
        let root = try fixture(); var trashed = false
        let store = try SessionStore(root: root, trashDirectory: { _ in trashed = true })
        let a = try record(store), b = try record(store)
        XCTAssertThrowsError(try store.trashSessions([a.id, UUID()]))
        try FileManager.default.copyItem(at: store.directory(a.id).appendingPathComponent("session.json"), to: root.appendingPathComponent("copy.json"))
        try Data(contentsOf: root.appendingPathComponent("copy.json")).write(to: store.directory(b.id).appendingPathComponent("session.json"))
        XCTAssertThrowsError(try store.trashSessions([a.id, b.id]))
        XCTAssertFalse(trashed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.outputFile(for: a.id).path))
    }
    func testSymlinkRecordCannotDeleteItsExternalTarget() throws {
        let root = try fixture(); let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let store = try SessionStore(root: root.appendingPathComponent("Store"), trashDirectory: { _ in XCTFail("must not trash a symlink") })
        let id = UUID()
        try FileManager.default.createSymbolicLink(at: store.directory(id), withDestinationURL: external)
        XCTAssertThrowsError(try store.trashSessions([id]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }
    func testRemovingProjectPreservesOtherProjectsFilesAndHistory() throws {
        let root = try fixture(); let store = try SessionStore(root: root.appendingPathComponent("Store"))
        let a = Project(path: root.path, presets: [CommandPreset(name: "custom", command: "echo a")])
        let b = Project(path: "/fixture/b")
        var config = Configuration(); config.projects = [a, b]
        let history = try record(store)
        XCTAssertThrowsError(try config.removeProject(a.id, activeProjectIDs: [a.id]))
        XCTAssertEqual(config.projects, [a, b])
        XCTAssertEqual(try config.removeProject(a.id, activeProjectIDs: []), a)
        try store.saveConfiguration(config)
        XCTAssertEqual(try store.loadConfiguration().projects, [b])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(try store.sessions().map(\.id), [history.id])
        XCTAssertNil(try config.removeProject(UUID(), activeProjectIDs: []))
    }
}
