import Foundation

public struct ResponseRewriteTable: Identifiable, Sendable {
    public var path: String
    public var headers: [String]
    public var rows: [[String]]
    public var headerRow: Int
    public var id: String { path }
    public init(path: String, headers: [String], rows: [[String]], headerRow: Int = 0) {
        self.path = path; self.headers = headers; self.rows = rows; self.headerRow = headerRow
    }
}

public enum ResponseRewritePresentation {
    public static let artifactLimit = 4 * 1024 * 1024

    public static func artifact(directory: URL, summary: ResponseRewriteSummary?) throws -> ResponseRewriteArtifact? {
        guard let summary, summary.state == .changed else { return nil }
        guard let identifier = summary.artifactID, UUID(uuidString: identifier) != nil else {
            throw RunbarError.message("改写记录未完整缓存，原始值不可用。")
        }
        let folder = directory.appendingPathComponent("rewrite", isDirectory: true)
        let url = folder.appendingPathComponent(identifier + ".json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw RunbarError.message("改写记录文件缺失，原始值不可用。") }
        let directoryValues = try folder.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true,
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= artifactLimit else {
            throw RunbarError.message("改写记录文件异常或超过 4 MB，原始值不可用。")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: artifactLimit + 1) ?? Data()
        guard data.count <= artifactLimit else { throw RunbarError.message("改写记录超过 4 MB。") }
        let artifact = try JSONDecoder().decode(ResponseRewriteArtifact.self, from: data)
        guard artifact.schemaVersion == 1, artifact.originalBody.count <= ResponseRewriteEngine.bodyLimit,
              artifact.originalHeaders.utf8.count <= 32_768, artifact.ruleName.unicodeScalars.count <= 80,
              artifact.changes.count <= ResponseRewriteEngine.maximumChanges,
              artifact.changes.count == summary.count, Set(artifact.changes.map(\.path)).count == artifact.changes.count,
              summary.ruleID.map({ $0 == artifact.ruleID }) ?? true,
              summary.ruleName.map({ $0 == artifact.ruleName }) ?? true,
              summary.revision.map({ $0 == artifact.revision }) ?? true,
              try JSONEncoder().encode(artifact.changes).count <= ResponseRewriteEngine.bodyLimit else {
            throw RunbarError.message("改写记录校验失败，原始值不可用。")
        }
        let original = try RewriteJSONDocument(artifact.originalBody)
        for change in artifact.changes {
            try Task.checkCancellation()
            let nodes = try original.nodes(at: change.path)
            guard nodes.count == 1, let node = nodes.first, original.raw(node) == change.originalJSON else {
                throw RunbarError.message("改写记录中的原值与原始响应不一致。")
            }
            _ = try RewriteJSONDocument(Data(change.replacementJSON.utf8))
        }
        return artifact
    }

    public static func tables(in data: Data) throws -> [ResponseRewriteTable] {
        let document = try RewriteJSONDocument(data)
        return tableNodes(in: document).map { node in
            ResponseRewriteTable(path: node.path, headers: node.elements[0].elements.map(\.scalar),
                rows: node.elements.dropFirst().map { $0.elements.map(document.raw) })
        }
    }

    private static func tableNodes(in document: RewriteJSONDocument) -> [RewriteJSONDocument.Node] {
        var result: [RewriteJSONDocument.Node] = []
        func visit(_ node: RewriteJSONDocument.Node) {
            guard result.count < 16 else { return }
            if node.kind == .array, let header = node.elements.first, header.kind == .array,
               !header.elements.isEmpty, header.elements.allSatisfy({ $0.kind == .string }),
               Set(header.elements.map(\.scalar)).count == header.elements.count,
               node.elements.dropFirst().allSatisfy({ $0.kind == .array && $0.elements.count == header.elements.count }) {
                result.append(node)
                return
            }
            for key in node.members.keys.sorted() { if let child = node.members[key] { visit(child) } }
            for child in node.elements { visit(child) }
        }
        visit(document.root); return result
    }

    /// row is a zero-based data row; -1 selects the column header and uses its
    /// first data value. Empty tables cannot supply an inferred replacement.
    public static func target(table: ResponseRewriteTable, row: Int, column: Int) -> ResponseRewriteTarget? {
        guard row >= -1, table.headerRow >= 0, table.headers.indices.contains(column),
              Set(table.headers).count == table.headers.count,
              table.rows.allSatisfy({ $0.count == table.headers.count }),
              table.rows.indices.contains(max(0, row)), (try? RewriteJSONDocument.path(table.path)) != nil else { return nil }
        let value = table.rows[max(0, row)][column]
        guard (try? RewriteJSONDocument(Data(value.utf8))) != nil else { return nil }
        var action = ResponseRewriteAction(); action.kind = .table; action.path = table.path
        action.column = table.headers[column]; action.headerRow = table.headerRow; action.valueJSON = value
        return ResponseRewriteTarget(range: NSRange(location: 0, length: 0), action: action,
            path: table.path + "[\(row < 0 ? table.headerRow : row + table.headerRow + 1)][\(column)]")
    }

    private static func targets(document: RewriteJSONDocument, source: RewriteJSONDocument,
                                page: Range<Int>) -> [ResponseRewriteTarget] {
        let tablePaths = Set(tableNodes(in: source).map(\.path))
        typealias Node = RewriteJSONDocument.Node
        var pending: [(range: Range<Int>, action: ResponseRewriteAction, value: Node, path: String, depth: Int)] = []
        func clipped(_ range: Range<Int>) -> Range<Int>? {
            let lower = max(range.lowerBound, page.lowerBound), upper = min(range.upperBound, page.upperBound)
            return lower < upper ? lower..<upper : nil
        }
        func visit(_ node: Node, _ original: Node, depth: Int, rowTable: Node? = nil,
                   column: (table: Node, index: Int, header: Bool)? = nil) {
            let fieldRange = node.keyRange.map { $0.lowerBound..<node.range.upperBound }
            let ranges = [node.keyRange, node.range, fieldRange].compactMap { $0.flatMap(clipped) }
            if !ranges.isEmpty, (try? RewriteJSONDocument.path(original.path)) != nil {
                var action = ResponseRewriteAction(); action.path = original.path
                var value: Node? = original
                if let column {
                    action.kind = .table; action.path = column.table.path
                    action.column = column.table.elements[0].elements[column.index].scalar
                    if column.header { value = column.table.elements.count > 1 ? column.table.elements[1].elements[column.index] : nil }
                }
                if let value {
                    for range in ranges { pending.append((range, action, value, original.path, depth)) }
                }
            }
            for key in node.members.keys.sorted() {
                if let child = node.members[key], let originalChild = original.members[key] { visit(child, originalChild, depth: depth + 1) }
            }
            for (index, child) in node.elements.enumerated() where original.elements.indices.contains(index) {
                if let rowTable {
                    visit(child, original.elements[index], depth: depth + 1,
                          column: (rowTable, index, original === rowTable.elements.first))
                } else {
                    visit(child, original.elements[index], depth: depth + 1,
                          rowTable: tablePaths.contains(original.path) ? original : nil)
                }
            }
        }
        visit(document.root, source.root, depth: 0)
        // A deeply nested document must not copy the whole body once for every
        // ancestor. Prefer small fields and share each node's key/value action.
        var actions: [String: ResponseRewriteAction] = [:], valueBytes = 0
        for item in pending.sorted(by: { $0.value.range.count < $1.value.range.count }) where actions[item.path] == nil {
            guard valueBytes + item.value.range.count <= 2 * ResponseRewriteEngine.bodyLimit else { continue }
            var action = item.action; action.valueJSON = source.raw(item.value)
            actions[item.path] = action; valueBytes += item.value.range.count
        }
        // All boundaries come from a valid UTF-8 document. One page-sized map
        // avoids rescanning a large prefix for every overlapping key/value.
        var offsets = [Int](repeating: 0, count: page.count + 1), byte = page.lowerBound, utf16 = 0
        while byte < page.upperBound {
            let first = document.data[byte]
            let length = first < 0x80 ? 1 : first < 0xe0 ? 2 : first < 0xf0 ? 3 : 4
            byte += length; utf16 += length == 4 ? 2 : 1
            offsets[byte - page.lowerBound] = utf16
        }
        return pending.sorted {
            $0.range.count == $1.range.count ? $0.depth > $1.depth : $0.range.count < $1.range.count
        }.compactMap {
            guard let action = actions[$0.path] else { return nil }
            let lower = offsets[$0.range.lowerBound - page.lowerBound], upper = offsets[$0.range.upperBound - page.lowerBound]
            return ResponseRewriteTarget(range: NSRange(location: lower, length: upper - lower), action: action, path: $0.path)
        }
    }

    /// Index changes once by cell. Token ranges cover nested fields and container
    /// replacements without scanning every change whenever AppKit draws a cell.
    public static func tableChanges(in data: Data, artifact: ResponseRewriteArtifact) throws -> [String: [ResponseRewriteChange]] {
        let client = try RewriteJSONDocument(data), original = try RewriteJSONDocument(artifact.originalBody)
        var changes: [(node: RewriteJSONDocument.Node, change: ResponseRewriteChange)] = []
        for change in artifact.changes {
            try Task.checkCancellation()
            let nodes = try client.nodes(at: change.path), originals = try original.nodes(at: change.path)
            guard nodes.count == 1, originals.count == 1, let node = nodes.first, let old = originals.first,
                  original.raw(old) == change.originalJSON else {
                throw RunbarError.message("改写字段无法在响应中定位，或原值与改写记录不一致。")
            }
            let replacement = try RewriteJSONDocument(Data(change.replacementJSON.utf8))
            guard RewriteJSONDocument.equal(node, replacement.root) else { throw RunbarError.message("改写记录与客户端响应不一致。") }
            changes.append((node, change))
        }
        changes.sort { $0.node.range.lowerBound < $1.node.range.lowerBound }
        for index in changes.indices.dropFirst() where changes[index - 1].node.range.upperBound > changes[index].node.range.lowerBound {
            throw RunbarError.message("改写记录包含重叠字段。")
        }
        let cells = tableNodes(in: client).flatMap { $0.elements.dropFirst().flatMap(\.elements) }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result: [String: [ResponseRewriteChange]] = [:], changeIndex = 0
        var originalNodes: [String: RewriteJSONDocument.Node]?
        for cell in cells {
            try Task.checkCancellation()
            while changeIndex < changes.count, changes[changeIndex].node.range.upperBound <= cell.range.lowerBound { changeIndex += 1 }
            var index = changeIndex
            while index < changes.count, changes[index].node.range.lowerBound < cell.range.upperBound {
                let entry = changes[index]
                if entry.node.range.lowerBound >= cell.range.lowerBound, entry.node.range.upperBound <= cell.range.upperBound {
                    result[cell.path, default: []].append(entry.change)
                } else {
                    // A whole row/table/object was replaced. Only changed cells
                    // are marked, with their exact original token when present.
                    if originalNodes == nil {
                        var byPath: [String: RewriteJSONDocument.Node] = [:]
                        func visit(_ node: RewriteJSONDocument.Node) {
                            byPath[node.path] = node
                            for child in node.elements { visit(child) }
                            for child in node.members.values { visit(child) }
                        }
                        visit(original.root); originalNodes = byPath
                    }
                    if let old = originalNodes?[cell.path] {
                        if !RewriteJSONDocument.equal(old, cell) {
                            result[cell.path, default: []].append(ResponseRewriteChange(path: cell.path,
                                originalJSON: original.raw(old), replacementJSON: client.raw(cell)))
                        }
                    } else {
                        // Newly created cells have no original token; retain the
                        // enclosing change rather than inventing an original null.
                        result[cell.path, default: []].append(entry.change)
                    }
                }
                index += 1
            }
        }
        return result
    }

    static func page(data: Data, artifact: ResponseRewriteArtifact?, version: ResponseRewriteBodyVersion,
                     format: NetworkBodyFormat, page: Int) throws -> NetworkBodyPage {
        if version == .changes {
            let changes = artifact?.changes ?? []
            let text = changes.isEmpty ? "没有实际改变的值。" : changes.map { "\($0.path)\n原始值：\($0.originalJSON)\n修改后：\($0.replacementJSON)" }.joined(separator: "\n\n")
            let display = NetworkBodyFormatter.page(Data(text.utf8), page: page, chunk: 128 * 1024)
            return NetworkBodyPage(text: display.text, page: display.page, pages: display.pages, bytes: data.count)
        }
        let displayData = try NetworkBodyFormatter.format(data, as: format)
        let display = NetworkBodyFormatter.page(displayData, page: page, chunk: 128 * 1024)
        var annotations: [ResponseRewriteAnnotation] = []
        let document = format == .xml ? nil : try? RewriteJSONDocument(displayData, limit: NetworkBodyFormatter.outputLimit)
        let source = displayData == data ? document : try? RewriteJSONDocument(data)
        let rewriteTargets = document.flatMap { document in source.map { targets(document: document, source: $0, page: display.range) } } ?? []
        if version == .client, let artifact, format != .xml {
            guard let document else { throw RunbarError.message("客户端响应不是可定位字段的 JSON。") }
            var ranges: [(Range<Int>, ResponseRewriteChange)] = []
            for change in artifact.changes {
                try Task.checkCancellation()
                let nodes = try document.nodes(at: change.path)
                guard nodes.count == 1, let node = nodes.first else { throw RunbarError.message("改写字段无法在客户端响应中定位。") }
                let replacement = try RewriteJSONDocument(Data(change.replacementJSON.utf8))
                guard RewriteJSONDocument.equal(node, replacement.root) else { throw RunbarError.message("改写记录与客户端响应不一致。") }
                let lower = max(node.range.lowerBound, display.range.lowerBound)
                let upper = min(node.range.upperBound, display.range.upperBound)
                guard lower < upper else { continue }
                ranges.append((lower..<upper, change))
            }
            var byteCursor = display.range.lowerBound, characterCursor = 0
            for (range, change) in ranges.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
                guard range.lowerBound >= byteCursor else { throw RunbarError.message("改写记录包含重叠字段。") }
                characterCursor += String(decoding: displayData[byteCursor..<range.lowerBound], as: UTF8.self).utf16.count
                let length = String(decoding: displayData[range], as: UTF8.self).utf16.count
                annotations.append(ResponseRewriteAnnotation(range: NSRange(location: characterCursor, length: length),
                    path: change.path, originalJSON: change.originalJSON, replacementJSON: change.replacementJSON, ruleName: artifact.ruleName))
                byteCursor = range.upperBound; characterCursor += length
            }
        }
        return NetworkBodyPage(text: display.text, page: display.page, pages: display.pages, bytes: data.count,
                               annotations: annotations, rewriteTargets: rewriteTargets)
    }
}
