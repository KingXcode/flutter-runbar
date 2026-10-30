import Foundation

public enum ApplicationSourceDirectory {
    /// Suggestions use explicit bundle containment, never an app/display-name guess.
    public static func suggestion(bundlePath: String, projects: [Project]) -> String? {
        let bundle = URL(fileURLWithPath: bundlePath).standardizedFileURL.resolvingSymlinksInPath().path
        let paths = Set(projects.filter { $0.kind == .flutter }.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path
        }).filter { $0 != "/" && bundle.hasPrefix($0 + "/") }
        return paths.max { $0.count < $1.count }
    }

    /// Read only a bounded manifest. Never execute code from the selected folder.
    public static func validate(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 8192 else {
            throw RunbarError.message("请选择本机 Flutter 源码项目目录。")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: root.path) else {
            throw RunbarError.message("源码目录不存在或无法读取，请重新选择。")
        }
        let manifest = root.appendingPathComponent("pubspec.yaml").resolvingSymlinksInPath()
        guard let attributes = try? manifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 256 * 1024,
              let handle = try? FileHandle(forReadingFrom: manifest) else {
            throw RunbarError.message("所选目录没有可读取的 pubspec.yaml，请选择对应 Flutter 项目的根目录。")
        }
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 256 * 1024 + 1) ?? Data()
        guard bytes.count <= 256 * 1024, let text = String(data: bytes, encoding: .utf8),
              text.range(of: #"(?m)^\s*sdk:\s*['"]?flutter['"]?\s*(?:#.*)?$"#, options: .regularExpression) != nil else {
            throw RunbarError.message("所选目录不是可识别的 Flutter 项目，请选择包含 flutter SDK 依赖的源码根目录。")
        }
        return root.path
    }
}
