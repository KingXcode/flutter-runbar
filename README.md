# Flutter Runbar

macOS 26+ 的原生 SwiftUI 菜单栏 Flutter 开发辅助工具。独立新项目，不依赖或修改其他应用。

## 第一版功能

- 选择并保存多个项目目录，添加、编辑每个项目的命令预设。
- 默认命令：`fvm flutter run -d macos`。
- 在项目目录中执行你明确保存的命令；同一时刻只允许运行一条。
- 菜单栏快速运行、停止、打开管理窗口。
- 保存每次运行的命令快照、开始/结束时间、持续时间、状态、退出码。
- 连续读取合并的 stdout/stderr，保存全部原始字节及有顺序号的接收时间索引。
- 实时日志窗口、历史日志、本地日志目录入口。显示窗口有内存上限，磁盘日志不截断。
- 增量处理 UTF-8 / ANSI / 分块 URL，识别实际的本机 DevTools 地址，而不是把 Dart VM Service 地址当成 DevTools。
- DevTools 由你点击打开或复制，不自动打开；历史运行的打开按钮禁用。
- 停止采用独立进程组 SIGINT → 3 秒后 SIGTERM → 6 秒后 SIGKILL，不使用 killall。
- 退出时若仍有命令运行，明确询问并等待停止和日志保存；异常退出留下的记录标为中断，不追杀历史 PID。

## 运行环境

- macOS 26 或更新版本。
- Xcode 26（Swift 6.2）或更新版本。项目使用 Swift 5 语言模式，以明确控制渐进迁移；UI 使用 SwiftUI，日志显示与目录选择采用 AppKit 桥接。
- 已安装 Flutter / FVM 与运行 Flutter macOS 项目需要的开发工具。
- 不需要第三方 Swift 包、API 密钥、Apple Developer 证书或在线服务。

## 构建

用 Xcode 打开 `FlutterRunbar.xcodeproj`，选择 **FlutterRunbar** Scheme 和 **My Mac**：

- `⌘R`：编译并运行应用，入口在系统菜单栏。
- `⌘U`：运行 `RunbarCoreTests` 单元测试。
- `Product > Archive`：使用 Release 配置归档，在 Organizer 查看归档和导出选项。
- 版本号和构建号在应用 Target 的 General 中修改；证书与开发团队在 Signing & Capabilities 中配置。

工程默认使用本机 ad hoc 签名，无需开发者账号。正式分发时需设置自己的 Team、Developer ID 签名与公证。应用需要执行用户命令和访问项目目录，因此未启用 App Sandbox。

命令行测试、打包：

```sh
swift test
bash scripts/test-process.sh
bash scripts/build-app.sh
open 'dist/Flutter Runbar.app'
```

构建脚本生成可放进 Applications 的 `.app`，仅使用本机 ad hoc 签名，不是 Developer ID 签名，未公证。跨机器分发可能遇到 Gatekeeper；不要关闭系统安全功能。正式分发需单独配置合法签名与公证。当前构建只生成所在机器架构的应用。

`FlutterRunbar.xcodeproj`、共享 Scheme 和 `Resources/Info.plist` 已保存在仓库中，正常使用 Xcode 不需要安装额外工具。`Package.swift` 管理共享的 `RunbarCore` / `RunbarProcess` 模块，应用 Target 和测试 Target 使用同一份源码。`project.yml` 是 XcodeGen 工程生成配置；需要重新生成时使用 XcodeGen 2.46+ 执行 `xcodegen generate`。如果直接在 Xcode 修改工程设置，应同步修改 `project.yml`，避免重新生成时覆盖设置。

### Xcode 控制台系统日志

共享 Scheme 的 `Run > Arguments > Environment Variables` 默认启用 `OS_ACTIVITY_MODE=disable` 与 `IDELogRedirectionPolicy=oslogToStdio`，用于减少 macOS App Intents / `com.apple.linkd.autoShortcut` 等系统服务日志。它会抑制调试进程的统一系统日志，不是只过滤某一个错误；需要排查系统框架时取消勾选这两个变量即可恢复。普通 stdout/stderr 和应用保存的命令原始日志仍正常工作。测试和 Profile 使用默认日志模式，Release 归档不会写入这些运行环境变量。系统服务连接问题本身不由这项设置修复。

