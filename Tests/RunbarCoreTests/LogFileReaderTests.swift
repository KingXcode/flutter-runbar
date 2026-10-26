import XCTest
@testable import RunbarCore

final class LogFileReaderTests: XCTestCase {
    private func withFile(_ bytes: Data, _ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("output.raw")
        try bytes.write(to: url)
        try body(url)
    }
    func testEmptyAndSmallLogsAreComplete() throws {
        try withFile(Data()) { url in
            let page = try LogFileReader.read(url)
            XCTAssertEqual(page.text, ""); XCTAssertEqual(page.totalBytes, 0)
            XCTAssertFalse(page.hasEarlier); XCTAssertFalse(page.hasLater)
        }
        try withFile(Data("开始\n结束🚀".utf8)) { url in
            let page = try LogFileReader.read(url)
            XCTAssertEqual(page.text, "开始\n结束🚀")
            XCTAssertFalse(page.hasEarlier); XCTAssertFalse(page.hasLater)
        }
    }
    func testEveryByteBoundaryPagesForwardWithoutDroppingUnicodeOrANSI() throws {
        let raw = String(repeating: "中文🚀\u{1b}[31mFAIL\u{1b}[0m é\n", count: 17)
        let expected = String(repeating: "中文🚀FAIL é\n", count: 17)
        try withFile(Data(raw.utf8)) { url in
            for budget in 4...60 {
                var offset: UInt64 = 0, result = ""
                while true {
                    let page = try LogFileReader.read(url, at: .after(offset), limit: budget)
                    result += page.text
                    XCTAssertGreaterThan(page.endOffset, offset)
                    XCTAssertLessThanOrEqual(page.endOffset - page.startOffset, UInt64(budget))
                    offset = page.endOffset
                    if !page.hasLater { break }
                }
                XCTAssertEqual(result, expected, "window size \(budget)")
            }
        }
    }
    func testPagesBackwardReachFileBeginningWithoutGaps() throws {
        let text = String(repeating: "每一段都可查看🚀\n", count: 37)
        try withFile(Data(text.utf8)) { url in
            for budget in 4...60 {
                var page = try LogFileReader.read(url, limit: budget)
                var pages = [page.text]
                while page.hasEarlier {
                    let next = try LogFileReader.read(url, at: .before(page.startOffset), limit: budget)
                    XCTAssertEqual(next.endOffset, page.startOffset)
                    XCTAssertLessThan(next.startOffset, page.startOffset)
                    pages.append(next.text); page = next
                }
                XCTAssertEqual(pages.reversed().joined(), text, "window size \(budget)")
            }
        }
    }
    func testLiveIncompleteScalarIsHeldThenCanBeReadAfterAppend() throws {
        let bytes = Array("hello🚀".utf8)
        try withFile(Data(bytes.dropLast(2))) { url in
            let page = try LogFileReader.read(url, at: .first, isLive: true)
            XCTAssertEqual(page.text, "hello")
            XCTAssertEqual(page.endOffset, 5)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd(); try handle.write(contentsOf: Data(bytes.suffix(2))); try handle.close()
            let next = try LogFileReader.read(url, at: .after(page.endOffset), isLive: true)
            XCTAssertEqual(page.text + next.text, "hello🚀")
            XCTAssertFalse(next.hasLater)
        }
    }
    func testHugeFileReadsBoundedWindowsAndCanReturnToOldOutput() throws {
        try withFile(Data("FIRST\n".utf8)) { url in
            let handle = try FileHandle(forWritingTo: url)
            let size: UInt64 = 3 * 1024 * 1024 * 1024
            try handle.truncate(atOffset: size)
            try handle.seek(toOffset: size - 5); try handle.write(contentsOf: Data("LAST\n".utf8)); try handle.close()
            let page = try LogFileReader.read(url, limit: Int.max)
            XCTAssertEqual(page.totalBytes, size)
            XCTAssertEqual(page.endOffset - page.startOffset, UInt64(LogFileReader.windowBytes))
            XCTAssertTrue(page.text.hasSuffix("LAST\n")); XCTAssertTrue(page.hasEarlier)
            XCTAssertTrue(try LogFileReader.read(url, at: .first).text.hasPrefix("FIRST\n"))
        }
    }
    func testTruncationInvalidBytesAndMissingFile() throws {
        try withFile(Data([0xFF, 0x0A, 0xE4, 0xBD])) { url in
            XCTAssertEqual(try LogFileReader.read(url).text, "�\n�")
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0); try handle.close()
            let page = try LogFileReader.read(url, at: .after(99))
            XCTAssertEqual(page.text, ""); XCTAssertEqual(page.totalBytes, 0)
            try FileManager.default.removeItem(at: url)
            XCTAssertThrowsError(try LogFileReader.read(url))
        }
    }
    func testGlobalScrollMetricsDescribeWholeFileInsteadOfLoadedWindow() {
        let middle = LogScrollMetrics(start: 200, end: 300, total: 1000, localProgress: 0.5, visibleFraction: 0.1)
        XCTAssertEqual(middle.value, 245.0 / 990, accuracy: 0.000001)
        XCTAssertEqual(middle.knobProportion, 0.01, accuracy: 0.000001)
        XCTAssertEqual(LogScrollMetrics(start: 0, end: 100, total: 1000, localProgress: 0, visibleFraction: 0.1).value, 0)
        XCTAssertEqual(LogScrollMetrics(start: 900, end: 1000, total: 1000, localProgress: 1, visibleFraction: 0.1).value, 1)
        let empty = LogScrollMetrics(start: 0, end: 0, total: 0, localProgress: 1, visibleFraction: 1)
        XCTAssertEqual(empty.value, 0); XCTAssertEqual(empty.knobProportion, 1)
        XCTAssertEqual(LogScrollMetrics.clamp(.nan), 0)
        XCTAssertEqual(LogScrollMetrics.clamp(-1), 0); XCTAssertEqual(LogScrollMetrics.clamp(2), 1)
    }
    func testAroundWindowsOverlapAndPreserveExactUnicodeANSIAnchor() throws {
        let lines = (0..<300).map { "\u{1b}[32m[\($0)] 中文🚀日志\u{1b}[0m\n" }
        let data = Data(lines.joined().utf8)
        try withFile(data) { url in
            for line in [5, 100, 200, 295] {
                let offset = UInt64(lines.prefix(line).joined().utf8.count)
                let page = try LogFileReader.read(url, at: .around(offset), limit: 512)
                XCTAssertLessThanOrEqual(page.startOffset, offset)
                XCTAssertGreaterThan(page.endOffset, offset)
                XCTAssertLessThanOrEqual(page.endOffset - page.startOffset, 512)
                let anchor = try XCTUnwrap(page.anchorUTF16Offset)
                XCTAssertTrue((page.text as NSString).substring(from: anchor).hasPrefix("[\(line)] 中文🚀日志\n"))
                let previous = try LogFileReader.read(url, at: .around(page.startOffset), limit: 512)
                let next = try LogFileReader.read(url, at: .around(page.endOffset), limit: 512)
                XCTAssertGreaterThan(previous.endOffset, page.startOffset)
                XCTAssertLessThan(next.startOffset, page.endOffset)
            }
        }
    }
    func testScrollbarSeeksDirectlyToFirstMiddleAndLastOfHugeFile() throws {
        try withFile(Data("FIRST\n".utf8)) { url in
            let handle = try FileHandle(forWritingTo: url)
            let size: UInt64 = 4 * 1024 * 1024 * 1024
            try handle.truncate(atOffset: size)
            try handle.seek(toOffset: size / 2); try handle.write(contentsOf: Data("MIDDLE\n".utf8))
            try handle.seek(toOffset: size - 5); try handle.write(contentsOf: Data("LAST\n".utf8)); try handle.close()
            let first = try LogFileReader.read(url, at: .fraction(0))
            XCTAssertEqual(first.startOffset, 0); XCTAssertTrue(first.text.hasPrefix("FIRST\n"))
            let middle = try LogFileReader.read(url, at: .fraction(0.5))
            XCTAssertEqual(middle.anchorByteOffset, size / 2)
            XCTAssertTrue((middle.text as NSString).substring(from: try XCTUnwrap(middle.anchorUTF16Offset)).hasPrefix("MIDDLE\n"))
            let last = try LogFileReader.read(url, at: .fraction(1))
            XCTAssertEqual(last.endOffset, size); XCTAssertTrue(last.text.hasSuffix("LAST\n"))
            for page in [first, middle, last] {
                XCTAssertLessThanOrEqual(page.endOffset - page.startOffset, UInt64(LogFileReader.windowBytes))
            }
        }
    }
}
