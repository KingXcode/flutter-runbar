import XCTest
@testable import RunbarCore

final class AppUpdateTests: XCTestCase {
    private func payload(tag: String = "v0.10.0+47", draft: Bool = false, prerelease: Bool = false,
                         host: String = "github.com", names: [String] = ["Runbar-0.10.0-47-macOS26.0-universal-signed.dmg"]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "body": "### 新增\n- 显示完整更新说明。\n<!-- runbar-notes-sha256:\(String(repeating: "a", count: 64)) -->",
            "html_url": "https://\(host)/KingXcode/flutter-runbar/releases/tag/\(tag)",
            "assets": names.map { ["name": $0, "size": 1024,
                "browser_download_url": "https://\(host)/KingXcode/flutter-runbar/releases/download/\(tag)/\($0)"] }
        ])
    }
    func testNumericVersionAndBuildOrdering() throws {
        XCTAssertTrue(try AppReleaseVersion(version: "0.10.0", build: 1) > AppReleaseVersion(version: "0.9.0", build: 99))
        XCTAssertTrue(try AppReleaseVersion(version: "0.10.0", build: 47) > AppReleaseVersion(version: "0.10.0", build: 9))
        for version in ["0.10", "0.10.0-beta", "-1.0.0", "0..1", "０.10.0"] {
            XCTAssertThrowsError(try AppReleaseVersion(version: version, build: 1))
        }
        XCTAssertThrowsError(try AppReleaseVersion(version: "0.10.0", build: -1))
    }
    func testAutomaticCheckUsesLocalDayIncludingYearBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 59))!
        XCTAssertTrue(AppUpdateSchedule.shouldCheck(lastAutomaticAttempt: nil, now: evening, calendar: calendar))
        XCTAssertFalse(AppUpdateSchedule.shouldCheck(lastAutomaticAttempt: evening.addingTimeInterval(-3600), now: evening, calendar: calendar))
        XCTAssertTrue(AppUpdateSchedule.shouldCheck(lastAutomaticAttempt: evening, now: evening.addingTimeInterval(120), calendar: calendar))
    }
    func testRejectsUntrustedOrUnstableMetadataAndBoundsResponse() throws {
        XCTAssertThrowsError(try AppUpdateRelease.parse(payload(draft: true)))
        XCTAssertThrowsError(try AppUpdateRelease.parse(payload(prerelease: true)))
        XCTAssertThrowsError(try AppUpdateRelease.parse(payload(tag: "v0.10.0")))
        XCTAssertThrowsError(try AppUpdateRelease.parse(payload(host: "github.com.example.com")))
        XCTAssertThrowsError(try AppUpdateRelease.parse(Data(repeating: 0, count: AppUpdateRelease.responseLimit + 1)))
        let release = try AppUpdateRelease.parse(payload())
        XCTAssertFalse(release.notes.contains("runbar-notes-sha256"))
        XCTAssertTrue(release.notes.contains("显示完整更新说明"))
        XCTAssertTrue(try release.isNewer(than: AppReleaseVersion(version: "0.9.0", build: 14)))
    }
    func testSelectsCompatibleDownloadAndSkipsFutureOSAndWrongArchitecture() throws {
        let release = try AppUpdateRelease.parse(payload(names: [
            "Runbar-0.10.0-47-macOS26.0-universal.zip",
            "Runbar-0.10.0-47-macOS26.0-universal-signed.dmg",
            "Runbar-0.10.0-47-macOS27.0-universal-signed.dmg",
            "Runbar-0.10.0-47-macOS26.0-x86_64-signed.dmg"
        ]))
        let os = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        XCTAssertEqual(release.compatibleAsset(architecture: "arm64", operatingSystem: os)?.name,
                       "Runbar-0.10.0-47-macOS26.0-universal-signed.dmg")
        XCTAssertNil(release.compatibleAsset(architecture: "arm64", operatingSystem: .init(majorVersion: 25, minorVersion: 9, patchVersion: 0)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload()) as? [String: Any])
        object["assets"] = [["name": "Runbar-0.10.0-47-macOS26.0-universal-signed.dmg", "size": 1024,
                            "browser_download_url": "https://evil.example/download.dmg"]]
        XCTAssertTrue(try AppUpdateRelease.parse(JSONSerialization.data(withJSONObject: object)).assets.isEmpty)
    }
}
