import Foundation
import Darwin
import UniformTypeIdentifiers

struct NetworkResponseFile: Codable, Equatable, Sendable {
    static let maximumBytes = 64 * 1024 * 1024
    let id: String
    let bytes: Int

    var isValid: Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && (1...Self.maximumBytes).contains(bytes)
    }

    func url(in directory: URL) throws -> URL {
        guard isValid else { throw RunbarError.message("文件缓存记录无效。") }
        let url = directory.resolvingSymlinksInPath().appendingPathComponent("files/\(id).body")
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL else {
            throw RunbarError.message("文件缓存路径无效。")
        }
        return url
    }
}

public struct NetworkResponseExport: Sendable {
    enum Source: Sendable { case body(Data), file(URL, bytes: Int) }
    public let filename: String
    let source: Source

    static func filename(url: String, disposition: String?, contentType: String) -> String {
        let url = URL(string: url)
        let proposed = url.flatMap { url in
            disposition.flatMap { HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Disposition": $0])?.suggestedFilename }
        }
        let clean = (proposed ?? url?.lastPathComponent ?? "")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)).last ?? ""
        let name = clean.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "." })
        let ext = (String(name) as NSString).pathExtension
        let mime = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let typeExtension = UTType(mimeType: mime)?.preferredFilenameExtension ?? "bin"
        let useExtension = ext.isEmpty || ext.utf8.count > 20 ? typeExtension : ext
        let stem = ext.isEmpty ? String(name) : (String(name) as NSString).deletingPathExtension
        let shortened = String(decoding: stem.utf8.prefix(180), as: UTF8.self)
        return (shortened.isEmpty ? "response" : shortened) + "." + useExtension
    }

    public static func suggestedFilename(for record: NetworkRecord) -> String {
        filename(url: record.url, disposition: headers(record.responseHeaders)["content-disposition"],
                 contentType: record.contentType)
    }

    private static func headers(_ text: String) -> [String: String] {
        guard let fields = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in fields {
            result[key.lowercased()] = value as? String ?? (value as? [String])?.first
        }
        return result
    }

    static func prepare(record: NetworkRecord, directory: URL, version: ResponseRewriteBodyVersion,
                        readBody: () throws -> Data) throws -> Self {
        guard version != .changes, record.isComplete, record.failure == nil, record.method.uppercased() != "HEAD",
              let status = record.status, status >= 200, ![204, 205, 206, 304].contains(status) else {
            throw RunbarError.message("此请求没有完整的响应文件可导出。")
        }
        let headers = headers(record.responseHeaders)
        guard headers["content-range"] == nil else { throw RunbarError.message("只抓到了文件的部分区间，无法导出完整文件。") }
        let source: Source
        if let file = record.responseFile, version == .client || record.rewrite?.state != .changed {
            let url = try file.url(in: directory)
            let handle = try openFile(url, bytes: file.bytes)
            try handle.close()
            source = .file(url, bytes: file.bytes)
        } else {
            let encoding = (headers["content-encoding"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let responseNotes = record.bodyNote.split(separator: ";").filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("response ")
            }
            guard ["", "identity", "gzip", "deflate"].contains(encoding), responseNotes.isEmpty else {
                throw RunbarError.message("此记录的响应正文不完整或无法解压，无法导出。请重新抓取完整响应。")
            }
            let data = try readBody()
            let originalWasRewritten = version == .original && record.rewrite?.state == .changed
            if !originalWasRewritten, encoding.isEmpty || encoding == "identity",
               let bytes = record.responseBytes, bytes > Int64(data.count) {
                throw RunbarError.message("此记录只缓存了部分响应正文，无法导出。请重新抓取完整响应。")
            }
            guard !data.isEmpty else { throw RunbarError.message("响应正文为空，没有文件可导出。") }
            source = .body(data)
        }
        return Self(filename: filename(url: record.url, disposition: headers["content-disposition"],
                                      contentType: record.contentType), source: source)
    }

    /// Writes to a sibling temporary file first. A failed export leaves the
    /// destination untouched, including a file the user chose to replace.
    public func write(to destination: URL) throws {
        switch source {
        case .body(let data):
            try data.write(to: destination, options: .atomic)
        case .file(let url, let bytes):
            let input = try Self.openFile(url, bytes: bytes)
            defer { try? input.close() }
            let fm = FileManager.default
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".runbar-export-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            let temp = staging.appendingPathComponent("response")
            try Data().write(to: temp)
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            var remaining = bytes
            while remaining > 0 {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: min(remaining, 256 * 1024)), !data.isEmpty else {
                    throw RunbarError.message("文件缓存不完整，导出已取消。")
                }
                try output.write(contentsOf: data)
                remaining -= data.count
            }
            try output.close()
            guard rename(temp.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func openFile(_ url: URL, bytes: Int) throws -> FileHandle {
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL else {
            throw RunbarError.message("文件缓存路径无效。")
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RunbarError.message("该响应文件的缓存已不存在。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == bytes else {
            try? handle.close()
            throw RunbarError.message("响应文件缓存大小不匹配，无法导出。")
        }
        return handle
    }
}
