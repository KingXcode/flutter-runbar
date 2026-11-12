import Foundation
import Security
import CryptoKit

/// Public CA data only. No keychain writes, custom anchors, or network fetches.
public struct ProxyCertificate: Equatable, Sendable {
    public static let maximumBytes = 64 * 1024
    public let der: Data
    public let name: String
    public let fingerprint: String
    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else {
            throw RunbarError.message("抓包证书为空或超过 64 KB，无法打开。")
        }
        let certificateData: Data
        if let pem = String(data: data, encoding: .utf8), pem.contains("-----BEGIN") {
            guard !pem.contains("PRIVATE KEY"),
                  pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").count == 2,
                  let begin = pem.range(of: "-----BEGIN CERTIFICATE-----"),
                  let end = pem.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<pem.endIndex),
                  pem[..<begin.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  pem[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let decoded = Data(base64Encoded: String(pem[begin.upperBound..<end.lowerBound]), options: .ignoreUnknownCharacters) else {
                throw RunbarError.message("只可打开单张公开抓包证书，不能包含私钥。")
            }
            certificateData = decoded
        } else { certificateData = data }
        guard Self.isSingleDERObject(certificateData), let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw RunbarError.message("抓包证书无法识别。请检查证书文件，Runbar 不会自动覆盖已有证书。")
        }
        der = SecCertificateCopyData(certificate) as Data
        name = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Runbar 抓包证书"
        fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    private static func isSingleDERObject(_ data: Data) -> Bool {
        guard data.count >= 2, data[data.startIndex] == 0x30 else { return false }
        let first = Int(data[data.startIndex + 1])
        if first < 128 { return data.count == first + 2 }
        let octets = first & 0x7f
        guard octets > 0, octets <= 4, data.count >= octets + 2 else { return false }
        var length = 0
        for index in 0..<octets { length = (length << 8) | Int(data[data.startIndex + index + 2]) }
        return data.count == length + octets + 2
    }
    public static func read(from url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try Self(data: file.read(upToCount: maximumBytes + 1) ?? Data())
    }
    public func makeSSLTrust() throws -> SecTrust {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw RunbarError.message("抓包证书无法识别。")
        }
        var result: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, nil), &result)
        guard status == errSecSuccess, let result else { throw RunbarError.message("无法读取系统证书信任状态（\(status)）。") }
        // Use the real system trust store. Making this CA an explicit anchor
        // here would falsely report trust before the user grants it.
        SecTrustSetNetworkFetchAllowed(result, false)
        return result
    }
}

public struct ProxyCertificateStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable { case missing, needsTrust, trusted, unreadable }
    public var state: State
    public var certificate: ProxyCertificate?
    public var detail: String?
    public static let missing = Self(state: .missing)
    public static func read(from url: URL) -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let certificate = try ProxyCertificate.read(from: url)
            let trust = try certificate.makeSSLTrust()
            var error: CFError?
            let trusted = SecTrustEvaluateWithError(trust, &error)
            return Self(state: trusted ? .trusted : .needsTrust, certificate: certificate,
                        detail: error.map { String($0.localizedDescription.prefix(1024)) })
        } catch { return Self(state: .unreadable, detail: error.localizedDescription) }
    }
}
