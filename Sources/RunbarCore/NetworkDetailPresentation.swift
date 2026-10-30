import Foundation

public enum NetworkDetailSection: String, Codable, CaseIterable, Sendable {
    case overview, headers, request, response
    public var title: String {
        switch self { case .overview: return "概览"; case .headers: return "Headers"; case .request: return "Request"; case .response: return "Response" }
    }
}

public struct NetworkDetailPreferences: Codable, Equatable, Sendable {
    private var formats: [String: NetworkBodyFormat] = [:]
    public var wrapsLines = false
    public init() {}
    public func format(for section: NetworkDetailSection) -> NetworkBodyFormat { formats[section.rawValue] ?? .json }
    public mutating func setFormat(_ format: NetworkBodyFormat, for section: NetworkDetailSection) { formats[section.rawValue] = format }
}

/// Metadata presentation runs on the cache reader, just like body formatting.
/// It never reparses a request/response body or changes captured bytes.
enum NetworkDetailPresentation {
    static func page(record: NetworkRecord, section: NetworkDetailSection, format: NetworkBodyFormat, page: Int) throws -> NetworkBodyPage {
        try Task.checkCancellation()
        let value: [String: Any]
        let raw: String
        if section == .headers {
            func header(_ text: String) -> Any {
                guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { return text }
                return value
            }
            value = ["request": header(record.requestHeaders), "response": header(record.responseHeaders)]
            raw = "Request Headers\n\n\(record.requestHeaders.isEmpty ? "尚无数据" : record.requestHeaders)\n\nResponse Headers\n\n\(record.responseHeaders.isEmpty ? "尚无数据" : record.responseHeaders)"
        } else if section == .request {
            let items = URLComponents(string: record.url)?.queryItems ?? []
            value = ["query": items.map { ["name": $0.name, "value": $0.value.map { $0 as Any } ?? NSNull()] as [String: Any] }]
            raw = URLComponents(string: record.url)?.percentEncodedQuery ?? ""
        } else {
            value = ["method": record.method, "url": record.url, "status": record.status.map { $0 as Any } ?? NSNull(),
                     "failure": record.failure ?? "", "startedAt": record.startDate.ISO8601Format(),
                     "durationMs": record.durationMS.map { $0 as Any } ?? NSNull(), "contentType": record.contentType,
                     "requestBytes": record.requestBytes.map { $0 as Any } ?? NSNull(),
                     "responseBytes": record.responseBytes.map { $0 as Any } ?? NSNull(),
                     "bodyState": record.bodyState.title, "bodyNote": record.bodyNote]
            let duration = record.durationMS.map { String(format: "%.1f ms", $0) } ?? "未知"
            func size(_ bytes: Int64?) -> String { bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知" }
            raw = "\(record.method) \(record.url)\n\n状态：\(record.failure ?? record.status.map(String.init) ?? "Pending")\n时间：\(record.startDate.formatted())\n耗时：\(duration)\n类型：\(record.contentType)\n请求正文大小：\(size(record.requestBytes))\n响应正文大小：\(size(record.responseBytes))\n正文缓存：\(record.bodyState.title) \(record.bodyNote)"
        }
        let data: Data
        switch format {
        case .raw: data = Data(raw.utf8)
        case .json:
            data = try NetworkBodyFormatter.format(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: .json)
        case .xml:
            func element(_ name: String, _ object: Any) -> XMLElement {
                let node = XMLElement(name: name)
                if let dictionary = object as? [String: Any] {
                    for key in dictionary.keys.sorted() {
                        let child = element("entry", dictionary[key]!)
                        child.addAttribute(XMLNode.attribute(withName: "name", stringValue: key) as! XMLNode)
                        node.addChild(child)
                    }
                } else if let array = object as? [Any] {
                    for item in array { node.addChild(element("value", item)) }
                } else if !(object is NSNull) { node.stringValue = String(describing: object) }
                return node
            }
            data = XMLDocument(rootElement: element(section == .headers ? "headers" : "request", value)).xmlData(options: .nodePrettyPrint)
        }
        guard data.count <= NetworkBodyFormatter.outputLimit else { throw RunbarError.message("详情格式化结果超过 4 MB，请使用原始格式。") }
        let result = NetworkBodyFormatter.page(data, page: page, chunk: 128 * 1024)
        return NetworkBodyPage(text: result.text, page: result.page, pages: result.pages, bytes: data.count)
    }
}