日志模式说明参考 [WebKit 官方调试文档](https://webkit.org/debugging-webkit/#logging)。

## 使用

1. 从菜单栏打开管理窗口，点击「添加项目」。项目目录可包含空格或中文。
2. 选择或编辑命令。支持 zsh 引号、管道与环境变量赋值，例如 `fvm flutter run -d macos`。
3. 点击「运行」。查看运行输出和开始时间。DevTools 出现后点击「打开」或「复制」。
4. 点击「停止」。界面等待最多约 6 秒的正常升级阶段，并继续排空输出，再保存最终退出结果。
5. 点击左侧运行记录可选中高亮并查看输出，再次点击同一条取消选中，右侧恢复默认空白。取消查看不停止命令；任务结束也不会改变当前选中状态。选中记录后点击「本地日志」查看全部文件。

命令由 `/bin/zsh -l -c` 执行，工作目录通过进程 API 设置，不拼接 `cd`。每次运行会在自定义 PATH 后补充 `~/.pub-cache/bin`、`~/fvm/bin`、`/opt/homebrew/bin`、`/usr/local/bin`，已有配置也会生效；自定义路径中的 `~/` 会展开为用户主目录。可在「PATH 设置」添加其他 SDK 或 FVM 实际所在目录，自定义路径优先。登录 zsh 会读取你自己的登录配置；本应用不安装 SDK、不修改 shell 文件。PATH 只影响新运行。

只保存你信任的命令。它拥有当前用户的系统权限，应用没有启用 App Sandbox。输出或日志内容永远不会被执行。stdin 接到 `/dev/null`，当前版本没有交互式终端、Flutter 热重载键盘输入或 PTY；需要交互的操作请使用终端。不要配置 `&`、`nohup`、`setsid` 或其他后台化 / 脱离进程组的命令：主动脱离进程组的进程不能由本应用可靠管理。

## 日志格式与隐私

数据保存在：

```text
~/Library/Application Support/FlutterRunbar/
  configuration.json
  sessions/<UUID>/
    session.json
    output.raw
    events.jsonl
```

- `output.raw`：stdout/stderr 合并管道收到的原始字节，保留 ANSI、无换行片段以及非 UTF-8 数据。
- `events.jsonl`：每次读取分块的 UTC 接收时间、顺序号、原始文件字节偏移及长度。不是进程自身打印时间，也不伪称可以还原两个流在源头的精确时间或来源标签。每次分块同步落盘。
- `session.json`：运行信息，最多保存最先识别的 32 个不同 DevTools 地址；完整 URL 仍在原始日志中。
- 实时视图保留有限尾部；历史视图最多读取末尾 200 KB。完整日志始终在磁盘，直到用户自行管理文件。MVP 没有自动清理，会持续占用磁盘。
- 磁盘写入、同步或读取失败会显式报错，并停止命令；不把不完整日志宣称为成功。异常中断无法准确知道结束时间，因此保留为空。
- 损坏的单条历史记录保留原文件、跳过并提醒；损坏配置不会自动覆盖。
- 无遥测、无日志上传、无云同步。命令本身可联网；你手动打开 DevTools 后，浏览器会访问该本机服务。
- 日志、项目路径、命令和 DevTools 地址可能包含令牌、环境信息或业务数据。不要把运行数据提交到 GitHub。历史数据不加密，依赖 macOS 用户权限和磁盘保护。

## 工程结构

- `FlutterRunbar.xcodeproj`：标准 macOS App Target、XCTest Target 和共享 Scheme。
- `Resources/Info.plist`：应用名称、版本变量和菜单栏应用配置。
- `project.yml`：可重新生成 Xcode 工程的 XcodeGen 配置。
- `RunbarCore`：配置/运行模型、原始日志、增量解析、运行生命周期，可由 XCTest 单独测试。
- `RunbarProcess`：`posix_spawn`、独立进程组、信号、waitpid；避免在多线程 GUI 中使用 fork 后复杂逻辑。
- `FlutterRunbar`：SwiftUI MenuBarExtra / NavigationSplitView，AppKit 目录选择、退出确认、原生文本视图。
- `scripts/test-process.sh`：C 层过程集成测试，验证含空格目录、stdout/stderr、退出码、启动失败、大输出、进程组升级和无关进程保护。

## CI 与验证边界

`.github/workflows/macos.yml` 在 main 分支推送时自动触发，也支持手动触发，使用标准 `macos-26` Apple Silicon runner 与 Xcode 26.6，运行测试并生成 ad hoc 签名应用产物，保留 3 天。默认工作流使用标准 runner；公开仓库的标准托管 runner 通常免费。若未来改为私有仓库，Actions 可能消耗账户额度或产生费用，确认预算后再运行。不配置证书、不创建凭据、不发布 Release。

官方 runner / Xcode 参考：
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md

最初在 Linux 环境创建，后续已在本机 macOS / Xcode 环境执行 Swift 测试、C 进程集成测试和原生应用构建。Xcode 工程的测试与 Release Archive 也需在 macOS 上验证；CI 使用上述标准 macOS runner。

建议原生验收：从 Finder 启动应用（非终端环境）、FVM PATH、真实 Flutter 项目含空格路径、重复运行/停止、两种流的大量输出、中文/Emoji、命令失败、无换行 DevTools、退出取消/确认、磁盘不可写、日志恢复及多条历史记录切换。
