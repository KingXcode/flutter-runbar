import XCTest
import Darwin
@testable import RunbarCore

final class SandboxResetTests: XCTestCase {
    private let fm = FileManager.default
    private let identifier = "com.example.runbar-fixture"

    private final class Fixture {
        let root: URL
        let project: URL
        let home: URL
        let app: URL
        let container: URL
        var running = false
        var sandboxed = true
        var signedIdentifier = "com.example.runbar-fixture"
        var hash = Data([1, 2, 3])
        var trashed: [URL] = []
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("runbar-sandbox-test-" + UUID().uuidString)
                .standardizedFileURL.resolvingSymlinksInPath()
            project = root.appendingPathComponent("project")
            home = root.appendingPathComponent("home")
            app = project.appendingPathComponent("build/macos/Build/Products/Debug/Fixture.app")
            container = home.appendingPathComponent("Library/Containers/com.example.runbar-fixture")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: container.appendingPathComponent("Data/Documents"), withIntermediateDirectories: true)
            try write(["CFBundleIdentifier": signedIdentifier], to: app.appendingPathComponent("Contents/Info.plist"))
            try write(["MCMMetadataIdentifier": signedIdentifier], to: container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func write(_ plist: [String: Any], to url: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        }
        func service() -> SandboxResetService {
            // Never calls OS trash or inspects actual home/app containers.
            SandboxResetService(home: home, signature: { [unowned self] _ in
                SandboxSignature(identifier: self.signedIdentifier, sandboxed: self.sandboxed, codeHash: self.hash)
            }, isRunning: { [unowned self] _ in self.running }, trash: { [unowned self] url in
                self.trashed.append(url)
                return self.root.appendingPathComponent("simulated-trash")
            })
        }
        func plan(_ service: SandboxResetService) throws -> SandboxResetPlan {
            try service.inspect(projectPath: project.path, applicationURL: app)
        }
    }

    func testDiscoveryReturnsAllConfigurationsWithoutChoosing() throws {
        let f = try Fixture()
        let second = f.project.appendingPathComponent("build/macos/Build/Products/Release/Other.app")
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        let apps = try f.service().discoverApplications(projectPath: f.project.path)
        XCTAssertEqual(Set(apps.map(\.path)), Set([f.app.path, second.path]))
        XCTAssertEqual(f.trashed, [])
    }

    func testNoBuildProductsReturnsEmptyWithoutTrash() throws {
        let f = try Fixture()
        try fm.removeItem(at: f.project.appendingPathComponent("build"))
        XCTAssertTrue(try f.service().discoverApplications(projectPath: f.project.path).isEmpty)
        XCTAssertThrowsError(try f.plan(f.service()))
        XCTAssertTrue(f.trashed.isEmpty)
    }

    func testApplicationOutsideProjectIsRejected() throws {
        let f = try Fixture()
        XCTAssertThrowsError(try f.service().inspect(projectPath: f.project.path,
                                                    applicationURL: URL(fileURLWithPath: "/Applications/Other.app")))
        XCTAssertTrue(f.trashed.isEmpty)
    }

    func testInvalidIdentifierCannotSelectParentOrOtherPath() {
        for value in ["", "..", ".", "../other", "com.example/other", "com..example", ".example", "com.example.", "com example", "com.example\n"] {
            XCTAssertFalse(SandboxResetService.validIdentifier(value), value)
        }
        XCTAssertTrue(SandboxResetService.validIdentifier(identifier))
    }

    func testUnsignedIdentityMismatchAndUnsandboxedAreRejected() throws {
        let f = try Fixture()
        f.sandboxed = false
        XCTAssertThrowsError(try f.plan(f.service()))
        f.sandboxed = true; f.signedIdentifier = "com.example.other"
        XCTAssertThrowsError(try f.plan(f.service()))
        f.signedIdentifier = identifier; f.hash = Data()
        XCTAssertThrowsError(try f.plan(f.service()))
        XCTAssertTrue(f.trashed.isEmpty)
    }

