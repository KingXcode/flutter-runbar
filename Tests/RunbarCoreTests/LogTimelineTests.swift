import XCTest
@testable import RunbarCore

final class LogTimelineTests: XCTestCase {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, root.appendingPathComponent("output.raw"))
    }
    private func date(_ second: Double) -> Date { Date(timeIntervalSince1970: second) }
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }
    func testReceiveIndexRandomAccessIncrementalGrowthAndMissingMetadata() throws {
        try fixture { root, raw in
            let log = try RunLog(directory: root)
            try log.append(Data("abc".utf8), at: date(1))
            try log.append(Data("defg".utf8), at: date(2))
            let index = LogReceiveTimeIndex(), events = root.appendingPathComponent("events.jsonl")
            try index.update(events)
            XCTAssertEqual(index.count, 2)
            XCTAssertEqual(try index.date(at: 6), date(2))
            XCTAssertEqual(try index.date(at: 0), date(1))
            XCTAssertEqual(try index.date(at: 2), date(1))
            XCTAssertNil(try index.date(at: 7))
            let generation = index.generation
            try log.append(Data("h".utf8), at: date(3))
            try index.update(events)
            XCTAssertEqual(index.generation, generation)
            XCTAssertEqual(try index.date(at: 7), date(3))
            try index.update(events); XCTAssertEqual(index.bytesReadLastUpdate, 0)
            try index.update(root.appendingPathComponent("missing.jsonl"))
            XCTAssertEqual(index.count, 0); XCTAssertNil(try index.date(at: 0))
            XCTAssertNotEqual(index.generation, generation)
            try log.close()
            XCTAssertEqual(try String(contentsOf: raw, encoding: .utf8), "abcdefgh")
        }
    }
    func testTimeFilterUsesFirstReceiveTimeAcrossChunksAndSearchIncludesHiddenLines() throws {
        try fixture { root, raw in
            let log = try RunLog(directory: root)
            try log.append(Data("first\npar".utf8), at: date(1))
            try log.append(Data("tial\n".utf8), at: date(2))
            try log.append(Data("\u{1b}[31m中文🚀\u{1b}[0m\n".utf8), at: date(3)); try log.close()
            let index = LogReceiveTimeIndex(); try index.update(root.appendingPathComponent("events.jsonl"))
            let processor = LogQueryProcessor(), reader = LogTimestampReader()
            let first = try processor.update(raw, filter: LogFilter(from: date(1), through: date(1)), query: "中文", isLive: false, times: index)
            XCTAssertEqual(try String(contentsOf: first.filteredURL, encoding: .utf8), "first\npartial\n")
            XCTAssertEqual(first.matchCount, 1)
            let full = try LogFileReader.read(first.fullURL)
            let fullMarks = try reader.projected(first.fullTimesURL, page: full)
            XCTAssertEqual(LogTimeMark.date(at: 6, in: fullMarks), date(1))
            XCTAssertEqual(LogTimeMark.date(at: 14, in: fullMarks), date(3))
            let filtered = try LogFileReader.read(first.filteredURL)
            XCTAssertEqual(LogTimeMark.date(at: 6, in: try reader.projected(first.filteredTimesURL, page: filtered)), date(1))
            let middle = try processor.update(raw, filter: LogFilter(from: date(2), through: date(2)), query: "", isLive: false, times: index)
            XCTAssertEqual(middle.filteredBytes, 0)
            let last = try processor.update(raw, filter: LogFilter(includes: ["中文"], excludes: ["ignore"], from: date(2), through: date(3)), query: "partial", isLive: false, times: index)
            XCTAssertEqual(try String(contentsOf: last.filteredURL, encoding: .utf8), "中文🚀\n")
            XCTAssertEqual(last.matchCount, 1)
            XCTAssertEqual(LogTimeMark.date(at: 0, in: try reader.projected(last.filteredTimesURL, page: LogFileReader.read(last.filteredURL))), date(3))
        }
    }
    func testRawTimeMarksAreUnicodeCorrectAndLiveAppendsReadOnlyAddedBytes() throws {
        try fixture { root, raw in
            let log = try RunLog(directory: root), index = LogReceiveTimeIndex(), reader = LogTimestampReader()
            var tail = LogTailReader()
            try log.append(Data("first\npar".utf8), at: date(1)); try index.update(root.appendingPathComponent("events.jsonl"))
            var page = try tail.read(raw, isLive: true)
            _ = try reader.raw(raw, page: page, times: index)
            try log.append(Data("tial\n\u{1b}[32m中文🚀\u{1b}[0m\n".utf8), at: date(2)); try index.update(root.appendingPathComponent("events.jsonl"))
            page = try tail.read(raw, isLive: true)
            let marks = try reader.raw(raw, page: page, times: index)
            XCTAssertEqual(LogTimeMark.date(at: 6, in: marks), date(1))
            XCTAssertEqual(LogTimeMark.date(at: 14, in: marks), date(2))
            let firstRead = reader.bytesReadLastRefresh
            try log.append(Data("new\n".utf8), at: date(3)); try index.update(root.appendingPathComponent("events.jsonl"))
            page = try tail.read(raw, isLive: true)
            let added = try reader.raw(raw, page: page, times: index)
            XCTAssertEqual(LogTimeMark.date(at: page.text.utf16.count - 4, in: added), date(3))
            XCTAssertLessThanOrEqual(reader.bytesReadLastRefresh, 4100)
            page = try tail.read(raw, isLive: true); _ = try reader.raw(raw, page: page, times: index)
            XCTAssertEqual(reader.bytesReadLastRefresh, 0)
            XCTAssertGreaterThan(firstRead, 0)
            try log.close()
        }
    }
    func testRawWindowStartingInMiddleOfLineDoesNotInventItsOriginalTime() throws {
        try fixture { root, raw in
            let log = try RunLog(directory: root)
            try log.append(Data("long partial\nnext\n".utf8), at: date(1)); try log.close()
            let index = LogReceiveTimeIndex(); try index.update(root.appendingPathComponent("events.jsonl"))
            let page = try LogFileReader.read(raw, at: .after(5))
            let marks = try LogTimestampReader().raw(raw, page: page, times: index)
            XCTAssertNil(LogTimeMark.date(at: 0, in: marks))
            XCTAssertEqual(LogTimeMark.date(at: "partial\n".utf16.count, in: marks), date(1))
        }
    }
    func testFilteredTimeProjectionRollsBackWithUnfinishedExcludedLine() throws {
        try fixture { root, raw in
            let log = try RunLog(directory: root), index = LogReceiveTimeIndex(), processor = LogQueryProcessor(), reader = LogTimestampReader()
            let filter = LogFilter(excludes: ["hide"])
            try log.append(Data("one\n".utf8), at: date(1)); try log.append(Data("two".utf8), at: date(2))
            try index.update(root.appendingPathComponent("events.jsonl"))
            _ = try processor.update(raw, filter: filter, query: "", isLive: true, times: index)
            try log.append(Data(" hide\n".utf8), at: date(3)); try log.append(Data("three\n".utf8), at: date(4))
            try index.update(root.appendingPathComponent("events.jsonl"))
            let result = try processor.update(raw, filter: filter, query: "", isLive: true, times: index)
            let page = try LogFileReader.read(result.filteredURL)
            XCTAssertEqual(page.text, "one\nthree\n")
            let marks = try reader.projected(result.filteredTimesURL, page: page)
            XCTAssertEqual(LogTimeMark.date(at: 4, in: marks), date(4))
            try log.close()
        }
    }
    func testMissingAndDamagedTimeMetadataRemainUnknownAndCannotPassTimeFilter() throws {
        try fixture { root, raw in
            try Data("hello\n".utf8).write(to: raw)
            let index = LogReceiveTimeIndex(), processor = LogQueryProcessor()
            try index.update(root.appendingPathComponent("events.jsonl"))
            let filtered = try processor.update(raw, filter: LogFilter(from: date(0)), query: "hello", isLive: false, times: index)
            XCTAssertEqual(filtered.filteredBytes, 0); XCTAssertEqual(filtered.matchCount, 1)
            let page = try LogFileReader.read(raw)
            let marks = try LogTimestampReader().raw(raw, page: page, times: index)
            XCTAssertNil(LogTimeMark.date(at: 0, in: marks))
            let events = root.appendingPathComponent("events.jsonl")
            try Data((String(repeating: "x", count: 100_000) + "\n{bad json}\n").utf8).write(to: events)
            try index.update(events); XCTAssertEqual(index.count, 0)
        }
    }
    func testPartialIndexLineIsRetainedUntilCompleteAndTruncationRebuilds() throws {
        try fixture { root, _ in
            let events = root.appendingPathComponent("events.jsonl")
            let line = "{\"sequence\":0,\"offset\":0,\"byteCount\":10,\"receivedAt\":\"1970-01-01T00:00:01Z\"}"
            try Data(line.utf8).write(to: events)
            let index = LogReceiveTimeIndex(); try index.update(events); XCTAssertEqual(index.count, 0)
            try append("\n", to: events); try index.update(events); XCTAssertEqual(index.count, 1)
            XCTAssertEqual(try index.date(at: 9), date(1))
            let generation = index.generation
            try Data().write(to: events); try index.update(events)
            XCTAssertEqual(index.count, 0); XCTAssertNotEqual(index.generation, generation)
        }
    }
    func testTimeFilterAndSavedPresetRoundTripThroughSessionStoreAndLegacyFilter() throws {
        try fixture { root, _ in
            let store = try SessionStore(root: root)
            let filter = LogFilter(includes: ["error"], from: date(100), through: date(200))
            var preferences = LogPreferences(); try preferences.apply(filter); try preferences.savePreset(name: "时间段")
            var config = Configuration(); config.logPreferences = preferences
            try store.saveConfiguration(config)
            XCTAssertEqual(try store.loadConfiguration().logPreferences, preferences)
            let old = try JSONDecoder().decode(LogFilter.self, from: Data("{\"includes\":[\"x\"],\"excludes\":[]}".utf8))
            XCTAssertFalse(old.hasTimeRange)
            XCTAssertThrowsError(try LogFilter(from: date(2), through: date(1)).validated())
            XCTAssertTrue(try filter.validated().contains(date(100)))
            XCTAssertTrue(filter.contains(date(200))); XCTAssertFalse(filter.contains(nil))
        }
    }
    func testSparseTimestampMetadataAndRandomPageStayBoundedForLargeLogs() throws {
        try fixture { root, raw in
            let log = try RunLog(directory: root)
            let data = Data(String(repeating: "same time\n", count: 20_000).utf8)
            for _ in 0..<20 { try log.append(data, at: date(1)) }; try log.close()
            let index = LogReceiveTimeIndex(); try index.update(root.appendingPathComponent("events.jsonl"))
            let processor = LogQueryProcessor()
            let result = try processor.update(raw, filter: LogFilter(includes: ["time"]), query: "", isLive: false, times: index)
            XCTAssertEqual(index.count, 20)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: result.fullTimesURL.path)[.size] as? Int, 16)
            let page = try LogFileReader.read(result.fullURL, at: .fraction(0.5))
            let marks = try LogTimestampReader().projected(result.fullTimesURL, page: page)
            XCTAssertEqual(marks.count, 1); XCTAssertEqual(marks.first?.date, date(1))
        }
    }
}
