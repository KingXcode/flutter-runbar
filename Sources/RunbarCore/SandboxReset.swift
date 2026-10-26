import Foundation
import AppKit
import Security
import Darwin

public enum SandboxResetError: LocalizedError, Equatable {
    case cancelled
    case unsafe(String)
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "已取消，未移动沙盒。"
        case .unsafe(let reason): return reason
        }
    }
}

/// A verified snapshot. Call reset only after displaying its exact URLs and receiving confirmation.
public struct SandboxResetPlan {
    public let projectPath: String
    public let applicationURL: URL
    public let bundleIdentifier: String
    public let containerURL: URL
    fileprivate let containerIdentity: SandboxFileIdentity
    fileprivate let applicationIdentity: SandboxFileIdentity
    fileprivate let signature: SandboxSignature
}

struct SandboxFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
}

struct SandboxSignature: Equatable {
    let identifier: String
    let sandboxed: Bool
    let codeHash: Data
}

/// Only moves one verified container as a directory. Never traverses its contents, deletes
/// permanently, kills applications, requests elevated access, or modifies system permissions.
public final class SandboxResetService {
    private let home: URL
    private let owner: UInt32
    private let fileManager: FileManager
    private let signature: (URL) throws -> SandboxSignature
    private let isRunning: (String) -> Bool
    private let trash: (URL) throws -> URL?

    public convenience init() {
        self.init(home: URL(fileURLWithPath: NSHomeDirectory()), owner: getuid(),
                  signature: Self.readSignature,
                  isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
                  trash: { url in
                      var destination: NSURL?
                      try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
                      return destination as URL?
                  })
    }