    func testWrongContainerMetadataAndOwnerAreRejected() throws {
        let f = try Fixture()
        try f.write(["MCMMetadataIdentifier": "com.example.other"], to: f.container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        XCTAssertThrowsError(try f.plan(f.service()))
        let wrongOwner = SandboxResetService(home: f.home, owner: getuid() &+ 1,
            signature: { _ in .init(identifier: self.identifier, sandboxed: true, codeHash: Data([1])) },
            isRunning: { _ in false }, trash: { _ in XCTFail("Must not trash"); return nil })
        XCTAssertThrowsError(try f.plan(wrongOwner))
    }

    func testContainerSymlinkIsRejectedAndTargetUntouched() throws {
        let f = try Fixture()
        let moved = f.root.appendingPathComponent("outside-container")
        try fm.moveItem(at: f.container, to: moved)
        try fm.createSymbolicLink(at: f.container, withDestinationURL: moved)
        XCTAssertThrowsError(try f.plan(f.service()))
        XCTAssertTrue(fm.fileExists(atPath: moved.path))
        XCTAssertTrue(f.trashed.isEmpty)
    }

    func testBuildDirectorySymlinkIsRejected() throws {
        let f = try Fixture()
        let build = f.project.appendingPathComponent("build")
        let moved = f.root.appendingPathComponent("outside-build")
        try fm.moveItem(at: build, to: moved)
        try fm.createSymbolicLink(at: build, withDestinationURL: moved)
        XCTAssertThrowsError(try f.service().discoverApplications(projectPath: f.project.path))
        XCTAssertTrue(f.trashed.isEmpty)
    }

    func testCancellationNeverCallsTrash() throws {
        let f = try Fixture(); let service = f.service(); let plan = try f.plan(service)
        XCTAssertThrowsError(try service.reset(plan, approved: false)) { error in
            XCTAssertEqual(error as? SandboxResetError, .cancelled)
        }
        XCTAssertTrue(f.trashed.isEmpty)
    }

    func testRunningAppBeforeOrAfterConfirmationIsRejected() throws {
        let f = try Fixture(); let service = f.service()
        f.running = true
        XCTAssertThrowsError(try f.plan(service))
        f.running = false
        let plan = try f.plan(service)
        f.running = true
        XCTAssertThrowsError(try service.reset(plan, approved: true))
        XCTAssertTrue(f.trashed.isEmpty)
    }

    func testReplacedContainerOrAppSignatureRequiresNewConfirmation() throws {
        let f = try Fixture(); let service = f.service(); let plan = try f.plan(service)
        let old = f.root.appendingPathComponent("old-container")
        try fm.moveItem(at: f.container, to: old)
        try fm.copyItem(at: old, to: f.container)
        XCTAssertThrowsError(try service.reset(plan, approved: true))
        let newPlan = try f.plan(service)
        f.hash = Data([9])
        XCTAssertThrowsError(try service.reset(newPlan, approved: true))
        XCTAssertTrue(f.trashed.isEmpty)
    }

    func testApprovedResetTargetsEntireContainerOnlyNotLinkedExternalData() throws {
        let f = try Fixture(); let service = f.service()
        let outside = f.root.appendingPathComponent("external-documents")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("important.txt"))
        try fm.createSymbolicLink(at: f.container.appendingPathComponent("Data/External"), withDestinationURL: outside)
        let plan = try f.plan(service)
        let destination = try service.reset(plan, approved: true)
        XCTAssertEqual(f.trashed.map(\.path), [f.container.path])
        XCTAssertEqual(destination?.path, f.root.appendingPathComponent("simulated-trash").path)
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("important.txt"), encoding: .utf8), "keep")
    }

    func testTrashFailurePropagatesWithoutFallback() throws {
        let f = try Fixture()
        var attempts = 0
        let service = SandboxResetService(home: f.home,
            signature: { _ in .init(identifier: self.identifier, sandboxed: true, codeHash: Data([1])) },
            isRunning: { _ in false }, trash: { _ in attempts += 1; throw SandboxResetError.unsafe("OS denied") })
        let plan = try f.plan(service)
        XCTAssertThrowsError(try service.reset(plan, approved: true))
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(fm.fileExists(atPath: f.container.path))
    }

    func testUnreadableMetadataOffersPermissionGuidanceWithoutTrash() throws {
        guard getuid() != 0 else { throw XCTSkip("POSIX read-denial fixture requires a non-root user") }
        let f = try Fixture()
        let metadata = f.container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: metadata.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path) }
        XCTAssertThrowsError(try f.plan(f.service())) { error in
            XCTAssertEqual(error as? SandboxResetError, .permissionDenied(containerPath: f.container.path))
            XCTAssertTrue(error.localizedDescription.contains("完全磁盘访问权限"))
        }
        XCTAssertTrue(f.trashed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: f.container.path))
    }

    func testUnreadableContainerPreservesPOSIXPermissionFailure() throws {
        guard getuid() != 0 else { throw XCTSkip("POSIX access-denial fixture requires a non-root user") }
        let f = try Fixture()
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: f.container.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.container.path) }
        XCTAssertThrowsError(try f.plan(f.service())) { error in
            XCTAssertEqual(error as? SandboxResetError, .permissionDenied(containerPath: f.container.path))
        }
        XCTAssertTrue(f.trashed.isEmpty)
    }

    func testPermissionLostAfterConfirmationNeverCallsTrash() throws {
        guard getuid() != 0 else { throw XCTSkip("POSIX read-denial fixture requires a non-root user") }
        let f = try Fixture(), service = f.service()
        let plan = try f.plan(service)
        let metadata = f.container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: metadata.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path) }
        XCTAssertThrowsError(try service.reset(plan, approved: true)) { error in
            XCTAssertEqual(error as? SandboxResetError, .permissionDenied(containerPath: f.container.path))
        }
        XCTAssertTrue(f.trashed.isEmpty)
    }

    func testTrashPermissionDenialOffersGuidanceWithoutRetry() throws {
        let f = try Fixture()
        var attempts = 0
        let service = SandboxResetService(home: f.home,
            signature: { _ in .init(identifier: self.identifier, sandboxed: true, codeHash: Data([1])) },
            isRunning: { _ in false }, trash: { _ in
                attempts += 1
                throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
            })
        let plan = try f.plan(service)
        XCTAssertThrowsError(try service.reset(plan, approved: true)) { error in
            XCTAssertEqual(error as? SandboxResetError, .permissionDenied(containerPath: f.container.path))
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(fm.fileExists(atPath: f.container.path))
    }

    func testPermissionClassifierDoesNotRelyOnErrorText() {
        for error in [NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue),
                      NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue),
                      NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
                      NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))] {
            XCTAssertTrue(SandboxResetService.isPermissionDenied(error))
        }
        for error: Error in [NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileNoSuchFile.rawValue),
                             NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
                             SandboxResetError.unsafe("permission denied: unverified identity")] {
            XCTAssertFalse(SandboxResetService.isPermissionDenied(error))
        }
    }

    func testInvalidMetadataDoesNotOfferPermissionGuidance() throws {
        let f = try Fixture()
        try Data("invalid property list".utf8).write(to: f.container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        XCTAssertThrowsError(try f.plan(f.service())) { error in
            if case .permissionDenied = error as? SandboxResetError { XCTFail("Invalid data is not a permission failure") }
        }
        XCTAssertTrue(f.trashed.isEmpty)
    }

    func testPermissionFailureOutsideContainerDoesNotOfferContainerAccess() throws {
        let f = try Fixture()
        let service = SandboxResetService(home: f.home,
            signature: { _ in throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue) },
            isRunning: { _ in false }, trash: { _ in XCTFail("Must not trash"); return nil })
        XCTAssertThrowsError(try f.plan(service)) { error in
            XCTAssertNil(error as? SandboxResetError)
        }
    }
}
