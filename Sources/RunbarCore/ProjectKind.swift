import Foundation

public enum ProjectKind: String, Codable, CaseIterable, Identifiable {
    case generic, flutter, xcode, android, swiftPackage, node, python, rust, go, dart, gradle
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .generic: return "通用 / 自定义"
        case .flutter: return "Flutter"
        case .xcode: return "Xcode"
        case .android: return "Android"
        case .swiftPackage: return "Swift Package"
        case .node: return "Node.js / Web"
        case .python: return "Python"
        case .rust: return "Rust"
        case .go: return "Go"
        case .dart: return "Dart"
        case .gradle: return "Gradle / JVM"
        }
    }
}

/// Read project markers only. Detection never invokes build tools or executes project code.
public enum ProjectDetector {
    public static func detect(at path: String) -> ProjectKind {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let files = FileManager.default
        let names = (try? files.contentsOfDirectory(atPath: path)) ?? []
        func has(_ name: String) -> Bool { files.fileExists(atPath: root.appendingPathComponent(name).path) }
        func text(_ name: String) -> String { (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        if has("pubspec.yaml"), text("pubspec.yaml").range(of: #"(?m)^\s*sdk:\s*['"]?flutter['"]?\s*(?:#.*)?$"#, options: .regularExpression) != nil {
            return .flutter
        }
        if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { return .xcode }
        let gradleFiles = ["build.gradle", "build.gradle.kts", "app/build.gradle", "app/build.gradle.kts"]
        if has("app/src/main/AndroidManifest.xml") || has("src/main/AndroidManifest.xml") || gradleFiles.contains(where: { text($0).contains("com.android.") }) {
            return .android
        }
        if has("Package.swift") { return .swiftPackage }
        if has("package.json") { return .node }
        if has("pyproject.toml") || has("requirements.txt") || has("setup.py") || has("Pipfile") { return .python }
        if has("Cargo.toml") { return .rust }
        if has("go.mod") { return .go }
        if has("pubspec.yaml") { return .dart }
        if has("settings.gradle") || has("settings.gradle.kts") || has("build.gradle") || has("build.gradle.kts") { return .gradle }
        return .generic
    }
}
