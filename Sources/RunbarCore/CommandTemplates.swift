import Foundation

/// Opt-in copies only. Reading this catalogue never changes a saved project or runs a command.
public struct CommandTemplate: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let invocation: String
    public let detail: String
    public func command(useFVM: Bool = true) -> String { (useFVM ? "fvm " : "") + invocation }

    public static let all: [CommandTemplate] = [
        .init(id: "run-macos", name: "运行 macOS", invocation: "flutter run -d macos", detail: "启动 macOS 调试应用。需要 Xcode 与项目的 macOS 平台支持。"),
        .init(id: "run-chrome", name: "运行 Chrome", invocation: "flutter run -d chrome", detail: "启动 Web 调试应用并打开 Chrome。需要安装 Chrome。"),
        .init(id: "pub-get", name: "获取依赖", invocation: "flutter pub get", detail: "下载项目依赖，可能访问网络并更新锁文件和生成的依赖配置。"),
        .init(id: "pub-outdated", name: "检查依赖更新", invocation: "flutter pub outdated", detail: "查询依赖可用版本，可能访问网络；不会自动升级项目依赖。"),
        .init(id: "clean", name: "清理构建缓存", invocation: "flutter clean", detail: "会删除项目 build/ 和 .dart_tool/ 生成目录；下次运行需要重新获取依赖并构建。"),
        .init(id: "analyze", name: "代码检查", invocation: "flutter analyze", detail: "静态分析 Dart 代码并报告问题。"),
        .init(id: "test", name: "运行测试", invocation: "flutter test", detail: "执行项目测试代码。测试可以访问文件或网络，请仅运行可信项目。"),
        .init(id: "format", name: "格式化 Dart 代码", invocation: "dart format .", detail: "会递归修改当前项目中的 Dart 源文件。建议先提交或备份改动；可编辑为 dart format --output=none --set-exit-if-changed . 仅检查。"),
        .init(id: "devices", name: "查看设备", invocation: "flutter devices", detail: "列出可用运行设备及设备 ID。"),
        .init(id: "doctor", name: "环境诊断", invocation: "flutter doctor -v", detail: "检查开发工具链。日志可能包含本机路径和设备信息，分享前请检查。"),
        .init(id: "build-macos", name: "构建 macOS", invocation: "flutter build macos --release", detail: "生成 macOS 发布构建，需要 Xcode 与 macOS 平台支持；分发可能需要签名和公证。不会上传。"),
        .init(id: "build-web", name: "构建 Web", invocation: "flutter build web --release", detail: "生成 build/web 静态文件。不会部署或上传。"),
        .init(id: "build-apk", name: "构建 Android APK", invocation: "flutter build apk --release", detail: "需要 Android SDK/JDK 和 Android 平台支持；正式分发需配置发布签名。不会上传。"),
        .init(id: "build-appbundle", name: "构建 Android App Bundle", invocation: "flutter build appbundle --release", detail: "生成 AAB，需要 Android SDK/JDK；正式分发需配置发布签名。不会上传商店。"),
        .init(id: "build-ios", name: "构建 iOS（不签名）", invocation: "flutter build ios --release --no-codesign", detail: "需要 Xcode、iOS 平台支持及插件所需工具。不执行代码签名；产物不能直接安装到真机或上架。")
    ]
}

extension Project {
    /// Preserves identities/selection on edits and refuses duplicate command text.
    /// Only trim outer whitespace; never rewrite shell quoting or internal whitespace.
    public mutating func savePreset(name: String, command: String, id: UUID? = nil) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else { throw RunbarError.message("名称和命令不能为空。") }
        guard !presets.contains(where: { $0.id != id && $0.command.trimmingCharacters(in: .whitespacesAndNewlines) == command }) else {
            throw RunbarError.message("该项目已保存相同命令，请选择已有配置，或修改后再保存。")
        }
        if let id {
            guard let index = presets.firstIndex(where: { $0.id == id }) else { throw RunbarError.message("原命令已不存在，请重新选择。") }
            presets[index].name = name
            presets[index].command = command
        } else {
            let preset = CommandPreset(name: name, command: command)
            presets.append(preset)
            selectedPresetID = preset.id
        }
    }
}
