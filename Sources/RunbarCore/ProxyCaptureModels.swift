import Foundation

public struct ProxyProjectOptions: Codable, Equatable, Sendable {
    public var enabled = false
    public var decryptTLS = false
    public init(enabled: Bool = false, decryptTLS: Bool = false) {
        self.enabled = enabled; self.decryptTLS = decryptTLS
    }
}

public struct ProxySessionInfo: Codable, Equatable, Sendable {
    public var port: UInt16
    public var decryptTLS: Bool
    public init(port: UInt16, decryptTLS: Bool) { self.port = port; self.decryptTLS = decryptTLS }
    public var address: String { "http://127.0.0.1:\(port)" }
}

public struct ProxyLaunchConfiguration: Sendable {
    public let executable: URL
    public let addon: URL
    public let certificateDirectory: URL
    public let decryptTLS: Bool
    public init(executable: URL, addon: URL, certificateDirectory: URL, decryptTLS: Bool) {
        self.executable = executable; self.addon = addon
        self.certificateDirectory = certificateDirectory; self.decryptTLS = decryptTLS
    }
    public struct BundledEngine: Sendable {
        public let executable: URL
        public let version: String
        public let architecture: String
        public let notices: URL
    }
    private struct BundledManifest: Decodable {
        struct Artifact: Decodable { let executable: String }
        let schemaVersion: Int
        let product: String
        let version: String
        let architectures: [String: Artifact]
    }
    public static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unsupported"
        #endif
    }
    public static func bundledEngine(in bundle: URL = Bundle.main.bundleURL) -> BundledEngine? {
        let architecture = currentArchitecture
        let relative = "Helpers/RunbarProxy-\(architecture).app/Contents/MacOS/mitmdump"
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        guard let bytes = try? Data(contentsOf: contents.appendingPathComponent("Resources/ProxyEngine/manifest.json")),
              bytes.count <= 16_384, let manifest = try? JSONDecoder().decode(BundledManifest.self, from: bytes),
              manifest.schemaVersion == 1, manifest.product == "mitmproxy", manifest.version.utf8.count <= 64,
              !manifest.version.isEmpty, manifest.architectures[architecture]?.executable == relative else { return nil }
        let executable = contents.appendingPathComponent(relative)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return BundledEngine(executable: executable, version: manifest.version, architecture: architecture,
            notices: contents.appendingPathComponent("Resources/ProxyCapture/mitmproxy-LICENSE.txt"))
    }
    public static func findExecutable(preferred: String = "", bundle: URL = Bundle.main.bundleURL) -> URL? {
        if !preferred.isEmpty {
            return FileManager.default.isExecutableFile(atPath: preferred) ? URL(fileURLWithPath: preferred) : nil
        }
        if let bundled = bundledEngine(in: bundle) { return bundled.executable }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/opt/homebrew/bin/mitmdump", "/usr/local/bin/mitmdump",
            "/Applications/mitmproxy.app/Contents/MacOS/mitmdump",
            home.appendingPathComponent(".local/bin/mitmdump").path
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

public struct ProxyCaptureStatus: Codable, Equatable, Sendable {
    public var running = false
    public var events: Int64 = 0
    public var dropped: Int64 = 0
    public var message = "正在启动代理…"
    public var warning: String?
    public var issue: String?
    public var updatedAt = Date()
    public init() {}
    public static func read(directory: URL) -> ProxyCaptureStatus? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")), data.count <= 16_384 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct ProxyHTTPRecord: Decodable {
    let flowID: String
    let method: String
    let url: String
    let startMicros: Int64
    let endMicros: Int64?
    let status: Int?
    let contentType: String
    let requestHeaders: String
    let responseHeaders: String
    let requestBytes: Int64
    let responseBytes: Int64
    let requestBody: Data?
    let responseBody: Data?
    let complete: Bool
    let failure: String?
    let note: String
}

public struct ProxyWebSocketEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case open, send, receive, close
        public var title: String {
            switch self { case .open: return "连接"; case .send: return "发送"; case .receive: return "接收"; case .close: return "关闭" }
        }
    }
    public var id: Int64
    public var flowID: String
    public var url: String
    public var timestamp: Int64
    public var kind: Kind
    public var opcode: Int
    public var bytes: Int64
    public var payload: Data
    public var note: String
    public var closeCode: Int?
    public var requestHeaders: String?
    public var responseHeaders: String?
    public var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1_000_000) }
}

public struct ProxyWebSocketSummary: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let flowID: String
    public let url: String
    public let timestamp: Int64
    public let kind: ProxyWebSocketEvent.Kind
    public let opcode: Int
    public let bytes: Int64
    public let note: String
    public var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1_000_000) }
}

public struct ProxyWebSocketWindow: Sendable {
    public static let capacity = 256
    public var total: Int
    public var offset: Int
    public var rows: [ProxyWebSocketSummary]
    public static let empty = Self(total: 0, offset: 0, rows: [])
    public func row(at index: Int) -> ProxyWebSocketSummary? {
        let relative = index - offset
        return rows.indices.contains(relative) ? rows[relative] : nil
    }
}

struct ProxyWireEvent: Decodable {
    let type: String
    let port: UInt16?
    let record: ProxyHTTPRecord?
    let socket: ProxyWebSocketEvent?
    let message: String?
    let issue: String?
    let dropped: Int64?
}

/// Incremental pipe decoder. Only tagged addon output is trusted as capture data.
/// A complete line is decoded once; rescanning a growing multi-MB prefix is avoided.
struct ProxyWireDecoder {
    static let lineLimit = 4 * 1024 * 1024
    private var buffer = Data()
    private var scanned = 0
    mutating func consume(_ data: Data, receive: (ProxyWireEvent) throws -> Void) throws {
        guard data.count <= 65_536 else { throw RunbarError.message("代理输出分块过大。") }
        buffer.append(data)
        while let newline = buffer[scanned...].firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            guard line.count <= Self.lineLimit else { throw RunbarError.message("代理事件超过 4 MB。") }
            let prefix = Data("RUNBAR_CAPTURE_V1 ".utf8)
            if line.starts(with: prefix) {
                let event = try JSONDecoder().decode(ProxyWireEvent.self, from: Data(line.dropFirst(prefix.count)))
                try receive(event)
            }
            buffer.removeSubrange(...newline); scanned = 0
        }
        scanned = buffer.count
        guard buffer.count <= Self.lineLimit else { throw RunbarError.message("代理事件超过 4 MB。") }
    }
}
