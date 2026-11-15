import XCTest
import CSQLite
@testable import RunbarCore

final class ResponseRewriteTests: XCTestCase {
    private func rule(path: String = "$.value", value: String = "true") -> ResponseRewriteRule {
        var rule = ResponseRewriteRule(); rule.name = "模拟清盘中"; rule.urlPattern = "/dfc/stock/rt"; rule.method = "POST"
        rule.actions[0].path = path; rule.actions[0].valueJSON = value
        return rule
    }
    private func preview(_ rule: ResponseRewriteRule, _ body: String, request: String = "{}", url: String = "https://example.test/dfc/stock/rt") throws -> ResponseRewritePreview {
        try ResponseRewriteEngine.preview(rule: rule, method: "POST", url: url,
            requestBody: Data(request.utf8), responseBody: Data(body.utf8))
    }
    func testReplacesOnlySelectedTokenAndPreservesNumberSpelling() throws {
        let before = #"{ "value":false, "other":false, "large":900719925474099312345, "small":1.23000000000000000000000001e-20 }"#
        let result = try preview(rule(), before)
        XCTAssertEqual(result.summary?.state, .changed); XCTAssertEqual(result.summary?.count, 1)
        XCTAssertEqual(String(decoding: result.body, as: UTF8.self), before.replacingOccurrences(of: "\"value\":false", with: "\"value\":true"))
        XCTAssertEqual(result.changes.first?.path, #"$["value"]"#)
        XCTAssertEqual(result.changes.first?.originalJSON, "false")
    }
    func testRequestSubsetUsesTypedExactArraysAndOptionalConditions() throws {
        var value = rule(); value.requestJSON = #"{"blocks":[2000]}"#
        XCTAssertEqual(try preview(value, #"{"value":false}"#, request: #"{"blocks":[2000],"count":40,"fields":["清盘中"]}"#).summary?.count, 1)
        for request in [#"{"blocks":[2000,2001]}"#, #"{"blocks":["2000"]}"#, #"{"blocks":null}"#, "{}"] {
            XCTAssertNil(try preview(value, #"{"value":false}"#, request: request).summary)
        }
        value.requestJSON = ""; var condition = ResponseRewriteRequestCondition(); condition.path = "$.blocks"; condition.operation = .contains; condition.valueJSON = "2000"
        value.requestConditions = [condition]
        XCTAssertEqual(try preview(value, #"{"value":false}"#, request: #"{"blocks":[2000,2001]}"#).summary?.count, 1)
        value.requestConditions[0].valueJSON = "true"
        XCTAssertNil(try preview(value, #"{"value":false}"#, request: #"{"blocks":[1]}"#).summary)
    }
    func testNullIsNotMissingAndNumberEqualityIsExact() throws {
        var value = rule(); value.requestJSON = #"{"field":null}"#
        XCTAssertNil(try preview(value, #"{"value":false}"#).summary)
        XCTAssertEqual(try preview(value, #"{"value":false}"#, request: #"{"field":null}"#).summary?.count, 1)
        XCTAssertEqual(try preview(rule(value: "1.000e0"), #"{"value":1}"#).summary?.state, .unchanged)
        XCTAssertEqual(try preview(rule(value: "900719925474099312346"), #"{"value":900719925474099312345}"#).summary?.state, .changed)
        XCTAssertEqual(try preview(rule(value: "-0.0e4"), #"{"value":0}"#).summary?.state, .unchanged)
    }
    func testQueryParametersRemainStringsAndRepeatedValuesKeepOrder() throws {
        var value = rule(); value.queryJSON = #"{"name":"a b","tag":["one","two"]}"#
        XCTAssertEqual(try preview(value, #"{"value":false}"#, url: "https://example.test/dfc/stock/rt?name=a+b&tag=one&tag=two").summary?.count, 1)
        XCTAssertNil(try preview(value, #"{"value":false}"#, url: "https://example.test/dfc/stock/rt?name=a+b&tag=two&tag=one").summary)
        value.queryJSON = #"{"count":1}"#
        XCTAssertThrowsError(try ResponseRewriteEngine.validate(rule: value))
    }
    func testTableResolvesCurrentHeaderOrderAndDoesNotChangeOtherFalse() throws {
        var value = rule(path: "$.body.symbols")
        value.actions[0].kind = .table; value.actions[0].column = "清盘中"
        let source = #"{"body":{"total_count":5232,"symbols":[["code","清盘中","开盘竞价"],["600000",false,false],["600004",false,false]]}}"#
        let result = try preview(value, source)
        XCTAssertEqual(result.changes.count, 2); XCTAssertEqual(result.changes[0].path, #"$["body"]["symbols"][1][1]"#)
        XCTAssertTrue(String(decoding: result.body, as: UTF8.self).contains(#"["600000",true,false]"#))
        let reordered = #"{"body":{"symbols":[["清盘中","code","开盘竞价"],[false,"600000",false]]}}"#
        XCTAssertEqual(try preview(value, reordered).changes.first?.path, #"$["body"]["symbols"][1][0]"#)
        value.actions[0].rowConditionsJSON = #"{"code":"600000"}"#
        XCTAssertEqual(try preview(value, source).changes.count, 1)
        value.actions[0].rowConditionsJSON = #"{"code":"missing"}"#
        XCTAssertEqual(try preview(value, source).summary?.state, .unchanged)
    }
    func testFortyDataRowsIgnoreHeaderAndServerTotalCount() throws {
        var value = rule(path: "$.body.symbols"); value.actions[0].kind = .table
        let rows = (0..<40).map { "[\"\(600000 + $0)\",false,false]" }.joined(separator: ",")
        let source = "{\"body\":{\"total_count\":5232,\"symbols\":[[\"code\",\"清盘中\",\"开盘竞价\"],\(rows)]}}"
        let result = try preview(value, source)
        XCTAssertEqual(result.summary?.count, 40)
        XCTAssertTrue(String(decoding: result.body, as: UTF8.self).contains("\"total_count\":5232"))
    }
    func testWildcardEscapedKeysAndAtomicFailures() throws {
        let value = rule(path: #"$.items[*]["a.b"]"#)
        XCTAssertEqual(try preview(value, #"{"items":[{"a.b":false},{"a.b":false}]}"#).changes.count, 2)
        XCTAssertEqual(try preview(value, #"{"items":[]}"#).summary?.state, .unchanged)
        let missing = #"{"items":[{"a.b":false},{"different":false}]}"#
        let skipped = try preview(value, missing)
        XCTAssertEqual(skipped.summary?.state, .skipped); XCTAssertEqual(skipped.body, Data(missing.utf8))
        var overlapping = rule(path: "$.items", value: "[]"); var child = ResponseRewriteAction(); child.path = "$.items[0]"; child.valueJSON = "true"; overlapping.actions.append(child)
        XCTAssertEqual(try preview(overlapping, #"{"items":[false]}"#).summary?.state, .skipped)
        XCTAssertEqual(try preview(rule(), #"{"value":false,"value":true}"#).summary?.state, .skipped)
    }
    func testFirstMatchingRuleOwnsFailureAndDisabledSettingsDoNothing() throws {
        var settings = ResponseRewriteSettings(); settings.enabled = true; settings.rules = [rule(path: "$.missing"), rule()]
        let input = Data(#"{"value":false}"#.utf8)
        let result = try ResponseRewriteEngine.preview(settings: settings, method: "POST", url: "https://example.test/dfc/stock/rt", requestBody: nil, responseBody: input)
        XCTAssertEqual(result.summary?.state, .skipped); XCTAssertEqual(result.body, input)
        settings.enabled = false
        XCTAssertNil(try ResponseRewriteEngine.preview(settings: settings, method: "POST", url: "https://example.test/dfc/stock/rt", requestBody: nil, responseBody: input).summary)
    }
    func testLimitsAndNamesRejectInvalidRulesAndOversizedResponses() throws {
        var value = rule(); value.name = " "
        XCTAssertThrowsError(try ResponseRewriteEngine.validate(rule: value))
        value.name = "正常"; value.notes = String(repeating: "中", count: 501)
        XCTAssertThrowsError(try ResponseRewriteEngine.validate(rule: value))
        value.notes = ""; value.urlPattern = "missing-slash"
        XCTAssertThrowsError(try ResponseRewriteEngine.validate(rule: value))
        value.urlMode = .full; value.urlPattern = "file:///tmp/example"
        XCTAssertThrowsError(try ResponseRewriteEngine.validate(rule: value))
        let result = try preview(rule(), String(repeating: " ", count: ResponseRewriteEngine.bodyLimit + 1))
        XCTAssertEqual(result.summary?.state, .skipped)
    }
    func testAnnotationsIdentifyOnlyTargetAndPreserveUTF16Offsets() throws {
        let result = try preview(rule(path: #"$["中文🚀"]"#, value: #""新🚀值""#), #"{"before":"🚀","中文🚀":"旧值","same":"新🚀值"}"#)
        let page = try ResponseRewritePresentation.page(data: result.body, artifact: result.artifact, version: .client, format: .json, page: 0)
        XCTAssertEqual(page.annotations.count, 1)
        let annotation = try XCTUnwrap(page.annotations.first)
        XCTAssertEqual((page.text as NSString).substring(with: annotation.range), #""新🚀值""#)
        XCTAssertEqual(annotation.originalJSON, #""旧值""#)
        XCTAssertEqual(try ResponseRewritePresentation.page(data: result.artifact!.originalBody, artifact: result.artifact, version: .original, format: .json, page: 0).annotations.count, 0)
    }
    func testCrossPageAnnotationsAndTablesPreserveExactTokens() throws {
        let replacement = "\"" + String(repeating: "中🚀", count: 30_000) + "\""
        let result = try preview(rule(value: replacement), #"{"value":"before","n":900719925474099312345}"#)
        let first = try ResponseRewritePresentation.page(data: result.body, artifact: result.artifact, version: .client, format: .raw, page: 0)
        var marked = ""
        for index in 0..<first.pages {
            let page = try ResponseRewritePresentation.page(data: result.body, artifact: result.artifact, version: .client, format: .raw, page: index)
            for range in page.annotations.map(\.range) { marked += (page.text as NSString).substring(with: range) }
        }
        XCTAssertEqual(marked, replacement)
        let tables = try ResponseRewritePresentation.tables(in: Data(#"{"body":{"symbols":[["code","n"],["600000",900719925474099312345]]}}"#.utf8))
        XCTAssertEqual(tables.first?.path, #"$["body"]["symbols"]"#)
        XCTAssertEqual(tables.first?.rows.first?.last, "900719925474099312345")
    }
    func testTableCellIndexIncludesNestedLeavesAndRejectsMismatchedBody() throws {
        let source = #"{"table":[["details","flag"],[{"a":false,"b":false},false]]}"#
        var value = rule(path: "$.table[1][0].a")
        var second = ResponseRewriteAction(); second.path = "$.table[1][0].b"; second.valueJSON = "true"
        value.actions.append(second)
        let result = try preview(value, source), artifact = try XCTUnwrap(result.artifact)
        let changes = try ResponseRewritePresentation.tableChanges(in: result.body, artifact: artifact)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[#"$["table"][1][0]"#]?.map(\.path), [#"$["table"][1][0]["a"]"#, #"$["table"][1][0]["b"]"#])
        XCTAssertThrowsError(try ResponseRewritePresentation.tableChanges(in: Data(source.utf8), artifact: artifact))
        let cell = try preview(rule(path: "$.table[1][1]"), source)
        let cellChanges = try ResponseRewritePresentation.tableChanges(in: cell.body, artifact: XCTUnwrap(cell.artifact))
        XCTAssertEqual(cellChanges[#"$["table"][1][1]"#]?.first?.originalJSON, "false")
    }
    func testTableCellIndexExpandsContainerChangesWithoutMarkingUnchangedCells() throws {
        let source = #"{"table":[["code","value"],["600000",900719925474099312345],["600004",false]]}"#
        for value in [rule(path: "$.table[1]", value: #"["600000",900719925474099312346]"#),
                      rule(path: "$", value: #"{"table":[["code","value"],["600000",900719925474099312346],["600004",false]]}"#)] {
            let result = try preview(value, source)
            let changes = try ResponseRewritePresentation.tableChanges(in: result.body, artifact: XCTUnwrap(result.artifact))
            XCTAssertEqual(changes.count, 1)
            XCTAssertEqual(changes[#"$["table"][1][1]"#]?.first?.originalJSON, "900719925474099312345")
            XCTAssertEqual(changes[#"$["table"][1][1]"#]?.first?.replacementJSON, "900719925474099312346")
        }
    }
    func testQuickTargetsDistinguishRepeatedEscapedKeysAndPreserveExactValues() throws {
        let source = #"{"left":{"same":false},"right":{"same":900719925474099312345},"\u0061.b🚀":"中🚀"}"#
        for format in [NetworkBodyFormat.raw, .json] {
            let page = try ResponseRewritePresentation.page(data: Data(source.utf8), artifact: nil, version: .original, format: format, page: 0)
            let right = page.rewriteTargets.filter { $0.path == #"$["right"]["same"]"# }
            XCTAssertEqual(right.count, 3)
            XCTAssertEqual(Set(right.map { $0.action.valueJSON }), ["900719925474099312345"])
            let rightTexts = Set(right.map { (page.text as NSString).substring(with: $0.range) })
            XCTAssertTrue(rightTexts.contains(#""same""#)); XCTAssertTrue(rightTexts.contains("900719925474099312345"))
            XCTAssertTrue(rightTexts.contains(format == .raw ? #""same":900719925474099312345"# : #""same": 900719925474099312345"#))
            let escaped = page.rewriteTargets.filter { $0.path == #"$["a.b🚀"]"# }
            XCTAssertEqual(escaped.count, 3)
            let escapedTexts = Set(escaped.map { (page.text as NSString).substring(with: $0.range) })
            XCTAssertTrue(escapedTexts.contains(#""\u0061.b🚀""#)); XCTAssertTrue(escapedTexts.contains(#""中🚀""#))
            XCTAssertEqual(escaped.first?.action.valueJSON, #""中🚀""#)
            XCTAssertEqual(right.first?.action, right.last?.action)
        }
    }
    func testQuickTableTargetsSelectWholeColumnAndNestedFieldsRemainJSON() throws {
        let source = #"{"table":[["清盘中","detail"],[false,{"ok":false}],[true,{"ok":true}]]}"#
        let page = try ResponseRewritePresentation.page(data: Data(source.utf8), artifact: nil, version: .client, format: .json, page: 0)
        let header = try XCTUnwrap(page.rewriteTargets.first { $0.path == #"$["table"][0][0]"# })
        let cell = try XCTUnwrap(page.rewriteTargets.first { $0.path == #"$["table"][2][0]"# })
        XCTAssertEqual(header.action.kind, .table); XCTAssertEqual(header.action.valueJSON, "false")
        XCTAssertEqual(cell.action.kind, .table); XCTAssertEqual(cell.action.column, "清盘中")
        XCTAssertEqual(cell.action.path, #"$["table"]"#); XCTAssertEqual(cell.action.valueJSON, "true")
        XCTAssertEqual(cell.action.rowConditionsJSON, "")
        XCTAssertEqual(page.rewriteTargets.first { $0.path == #"$["table"][1][1]["ok"]"# }?.action.kind, .json)
        let table = try XCTUnwrap(ResponseRewritePresentation.tables(in: Data(source.utf8)).first)
        XCTAssertEqual(ResponseRewritePresentation.target(table: table, row: 1, column: 0)?.action.valueJSON, "true")
        XCTAssertEqual(ResponseRewritePresentation.target(table: table, row: -1, column: 0)?.action.valueJSON, "false")
        XCTAssertNil(ResponseRewritePresentation.target(table: table, row: 2, column: 0))
        let duplicate = #"[["same","same"],[false,false]]"#
        let invalidTable = try ResponseRewritePresentation.page(data: Data(duplicate.utf8), artifact: nil, version: .client, format: .raw, page: 0)
        XCTAssertFalse(invalidTable.rewriteTargets.contains { $0.action.kind == .table })
    }
    func testQuickTargetsUseWholeDocumentAcrossUTF16Pages() throws {
        let value = "\"" + String(repeating: "中🚀", count: 30_000) + "\""
        let data = Data(("{\"v\":" + value + ",\"after\":false}").utf8)
        let first = try ResponseRewritePresentation.page(data: data, artifact: nil, version: .client, format: .raw, page: 0)
        var visibleValue = ""
        for index in 0..<first.pages {
            let page = try ResponseRewritePresentation.page(data: data, artifact: nil, version: .client, format: .raw, page: index)
            let target = try XCTUnwrap(page.rewriteTargets.first { $0.path == #"$["v"]"# && $0.range.length > 3 })
            visibleValue += (page.text as NSString).substring(with: target.range)
            XCTAssertEqual(target.action.valueJSON, value)
            XCTAssertTrue(page.rewriteTargets.allSatisfy { $0.range.location >= 0 && NSMaxRange($0.range) <= (page.text as NSString).length })
        }
        XCTAssertEqual(visibleValue, value)
    }
    func testQuickTargetsInvalidJSONAndNonJSONViewsHaveNoTargets() throws {
        for source in [#"{"ok":fal"#, #"{"same":false,"same":true}"#, "plain text"] {
            let page = try ResponseRewritePresentation.page(data: Data(source.utf8), artifact: nil, version: .client, format: .raw, page: 0)
            XCTAssertEqual(page.text, source); XCTAssertTrue(page.rewriteTargets.isEmpty)
        }
        XCTAssertTrue(try ResponseRewritePresentation.page(data: Data("<a>true</a>".utf8), artifact: nil,
            version: .client, format: .xml, page: 0).rewriteTargets.isEmpty)
        XCTAssertTrue(try ResponseRewritePresentation.page(data: Data("{}".utf8), artifact: nil,
            version: .changes, format: .json, page: 0).rewriteTargets.isEmpty)
    }
    func testQuickTargetValueBudgetPrioritizesLeavesAndPathMatchingPreservesWildcards() throws {
        let source = String(repeating: "{\"n\":", count: 25) + "\"" + String(repeating: "x", count: 100_000) + "\"" + String(repeating: "}", count: 25)
        let page = try ResponseRewritePresentation.page(data: Data(source.utf8), artifact: nil, version: .client, format: .raw, page: 0)
        let actions = Dictionary(page.rewriteTargets.map { ($0.path, $0.action) }, uniquingKeysWith: { first, _ in first })
        XCTAssertLessThanOrEqual(actions.values.reduce(0) { $0 + $1.valueJSON.utf8.count }, 2 * ResponseRewriteEngine.bodyLimit)
        XCTAssertNotNil(actions["$" + String(repeating: "[\"n\"]", count: 25)])
        XCTAssertTrue(ResponseRewriteEngine.pathsEqual("$.items[0].ok", #"$["items"][0]["ok"]"#))
        XCTAssertFalse(ResponseRewriteEngine.pathsEqual("$.items[*].ok", "$.items[0].ok"))
        XCTAssertFalse(ResponseRewriteEngine.pathsEqual("$[bad]", "$[bad]"))
        XCTAssertTrue(ResponseRewriteEngine.pathsMatch("$.items[*].ok", #"$["items"][3]["ok"]"#))
        XCTAssertFalse(ResponseRewriteEngine.pathsMatch("$.items[*].ok", "$.items[3].other"))
        XCTAssertFalse(ResponseRewriteEngine.pathsMatch("$.items[*]", "$.items[3].ok"))
        XCTAssertFalse(ResponseRewriteEngine.pathsMatch("$.items[*].ok", "$.items[*].ok"))
        XCTAssertFalse(ResponseRewriteEngine.pathsMatch("$[bad]", "$[bad]"))
    }
    func testStoreSummaryFilterBodyVersionsAndImmutableArtifact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rewrite-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NetworkStore(directory: directory); defer { store.close() }
        let result = try preview(rule(), #"{"value":false,"other":false}"#)
        let artifactID = UUID().uuidString
        var summary = try XCTUnwrap(result.summary); summary.artifactID = artifactID
        var record = NetworkRecord(id: NetworkRecord.identity(epoch: "e", isolate: "i", request: "r"), epoch: "e", isolateID: "i", requestID: "r", method: "POST", url: "https://example.test/dfc/stock/rt", startMicros: 1, endMicros: 2, status: 200, contentType: "application/json", requestBytes: 2, responseBytes: Int64(result.body.count), requestHeaders: "{}", responseHeaders: "{}", failure: nil, timingVersion: 2)
        record.rewrite = summary
        try store.upsert([record]); try store.saveBodies(record.id, request: Data("{}".utf8), response: result.body)
        let folder = directory.appendingPathComponent("rewrite"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(result.artifact!).write(to: folder.appendingPathComponent(artifactID + ".json"))
        let saved = try XCTUnwrap(try store.request(record.id)); var query = NetworkQuery(); query.onlyRewritten = true
        var ordinary = saved; ordinary.rewrite = nil
        XCTAssertFalse(try store.bodyPage(ordinary, response: true, page: 0, format: .raw).rewriteTargets.isEmpty)
        XCTAssertFalse(try store.bodyPage(ordinary, response: true, page: 0, format: .json).rewriteTargets.isEmpty)
        XCTAssertTrue(try store.bodyPage(ordinary, response: false, page: 0, format: .json).rewriteTargets.isEmpty)
        ordinary.bodyNote = "response 正文仅保留部分内容"
        XCTAssertTrue(try store.bodyPage(ordinary, response: true, page: 0, format: .raw).rewriteTargets.isEmpty)
        XCTAssertEqual(try store.listCounts(query: query).matching, 1)
        XCTAssertEqual(try store.listWindow(query: query, around: 0).rows.first?.rewriteCount, 1)
        XCTAssertEqual(try store.summaries(ids: [record.id]).first?.rewriteState, .changed)
        XCTAssertEqual(try store.bodyData(saved, response: true, version: .original), result.artifact!.originalBody)
        let displayed = try store.bodyPage(saved, response: true, page: 0, format: .json)
        XCTAssertEqual(displayed.annotations.first?.ruleName, "模拟清盘中")
        let reader = NetworkCacheReader(); let indexed = try await reader.listWindow(directory: directory, query: query, around: 0)
        XCTAssertEqual(indexed.matching, 1)
        query.search = "true"
        let searched = try await reader.listWindow(directory: directory, query: query, around: 0)
        XCTAssertEqual(searched.matching, 1)
        var revertedRecord = saved; revertedRecord.rewrite = ResponseRewriteSummary(state: .unchanged)
        try store.upsert([revertedRecord])
        let removed = try await reader.listWindow(directory: directory, query: query, around: 0)
        XCTAssertEqual(removed.matching, 0)
        try store.upsert([saved])
        try Data(#"{"value":123,"other":false}"#.utf8).write(to: directory.appendingPathComponent("bodies/\(record.id).response"))
        let inconsistent = try store.bodyPage(saved, response: true, page: 0, format: .json)
        XCTAssertTrue(inconsistent.annotations.isEmpty); XCTAssertNotNil(inconsistent.rewriteNote); XCTAssertTrue(inconsistent.text.contains("123"))
        try result.body.write(to: directory.appendingPathComponent("bodies/\(record.id).response"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent(artifactID + ".json"))
        XCTAssertThrowsError(try store.bodyData(saved, response: true, version: .original))
        XCTAssertNotNil(try store.bodyPage(saved, response: true, page: 0).rewriteNote)
        XCTAssertTrue(try store.bodyPage(saved, response: true, page: 0).text.contains("true"))
    }
    func testOldReadonlyCacheHasNoRewriteColumnsAndDoesNotMigrate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rewrite-legacy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NetworkStore(directory: directory); store.close()
        let url = directory.appendingPathComponent("requests.sqlite"); var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP INDEX requests_rewrite; ALTER TABLE requests DROP COLUMN rewrite_state; ALTER TABLE requests DROP COLUMN rewrite_count;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: url)
        let readonly = try NetworkStore(directory: directory, readOnly: true); defer { readonly.close() }
        var query = NetworkQuery(); query.onlyRewritten = true
        XCTAssertEqual(try readonly.listCounts(query: query).matching, 0)
        XCTAssertEqual(try readonly.listWindow(around: 0).rows.count, 0)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testSavedFilterRoundTripsOnlyRewritten() throws {
        var query = NetworkQuery(); query.onlyRewritten = true
        XCTAssertFalse(query.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(NetworkQuery.self, from: JSONEncoder().encode(query)).onlyRewritten)
        XCTAssertFalse(try JSONDecoder().decode(NetworkQuery.self, from: Data("{}".utf8)).onlyRewritten)
    }
    func testArtifactRejectsTraversalMismatchedSnapshotAndSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rewrite-artifact-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("rewrite"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = try preview(rule(), #"{"value":false}"#)
        var summary = result.summary!; summary.artifactID = "../outside"
        XCTAssertThrowsError(try ResponseRewritePresentation.artifact(directory: directory, summary: summary))
        let identifier = UUID().uuidString; summary.artifactID = identifier
        let file = folder.appendingPathComponent(identifier + ".json")
        try JSONEncoder().encode(result.artifact!).write(to: file)
        XCTAssertNotNil(try ResponseRewritePresentation.artifact(directory: directory, summary: summary))
        summary.ruleName = "另外的规则"
        XCTAssertThrowsError(try ResponseRewritePresentation.artifact(directory: directory, summary: summary))
        summary.ruleName = result.summary?.ruleName
        let other = directory.appendingPathComponent("other.json"); try FileManager.default.moveItem(at: file, to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertThrowsError(try ResponseRewritePresentation.artifact(directory: directory, summary: summary))
    }
}
