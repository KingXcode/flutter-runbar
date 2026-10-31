import Foundation

public struct AppReleaseVersion: Equatable, Comparable, Sendable {
    public let version: String
    public let build: Int
    private let components: [Int]
    public init(version: String, build: Int) throws {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts.compactMap({ Int($0) }).count == 3, build >= 0 else {
            throw RunbarError.message("更新版本号格式不受支持。")
        }
        self.version = version; self.build = build; components = parts.compactMap { Int($0) }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.components != rhs.components { return lhs.components.lexicographicallyPrecedes(rhs.components) }
        return lhs.build < rhs.build
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.components == rhs.components && lhs.build == rhs.build }
}

public struct AppUpdateRelease: Equatable, Sendable {
    public struct Asset: Equatable, Sendable {
        public let name: String
        public let url: URL
        public let bytes: Int64
    }
    public let tag: String
    public let version: String
    public let build: Int
    public let notes: String
    public let page: URL
    public let assets: [Asset]
    public func isNewer(than current: AppReleaseVersion) -> Bool {
        guard let candidate = try? AppReleaseVersion(version: version, build: build) else { return false }
        return candidate > current
    }
    public static let repository = "KingXcode/flutter-runbar"
    public static let releasesPage = URL(string: "https://github.com/KingXcode/flutter-runbar/releases")!
    public static let latestAPI = URL(string: "https://api.github.com/repos/KingXcode/flutter-runbar/releases/latest")!
    public static let responseLimit = 512 * 1024

    public static func parse(_ data: Data) throws -> Self {
        struct Payload: Decodable {
            struct File: Decodable { let name: String; let browser_download_url: String; let size: Int64 }
            let tag_name: String; let body: String?; let html_url: String
            let draft: Bool; let prerelease: Bool; let assets: [File]
        }
        guard data.count <= responseLimit else { throw RunbarError.message("GitHub 更新信息过大，请打开发布页查看。") }
        let value = try JSONDecoder().decode(Payload.self, from: data)
        let parts = value.tag_name.dropFirst().split(separator: "+", omittingEmptySubsequences: false)
        guard value.tag_name.hasPrefix("v"), parts.count == 2, let build = Int(parts[1]),
              !value.draft, !value.prerelease, value.assets.count <= 100,
              let page = URL(string: value.html_url), validURL(page, prefix: "/\(repository)/releases/tag/") else {
            throw RunbarError.message("GitHub 发布信息格式不受支持，请打开发布页查看。")
        }
        let version = try AppReleaseVersion(version: String(parts[0]), build: build)
        guard page.path == "/\(repository)/releases/tag/\(value.tag_name)" else { throw RunbarError.message("更新发布页不属于 Runbar。") }
        let assets = value.assets.compactMap { file -> Asset? in
            guard file.name.utf8.count <= 200, file.size > 0, file.size <= 1024 * 1024 * 1024,
                  !file.name.contains("/"), !file.name.contains("\\"),
                  let url = URL(string: file.browser_download_url),
                  validURL(url, prefix: "/\(repository)/releases/download/\(value.tag_name)/"),
                  url.path == "/\(repository)/releases/download/\(value.tag_name)/\(file.name)" else { return nil }
            return Asset(name: file.name, url: url, bytes: file.size)
        }
        let notes = (value.body ?? "本次发布未提供更新说明，请查看 GitHub 发布页。")
            .replacingOccurrences(of: "<!-- runbar-notes-sha256:[a-f0-9]{64} -->", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(tag: value.tag_name, version: version.version, build: version.build,
                    notes: String(notes.prefix(60_000)), page: page, assets: assets)
    }
    private static func validURL(_ url: URL, prefix: String) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com" && (url.port == nil || url.port == 443) &&
            url.user == nil && url.password == nil && url.query == nil && url.fragment == nil && url.path.hasPrefix(prefix)
    }
    public func compatibleAsset(architecture: String, operatingSystem: OperatingSystemVersion) -> Asset? {
        let escaped = NSRegularExpression.escapedPattern(for: "Runbar-\(version)-\(build)-macOS")
        let pattern = "^\(escaped)([0-9]+(?:\\.[0-9]+){0,2})-(universal|arm64|x86_64)(?:-(signed|adhoc))?\\.(dmg|zip)$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let candidates = assets.compactMap { asset -> (Asset, Int)? in
            guard let match = regex.firstMatch(in: asset.name, range: NSRange(asset.name.startIndex..., in: asset.name)),
                  let osRange = Range(match.range(at: 1), in: asset.name), let archRange = Range(match.range(at: 2), in: asset.name) else { return nil }
            let osParts = asset.name[osRange].split(separator: ".")
            let os = osParts.compactMap { Int($0) }
            guard os.count == osParts.count else { return nil }
            let minimum = os + Array(repeating: 0, count: max(0, 3 - os.count))
            let current = [operatingSystem.majorVersion, operatingSystem.minorVersion, operatingSystem.patchVersion]
            let arch = String(asset.name[archRange])
            guard !current.lexicographicallyPrecedes(minimum), arch == "universal" || arch == architecture,
                  Self.validURL(asset.url, prefix: "/\(Self.repository)/releases/download/\(tag)/") else { return nil }
            return (asset, (asset.name.hasSuffix(".dmg") ? 20 : 0) + (asset.name.contains("-signed.") ? 10 : 0) + (arch == "universal" ? 1 : 0))
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }
}

public enum AppUpdateSchedule {
    public static func shouldCheck(lastAutomaticAttempt: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastAutomaticAttempt else { return true }
        return !calendar.isDate(lastAutomaticAttempt, inSameDayAs: now)
    }
}

public enum GitHubAppUpdates {
    public static func latest() async throws -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: AppUpdateRelease.latestAPI)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Runbar-Update-Check", forHTTPHeaderField: "User-Agent")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw RunbarError.message("GitHub 未返回有效更新信息。") }
        if response.statusCode == 404 { return nil }
        if response.statusCode == 403 || response.statusCode == 429 { throw RunbarError.message("GitHub 暂时限制检查频率，请稍后手动重试或打开发布页。") }
        guard response.statusCode == 200 else { throw RunbarError.message("检查更新失败（HTTP \(response.statusCode)），请稍后手动重试。") }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < AppUpdateRelease.responseLimit else { throw RunbarError.message("GitHub 更新信息过大，请打开发布页查看。") }
            data.append(byte)
        }
        return data
    }
}
