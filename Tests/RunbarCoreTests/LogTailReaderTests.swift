import XCTest
@testable import RunbarCore

final class LogTailReaderTests: XCTestCase {
    private func withFile(_ data: Data, _ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("output.raw")
        try data.write(to: url)
        try body(url)
    }
    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    private func verifyChange(from old: LogFilePage, to new: LogFilePage, file: StaticString = #filePath, line: UInt = #line) throws {
        let change = try XCTUnwrap(new.change, file: file, line: line)
        XCTAssertEqual(change.baseStartOffset, old.startOffset, file: file, line: line)
        XCTAssertEqual(change.baseEndOffset, old.endOffset, file: file, line: line)
        XCTAssertEqual(change.baseUTF16Length, old.text.utf16.count, file: file, line: line)
        let updated = (old.text as NSString).substring(from: change.removedUTF16Count) + change.insertedText
        XCTAssertEqual(updated, new.text, file: file, line: line)
        XCTAssertLessThanOrEqual(new.endOffset - new.startOffset, UInt64(LogFileReader.windowBytes), file: file, line: line)
    }
    func testLargeLogRefreshReadsOnlyNewBytesAndProvidesNativeTextEdits() throws {
        try withFile(Data("FIRST\n".utf8)) { url in
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 24 * 1024 * 1024)
            try handle.seekToEnd(); try handle.write(contentsOf: Data("LAST\n".utf8)); try handle.close()
            var reader = LogTailReader()
            let first = try reader.read(url, isLive: true)
            XCTAssertLessThanOrEqual(reader.bytesReadLastRefresh, LogTailReader.liveWindowBytes + 4096)
            let delta = Data("\u{1b}[32m新增中文🚀\u{1b}[0m\n".utf8)
            try append(delta, to: url)
            let next = try reader.read(url, isLive: true)
            XCTAssertEqual(reader.bytesReadLastRefresh, delta.count)
            XCTAssertTrue(next.text.hasSuffix("LAST\n新增中文🚀\n"))
            try verifyChange(from: first, to: next)
            let unchanged = try reader.read(url, isLive: true)
            XCTAssertEqual(reader.bytesReadLastRefresh, 0)
            XCTAssertEqual(unchanged.text, next.text)
        }
    }
    func testUnicodeAndANSISplitAcrossEveryLiveRefresh() throws {
        try withFile(Data()) { url in
            var reader = LogTailReader()
            var page = try reader.read(url, isLive: true)
            let text = "你好\u{1b}[31m错误🚀\u{1b}[0m\n"
            for byte in text.utf8 {
                try append(Data([byte]), to: url)
                let next = try reader.read(url, isLive: true)
                XCTAssertEqual(reader.bytesReadLastRefresh, 1)
                try verifyChange(from: page, to: next)
                page = next
            }
            XCTAssertEqual(page.text, "你好错误🚀\n")
            XCTAssertEqual(reader.retainedChunkCount, 1)
        }
    }
    func testRollingEvictionIsBatchedAndEveryEditMatchesRenderedWindow() throws {
        try withFile(Data(repeating: 65, count: LogFileReader.windowBytes)) { url in
            var reader = LogTailReader()
            var page = try reader.read(url, isLive: true)
            var evictions = 0
            let delta = Data((String(repeating: "日志🚀\u{1b}[32mx\u{1b}[0m\n", count: 64)).utf8)
            for _ in 0..<200 {
                try append(delta, to: url)
                let next = try reader.read(url, isLive: true)
                XCTAssertEqual(reader.bytesReadLastRefresh, delta.count)
                try verifyChange(from: page, to: next)
                if (next.change?.removedUTF16Count ?? 0) > 0 { evictions += 1 }
                XCTAssertLessThanOrEqual(reader.retainedChunkCount, 40)
                page = next
            }
            XCTAssertGreaterThan(evictions, 0)
            XCTAssertLessThan(evictions, 10, "Head trimming must not occur for every refresh")
        }
    }
    func testManyTinyAppendsCoalesceChunkMetadata() throws {
        try withFile(Data()) { url in
            var reader = LogTailReader()
            _ = try reader.read(url, isLive: true)
            for _ in 0..<256 {
                try append(Data([65]), to: url)
                _ = try reader.read(url, isLive: true)
            }
            XCTAssertEqual(reader.retainedChunkCount, 1)
        }
    }
    func testHugeBurstRebuildsOnlyBoundedTail() throws {
        try withFile(Data("OLD\n".utf8)) { url in
            var reader = LogTailReader()
            _ = try reader.read(url, isLive: true)
            try append(Data(repeating: 66, count: 2 * LogFileReader.windowBytes) + Data("NEWEST\n".utf8), to: url)
            let page = try reader.read(url, isLive: true)
            XCTAssertNil(page.change)
            XCTAssertTrue(page.text.hasSuffix("NEWEST\n"))
            XCTAssertLessThanOrEqual(reader.bytesReadLastRefresh, LogFileReader.windowBytes + 4096)
            XCTAssertLessThanOrEqual(page.endOffset - page.startOffset, UInt64(LogFileReader.windowBytes))
        }
    }
    func testFinalIncompleteScalarFlushesAndTruncatedOrReplacedFilesReset() throws {
        try withFile(Data("hello".utf8) + Data([0xE4, 0xBD])) { url in
            var reader = LogTailReader()
            let live = try reader.read(url, isLive: true)
            XCTAssertEqual(live.text, "hello"); XCTAssertEqual(live.endOffset, 5)
            let finished = try reader.read(url, isLive: false)
            XCTAssertEqual(finished.text, "hello�"); XCTAssertEqual(finished.endOffset, 7)
            try verifyChange(from: live, to: finished)
            try Data("short".utf8).write(to: url)
            XCTAssertEqual(try reader.read(url, isLive: true).text, "short")
            try Data("replacement".utf8).write(to: url, options: .atomic)
            XCTAssertEqual(try reader.read(url, isLive: true).text, "replacement")
            let other = url.deletingLastPathComponent().appendingPathComponent("another.raw")
            try Data("another session".utf8).write(to: other)
            XCTAssertEqual(try reader.read(other, isLive: true).text, "another session")
        }
    }
    func testLiveWindowStaysSmallAndExpandsWhenViewingFinishedLog() throws {
        try withFile(Data(repeating: 65, count: 3 * LogFileReader.windowBytes)) { url in
            var reader = LogTailReader()
            let live = try reader.read(url, isLive: true)
            XCTAssertLessThanOrEqual(live.endOffset - live.startOffset, UInt64(LogTailReader.liveWindowBytes))
            let finished = try reader.read(url, isLive: false)
            XCTAssertEqual(finished.endOffset - finished.startOffset, UInt64(LogFileReader.windowBytes))
            XCTAssertNil(finished.change)
        }
    }
}
