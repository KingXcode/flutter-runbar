import XCTest
@testable import RunbarCore

final class LogQueryTests: XCTestCase {
    private func fixture(_ data: Data = Data(), _ body: (URL, LogQueryProcessor) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("output.raw")
        try data.write(to: url)
        try body(url, LogQueryProcessor())
    }
    private func append(_ text: Data, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: text)
    }
    func testFilterORAndExcludePriorityAndSearchStillIncludesHiddenLines() throws {
        let input = "INFO ready\nERROR red\nWARN yellow\nERROR ignore\nwarn lower\n"
        try fixture(Data(input.utf8)) { url, worker in
            let filter = LogFilter(includes: ["ERROR", "WARN"], excludes: ["ignore", "unused"])
            let result = try worker.update(url, filter: filter, query: "ERROR", isLive: false)
            XCTAssertEqual(try String(contentsOf: result.filteredURL, encoding: .utf8), "ERROR red\nWARN yellow\n")
            XCTAssertEqual(try String(contentsOf: result.fullURL, encoding: .utf8), input)
            XCTAssertEqual(result.matchCount, 2)
            XCTAssertEqual(try worker.matchOffset(at: 1), 11)
            XCTAssertEqual(try worker.matchOffset(at: 2), UInt64(input.range(of: "ERROR ignore")!.lowerBound.utf16Offset(in: input)))
            let excludes = try worker.update(url, filter: LogFilter(excludes: ["ERROR"]), query: "", isLive: false)
            XCTAssertEqual(try String(contentsOf: excludes.filteredURL, encoding: .utf8), "INFO ready\nWARN yellow\nwarn lower\n")
        }
    }
    func testUTF8ANSIAndKeywordsAcrossChunkBoundaryAndSearchPageAnchor() throws {
        let prefix = String(repeating: "a", count: LogQueryProcessor.chunkBytes - 3)
        let raw = prefix + "\u{1b}[31m中文🚀ERROR\u{1b}[0m tail\nother\n"
        try fixture(Data(raw.utf8)) { url, worker in
            let result = try worker.update(url, filter: LogFilter(includes: ["文🚀ERROR"]), query: "中文🚀ERROR", isLive: false)
            let clean = prefix + "中文🚀ERROR tail\n"
            XCTAssertEqual(try String(contentsOf: result.filteredURL, encoding: .utf8), clean)
            XCTAssertEqual(result.matchCount, 1)
            let offset = try worker.matchOffset(at: 1)
            XCTAssertEqual(offset, UInt64(prefix.utf8.count))
            let page = try LogFileReader.read(result.fullURL, at: .around(offset))
            let text = page.text as NSString
            XCTAssertEqual(text.substring(with: NSRange(location: try XCTUnwrap(page.anchorUTF16Offset), length: "中文🚀ERROR".utf16.count)), "中文🚀ERROR")
        }
    }
    func testLivePartialLineCanBecomeVisibleThenHiddenWithoutStaleTail() throws {
        try fixture(Data("keep done\nstart ".utf8)) { url, worker in
            let filter = LogFilter(includes: ["keep"], excludes: ["secret"])
            let first = try worker.update(url, filter: filter, query: "keep", isLive: true)
            XCTAssertEqual(try String(contentsOf: first.filteredURL, encoding: .utf8), "keep done\n")
            try append(Data("keep 中文".utf8), to: url)
            let second = try worker.update(url, filter: filter, query: "keep", isLive: true)
            XCTAssertEqual(worker.bytesReadLastUpdate, UInt64("keep 中文".utf8.count))
            XCTAssertEqual(try String(contentsOf: second.filteredURL, encoding: .utf8), "keep done\nstart keep 中文")
            try append(Data(" secret\nkeep next".utf8), to: url)
            let third = try worker.update(url, filter: filter, query: "keep", isLive: true)
            XCTAssertEqual(try String(contentsOf: third.filteredURL, encoding: .utf8), "keep done\nkeep next")
            XCTAssertGreaterThan(third.filterRevision, second.filterRevision)
            XCTAssertEqual(third.matchCount, 3)
            _ = try worker.update(url, filter: filter, query: "keep", isLive: true)
            XCTAssertEqual(worker.bytesReadLastUpdate, 0)
        }
    }
    func testMillionsOfHitsUseDiskIndexWithBoundedRetainedMemoryAndRandomAccess() throws {
        try fixture(Data(String(repeating: "x ", count: 1_000_000).utf8)) { url, worker in
            let result = try worker.update(url, filter: LogFilter(), query: "x", isLive: false)
            XCTAssertEqual(result.matchCount, 1_000_000)
            XCTAssertEqual(try worker.matchOffset(at: 1), 0)
            XCTAssertEqual(try worker.matchOffset(at: 500_001), 1_000_000)
            XCTAssertEqual(try worker.matchOffset(at: 1_000_000), 1_999_998)
            XCTAssertLessThan(worker.retainedOverlapBytes, 8192)
            let index = result.fullURL.deletingLastPathComponent().appendingPathComponent("matches.idx")
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: index.path)[.size] as? Int, 8_000_000)
            XCTAssertThrowsError(try worker.matchOffset(at: 0))
            XCTAssertThrowsError(try worker.matchOffset(at: 1_000_001))
            let folder = result.fullURL.deletingLastPathComponent()
            worker.reset()
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        }
    }
    func testHugeSingleLineSpoolsToDiskAndLateKeywordDoesNotRequireWholeLineInMemory() throws {
        try fixture() { url, worker in
            let block = Data(repeating: 65, count: LogQueryProcessor.chunkBytes)
            for _ in 0..<160 { try append(block, to: url) }
            let filter = LogFilter(includes: ["END"], excludes: ["HIDE"])
            let first = try worker.update(url, filter: filter, query: "", isLive: true)
            XCTAssertEqual(first.filteredBytes, 0)
            XCTAssertLessThan(worker.retainedOverlapBytes, 8192)
            try append(Data("END".utf8), to: url)
            let second = try worker.update(url, filter: filter, query: "", isLive: true)
            XCTAssertEqual(second.filteredBytes, 160 * UInt64(block.count) + 3)
            XCTAssertEqual(worker.bytesReadLastUpdate, 3)
            try append(Data(" HIDE\nnext END\n".utf8), to: url)
            let third = try worker.update(url, filter: filter, query: "", isLive: false)
            XCTAssertEqual(try String(contentsOf: third.filteredURL, encoding: .utf8), "next END\n")
            XCTAssertLessThan(worker.retainedOverlapBytes, 8192)
        }
    }
    func testIncompleteUTF8AndANSIAppendsAndNewlineBoundaries() throws {
        try fixture() { url, worker in
            var result: LogQuerySnapshot?
            let raw = "\u{1b}[32m中文🚀\u{1b}[0m\nfoo\nbar\n"
            for byte in raw.utf8 {
                try append(Data([byte]), to: url)
                result = try worker.update(url, filter: LogFilter(includes: ["中文", "foobar"]), query: "文🚀", isLive: true)
            }
            let final = try XCTUnwrap(result)
            XCTAssertEqual(final.matchCount, 1)
            XCTAssertEqual(try String(contentsOf: final.filteredURL, encoding: .utf8), "中文🚀\n")
            XCTAssertEqual(try worker.matchOffset(at: 1), 3)
        }
    }
    func testQueryChangesTruncationAndAtomicReplacementRebuildAndRemoveOldFiles() throws {
        try fixture(Data("aba aba".utf8)) { url, worker in
            let first = try worker.update(url, filter: LogFilter(), query: "aba", isLive: false)
            XCTAssertEqual(first.matchCount, 2)
            let second = try worker.update(url, filter: LogFilter(), query: "ba", isLive: false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: first.fullURL.path))
            XCTAssertEqual(try worker.matchOffset(at: 1), 1)
            try Data("ba".utf8).write(to: url)
            let short = try worker.update(url, filter: LogFilter(), query: "ba", isLive: false)
            XCTAssertEqual(short.matchCount, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: second.fullURL.path))
            try Data("xx".utf8).write(to: url, options: .atomic)
            XCTAssertEqual(try worker.update(url, filter: LogFilter(), query: "ba", isLive: false).matchCount, 0)
        }
    }
    func testCancelledScanCleansPartialIndexAndCanRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("output.raw")
        try Data(repeating: 65, count: 4 * LogQueryProcessor.chunkBytes).write(to: url)
        let worker = try await Task.detached {
            let worker = LogQueryProcessor()
            XCTAssertThrowsError(try worker.update(url, filter: LogFilter(), query: "A", isLive: false) { _, _ in
                // Cancel after the first chunk has produced both text and hits.
                withUnsafeCurrentTask { $0?.cancel() }
            }) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertGreaterThan(worker.bytesReadLastUpdate, 0)
            XCTAssertEqual(worker.retainedOverlapBytes, 0)
            return worker
        }.value
        XCTAssertEqual(try worker.update(url, filter: LogFilter(), query: "A", isLive: false).matchCount, 4 * UInt64(LogQueryProcessor.chunkBytes))
    }
    func testSavedPreferencesRoundTripAndLegacyConfigurationAndLimits() throws {
        var preferences = LogPreferences()
        try preferences.apply(LogFilter(includes: ["WARN", "WARN", "错误"], excludes: ["debug"]))
        XCTAssertEqual(preferences.filter.includes, ["WARN", "错误"])
        try preferences.savePreset(name: "诊断")
        try preferences.apply(LogFilter(excludes: ["INFO"]))
        try preferences.savePreset(name: "诊断")
        XCTAssertEqual(preferences.presets.count, 1)
        XCTAssertTrue(preferences.keywords.contains("错误"))
        var config = Configuration(); config.logPreferences = preferences
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config)).logPreferences, preferences)
        let legacy = Data("{\"projects\":[],\"extraPath\":\"\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(Configuration.self, from: legacy).logPreferences)
        XCTAssertThrowsError(try LogFilter(includes: [String(repeating: "a", count: 1025)]).validated())
        XCTAssertThrowsError(try LogFilter(excludes: ["a\nb"]).validated())
        XCTAssertThrowsError(try LogFilter(includes: (0..<33).map(String.init)).validated())
        try fixture() { url, worker in
            XCTAssertThrowsError(try worker.update(url, filter: LogFilter(), query: String(repeating: "x", count: 4097), isLive: false))
        }
    }
}
