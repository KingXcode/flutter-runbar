import Foundation

public enum FlutterRunMode: String, CaseIterable, Identifiable {
    case debug, profile, release
    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
    public var argument: String { "--" + rawValue }
}

/// Opt-in copies only. Reading this catalogue never changes a saved project or runs a command.
public struct CommandTemplate: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let invocation: String
    public let detail: String
    public var supportsFVM = false
    public var supportsFlutterRunMode: Bool { supportsFVM && invocation.hasPrefix("flutter run ") }
    public func command(useFVM: Bool = true, runMode: FlutterRunMode = .debug) -> String {
        (useFVM && supportsFVM ? "fvm " : "") + invocation + (supportsFlutterRunMode ? " " + runMode.argument : "")
    }
    public func presetName(runMode: FlutterRunMode = .debug) -> String {
        supportsFlutterRunMode ? "\(name)（\(runMode.name)）" : name
    }

    public static let flutter: [CommandTemplate] = [
        CommandTemplate(id: "run-macos", name: "运行 macOS", invocation: "flutter run -d macos", detail: "构建并启动 macOS 应用，可选 Debug、Profile、Release。需要 Xcode 与项目的 macOS 平台支持。"),
        .init(id: "run-chrome", name: "运行 Chrome", invocation: "flutter run -d chrome", detail: "构建并启动 Web 应用，可选 Debug、Profile、Release。需要安装 Chrome。"),
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
    ].map { template in var value = template; value.supportsFVM = true; return value }

    public static func templates(for project: Project) -> [CommandTemplate] {
        func item(_ id: String, _ name: String, _ command: String, _ detail: String) -> CommandTemplate {
            .init(id: id, name: name, invocation: command, detail: detail)
        }
        let root = URL(fileURLWithPath: project.path)
        let files = FileManager.default
        func has(_ name: String) -> Bool { files.fileExists(atPath: root.appendingPathComponent(name).path) }
        switch project.kind {
        case .generic: return []
        case .flutter: return flutter
        case .xcode:
            let names = ((try? files.contentsOfDirectory(atPath: project.path)) ?? []).sorted()
            let containers = names.filter { $0.hasSuffix(".xcworkspace") }
            let projects = names.filter { $0.hasSuffix(".xcodeproj") }
            let selected = containers.count == 1 ? containers.first : containers.isEmpty && projects.count == 1 ? projects.first : nil
            let target = selected.map { " \($0.hasSuffix(".xcworkspace") ? "-workspace" : "-project") \(shellQuote($0))" } ?? ""
            var result = [item("xcode-list", "查看项目与 Scheme", "xcodebuild\(target) -list", selected == nil ? "未找到唯一工程容器，请在保存前补充 -project 或 -workspace 路径；需要完整 Xcode。" : "读取可用 Target、Scheme 和构建配置。需要完整 Xcode；不自动猜测 Scheme。"),
                          item("xcode-destinations", "查看设备与模拟器", "xcrun simctl list devices available", "列出已安装的可用模拟器；需要 Xcode，不安装或启动模拟器。")]
            // Shared scheme files are metadata; never execute xcodebuild during discovery.
            if let container = selected {
                let schemeContainers = container.hasSuffix(".xcworkspace") ? [container] + projects : [container]
                let schemes = Set(schemeContainers.flatMap { name -> [String] in
                    let folder = root.appendingPathComponent(name).appendingPathComponent("xcshareddata/xcschemes")
                    return ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".xcscheme") }
                }).sorted()
                for scheme in schemes {
                    let name = String(scheme.dropLast(".xcscheme".count))
                    result.append(item("xcode-build-\(name)", "构建 \(name)", "xcodebuild\(target) -scheme \(shellQuote(name)) -configuration Debug build", "构建这个共享 Scheme。目的设备、签名与平台依项目配置，可在保存前编辑；不会上传或发布。"))
                }
            }
            return result
        case .android, .gradle:
            let tool = has("gradlew") ? "./gradlew" : "gradle"
            var result = [item("gradle-tasks", "查看可用任务", "\(tool) tasks --all", "列出项目任务。需要 JDK；有 Wrapper 时使用它，否则需要已安装 Gradle。Wrapper 可能下载依赖。"),
                          item("gradle-projects", "查看子项目", "\(tool) projects", "列出 Gradle 子项目；会读取构建脚本，可能访问网络。")]
            if project.kind == .android {
                result += [item("android-debug", "构建 Debug APK", "\(tool) assembleDebug", "需要 Android SDK/JDK。实际任务依模块与 flavor 而异，可先查看任务再编辑；不安装 APK。"),
                           item("android-lint", "Android 代码检查", "\(tool) lint", "执行 Android Lint；需要项目配置的 Android 工具链。")]
            } else {
                result.append(item("gradle-build", "构建项目", "\(tool) build", "执行项目定义的构建任务，可能下载依赖并运行测试。"))
            }
            result += [item("gradle-test", "运行测试", "\(tool) test", "运行项目的 JVM 单元测试，不自动连接设备。"),
                       item("gradle-clean", "清理构建", "\(tool) clean", "删除项目生成的构建产物；下次构建需要重新生成。")]
            return result
        case .swiftPackage:
            return [item("swift-build", "构建 Swift Package", "swift build", "构建当前 Package，可能解析并下载依赖。"),
                    item("swift-release", "构建 Release", "swift build -c release", "生成当前 Package 的 Release 构建，不组装 App 安装包。"),
                    item("swift-test", "运行测试", "swift test", "运行 Package 测试代码；可能访问网络或文件。"),
                    item("swift-resolve", "解析依赖", "swift package resolve", "解析 Package 依赖，可能访问网络并更新 Package.resolved。"),
                    item("swift-clean", "清理构建", "swift package clean", "删除该 Package 的生成构建产物。")]
        case .node:
            let data = (try? Data(contentsOf: root.appendingPathComponent("package.json"))) ?? Data()
            let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let declared = (manifest["packageManager"] as? String)?.split(separator: "@").first.map(String.init)
            let manager = ["npm", "pnpm", "yarn", "bun"].contains(declared ?? "") ? declared! : has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : has("bun.lock") || has("bun.lockb") ? "bun" : "npm"
            var result = [item("node-install", "安装依赖（\(manager)）", "\(manager) install", "下载依赖并可能更新锁文件、执行依赖生命周期脚本。需要已安装 \(manager)。"),
                          item("node-scripts", "查看项目脚本", "\(manager) run", "列出 package.json 中定义的脚本，不自动运行具体脚本。")]
            let scripts = (manifest["scripts"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            result += scripts.keys.sorted().map { name in
                item("node-script-\(name)", "运行 \(name)", "\(manager) run \(shellQuote(name))", "执行项目 scripts 中的 \(name)：\(scripts[name] ?? "")。请检查实际脚本内容及副作用。")
            }
            return result
        case .python:
            var result = [item("python-env", "创建虚拟环境", "python3 -m venv .venv", "在项目内创建 .venv。之后的 Python 命令需使用该环境路径或在命令中显式激活。"),
                          item("python-version", "查看 Python 版本", "python3 --version", "查看 PATH 中的 Python 3 版本，不安装依赖。"),
                          item("python-test", "运行 unittest 测试", "python3 -m unittest discover", "使用当前 Python 执行 unittest 测试；如使用虚拟环境请改为 .venv/bin/python。")]
            if has("requirements.txt") { result.append(item("python-install", "安装 requirements.txt", "python3 -m pip install -r requirements.txt", "下载并安装依赖，建议改为 .venv/bin/python 后再运行，避免修改全局环境。")) }
            if has("uv.lock") { result.append(item("python-uv-sync", "同步 uv 环境", "uv sync", "需要已安装 uv；下载依赖并同步项目虚拟环境。")) }
            return result
        case .rust:
            return [item("rust-check", "检查 Rust 代码", "cargo check", "检查代码与依赖，可能下载依赖并更新 Cargo.lock。"),
                    item("rust-build", "构建 Rust 项目", "cargo build", "生成调试构建，可能下载依赖。"),
                    item("rust-release", "构建 Release", "cargo build --release", "生成优化构建，不自动运行程序或发布。"),
                    item("rust-test", "运行测试", "cargo test", "运行当前 Cargo 项目的测试。"),
                    item("rust-format", "检查代码格式", "cargo fmt --check", "需要 rustfmt，仅检查格式，不修改源文件。")]
        case .go:
            return [item("go-build", "构建 Go 项目", "go build ./...", "构建各个包，可能下载模块依赖。"),
                    item("go-test", "运行测试", "go test ./...", "运行各个包的测试。"),
                    item("go-vet", "检查 Go 代码", "go vet ./...", "检查代码中的可疑结构，可能解析依赖。"),
                    item("go-download", "下载模块依赖", "go mod download", "下载 go.mod 声明的模块依赖。")]
        case .dart:
            return [item("dart-get", "获取 Dart 依赖", "dart pub get", "下载依赖并更新锁文件，需要已安装 Dart SDK。"),
                    item("dart-analyze", "代码检查", "dart analyze", "静态分析 Dart 项目。"),
                    item("dart-test", "运行测试", "dart test", "需要项目已配置 test 依赖。"),
                    item("dart-format", "格式化 Dart 代码", "dart format .", "递归修改项目中的 Dart 源文件。")]
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
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
            guard id != CommandPreset.sandboxReset.id else { throw RunbarError.message("内置操作不能编辑为 shell 命令。") }
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