    // Internal injection points let tests use isolated fixtures and a recording trash closure.
    init(home: URL, owner: UInt32 = getuid(), fileManager: FileManager = .default,
         signature: @escaping (URL) throws -> SandboxSignature,
         isRunning: @escaping (String) -> Bool,
         trash: @escaping (URL) throws -> URL?) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
        self.owner = owner; self.fileManager = fileManager
        self.signature = signature; self.isRunning = isRunning; self.trash = trash
    }

    /// Returns all immediate .app products in all build configurations, never selects a flavor.
    /// Nonexistent build products return an empty array. Symlinked product paths fail closed.
    public func discoverApplications(projectPath: String) throws -> [URL] {
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath()
        _ = try directoryIdentity(project)
        var products = project
        for part in ["build", "macos", "Build", "Products"] {
            products.appendPathComponent(part, isDirectory: true)
            guard try existsWithoutFollowingLinks(products) else { return [] }
            _ = try directoryIdentity(products)
        }
        var applications: [URL] = []
        for configuration in try fileManager.contentsOfDirectory(at: products, includingPropertiesForKeys: nil) {
            let attributes = try fileManager.attributesOfItem(atPath: configuration.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            _ = try directoryIdentity(configuration)
            for app in try fileManager.contentsOfDirectory(at: configuration, includingPropertiesForKeys: nil) where app.pathExtension == "app" {
                _ = try directoryIdentity(app)
                applications.append(URL(fileURLWithPath: app.standardizedFileURL.path, isDirectory: true))
            }
        }
        return applications.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public func inspect(projectPath: String, applicationURL: URL) throws -> SandboxResetPlan {
        let app = URL(fileURLWithPath: applicationURL.standardizedFileURL.path, isDirectory: true)
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath()
        let candidates = try discoverApplications(projectPath: project.path)
        guard candidates.contains(where: { $0.standardizedFileURL.path == app.path }) else { throw SandboxResetError.unsafe("所选 App 不是当前项目的直接 macOS 构建产物。请重新构建并选择。") }
        let appIdentity = try directoryIdentity(app)
        _ = try directoryIdentity(app.appendingPathComponent("Contents", isDirectory: true))
        let info = try plist(app.appendingPathComponent("Contents/Info.plist"))
        guard let identifier = info["CFBundleIdentifier"] as? String, Self.validIdentifier(identifier) else {
            throw SandboxResetError.unsafe("App 的 Bundle ID 缺失或不符合安全路径规则。")
        }
        let signed = try signature(app)
        guard signed.identifier == identifier, !signed.codeHash.isEmpty else {
            throw SandboxResetError.unsafe("App 的签名标识与 Info.plist 不一致，无法确认身份。")
        }
        guard signed.sandboxed else { throw SandboxResetError.unsafe("该 App 没有启用 App Sandbox，不能按容器路径清理。") }
        guard !isRunning(identifier) else { throw SandboxResetError.unsafe("该 Bundle ID 的 App 仍在运行。请先退出 App，并停止 IDE／Runbar 的运行任务。") }
        _ = try directoryIdentity(home)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        _ = try directoryIdentity(library)
        let containers = library.appendingPathComponent("Containers", isDirectory: true)
        _ = try directoryIdentity(containers)
        let container = containers.appendingPathComponent(identifier, isDirectory: true)
        let identity = try directoryIdentity(container)
        guard identity.owner == owner else { throw SandboxResetError.unsafe("沙盒容器不属于当前用户，已停止。") }
        let metadata = try plist(container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        guard metadata["MCMMetadataIdentifier"] as? String == identifier else {
            throw SandboxResetError.unsafe("无法核实沙盒元数据归属，已停止；不会猜测或强制删除。")
        }
        return SandboxResetPlan(projectPath: project.path, applicationURL: app,
                                bundleIdentifier: identifier, containerURL: container,
                                containerIdentity: identity, applicationIdentity: appIdentity, signature: signed)
    }

    /// Revalidates the app, signing identity, container identity and stopped state after approval.
    /// The caller must not treat an exception as success; OS protection failures are not bypassed.
    @discardableResult
    public func reset(_ plan: SandboxResetPlan, approved: Bool) throws -> URL? {
        guard approved else { throw SandboxResetError.cancelled }
        let fresh = try inspect(projectPath: plan.projectPath, applicationURL: plan.applicationURL)
        guard fresh.containerURL.path == plan.containerURL.path,
              fresh.bundleIdentifier == plan.bundleIdentifier,
              fresh.containerIdentity == plan.containerIdentity,
              fresh.applicationIdentity == plan.applicationIdentity,
              fresh.signature == plan.signature else {
            throw SandboxResetError.unsafe("确认期间 App 或容器发生变化。未清理，请重新检查并确认。")
        }
        // Last cheap checks immediately before the one OS trash operation. There is no
        // recursive traversal and no fallback to removeItem, shell deletion, or sudo.
        guard !isRunning(plan.bundleIdentifier), try directoryIdentity(plan.containerURL) == plan.containerIdentity else {
            throw SandboxResetError.unsafe("App 已启动或容器发生变化，已停止清理。")
        }
        return try trash(plan.containerURL)
    }

    static func validIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func alphanumeric(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
        }
        guard let first = bytes.first, bytes.count <= 255, alphanumeric(first),
              bytes.allSatisfy({ alphanumeric($0) || $0 == 45 || $0 == 46 }) else { return false }
        return !value.split(separator: ".", omittingEmptySubsequences: false).contains(where: { $0.isEmpty })
    }

    private func existsWithoutFollowingLinks(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw SandboxResetError.unsafe("无法访问目录：\(url.path)。请检查系统授权，不会绕过保护。")
    }

    private func directoryIdentity(_ url: URL) throws -> SandboxFileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw SandboxResetError.unsafe("目录不存在、不可访问或是符号链接：\(url.path)。未清理。")
        }
        return .init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), owner: info.st_uid)
    }

    private func plist(_ url: URL) throws -> [String: Any] {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw SandboxResetError.unsafe("无法安全读取身份文件：\(url.path)。未清理。")
        }
        guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: Any] else {
            throw SandboxResetError.unsafe("身份文件格式不正确：\(url.path)。未清理。")
        }
        return value
    }

    private static func readSignature(_ app: URL) throws -> SandboxSignature {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else {
            throw SandboxResetError.unsafe("无法读取 App 的代码签名。")
        }
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw SandboxResetError.unsafe("App 的代码签名校验失败。请先重新构建。")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let hash = values[kSecCodeInfoUnique as String] as? Data else {
            throw SandboxResetError.unsafe("无法读取最终签名身份及权限。")
        }
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let flag = entitlements?["com.apple.security.app-sandbox"] as? NSNumber
        // Require the actual boolean entitlement rather than a truthy string or arbitrary number.
        let sandboxed = flag.map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        return .init(identifier: identifier, sandboxed: sandboxed, codeHash: hash)
    }
}
