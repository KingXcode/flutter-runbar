# Flutter Runbar

macOS 26+ 的原生 SwiftUI 菜单栏 Flutter 开发辅助工具。独立新项目，不依赖或修改其他应用。

## 第一版功能

- 选择并保存多个项目目录，添加、编辑每个项目的命令预设。
- 默认命令：`fvm flutter run -d macos`。
- 在项目目录中执行你明确保存的命令；每个项目同一时刻只允许运行一条，不同项目可以同时运行。
- 菜单栏项目列表：每行项目名、独立命令选择、运行、停止；本次运行识别出的 DevTools 地址显示在该项目下面，点击后打开。保留「打开主界面」。列表支持滚动、长文本省略与辅助功能标签。
- 保存每次运行的命令快照、开始/结束时间、持续时间、状态、退出码。
- 连续读取合并的 stdout/stderr，保存全部原始字节及有顺序号的接收时间索引。
- 实时日志窗口、历史日志、本地日志目录入口。显示窗口有内存上限，磁盘日志不截断。
- 增量处理 UTF-8 / ANSI / 分块 URL，识别实际的本机 DevTools 地址，而不是把 Dart VM Service 地址当成 DevTools。
- DevTools 由你点击打开或复制，不自动打开；历史运行的打开按钮禁用。
- 停止采用独立进程组 SIGINT → 3 秒后 SIGTERM → 6 秒后 SIGKILL，不使用 killall。
- 退出时若仍有命令运行，明确询问并等待所有项目停止和各自日志保存；异常退出留下的记录标为中断，不追杀历史 PID。

## 运行环境

- macOS 26 或更新版本。
- Xcode 26（Swift 6.2）或更新版本。项目使用 Swift 5 语言模式，以明确控制渐进迁移；UI 使用 SwiftUI，日志显示与目录选择采用 AppKit 桥接。
- 已安装 Flutter / FVM 与运行 Flutter macOS 项目需要的开发工具。
- 不需要第三方 Swift 包、API 密钥、Apple Developer 证书或在线服务。

## 构建

用 Xcode 打开 `Package.swift`，选择 `FlutterRunbar` 可执行产品，运行到本机。也可以：

```sh
swift test
bash scripts/test-process.sh
bash scripts/build-app.sh
open 'dist/Flutter Runbar.app'
```

构建脚本生成可放进 Applications 的 `.app`，仅使用本机 ad hoc 签名，不是 Developer ID 签名，未公证。跨机器分发可能遇到 Gatekeeper；不要关闭系统安全功能。正式分发需单独配置合法签名与公证。当前构建只生成所在机器架构的应用。

## 使用

1. 从菜单栏打开管理窗口，点击「添加项目」。项目目录可包含空格或中文。
2. 选择或编辑命令。支持 zsh 引号、管道与环境变量赋值，例如 `fvm flutter run -d macos`。
3. 在菜单栏列表选择该项目的命令，点击右侧「运行」。不同项目互不影响；运行中不能改选/编辑该项目命令。DevTools 出现后，直接点击该行下方的链接。停止时链接立即隐藏，新一轮运行不会复用旧链接。主界面保留详细日志与历史记录。
4. 点击「停止」。界面等待最多约 6 秒的正常升级阶段，并继续排空输出，再保存最终退出结果。
5. 在主界面的「运行记录」选择本次或历史运行；输出框旁的「在 Finder 中显示日志文件」会定位这次记录的 `output.raw`，便于核对完整原始输出。未选择记录或文件不存在时不可点击，不会改为打开其他运行的日志。

命令由 `/bin/zsh -l -c` 执行，工作目录通过进程 API 设置，不拼接 `cd`。额外 PATH 默认包括 `~/.pub-cache/bin` 的展开路径、`/opt/homebrew/bin`、`/usr/local/bin`；可在「PATH 设置」添加 FVM 实际所在目录。登录 zsh 会读取你自己的登录配置；本应用不安装 SDK、不修改 shell 文件。PATH 只影响新运行。

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

- `RunbarCore`：配置/运行模型、原始日志、增量解析、运行生命周期，以及每项目独立的 `ProjectRunCoordinator` 状态机，可由 XCTest 单独测试。
- `RunbarProcess`：`posix_spawn`、独立进程组、信号、waitpid；避免在多线程 GUI 中使用 fork 后复杂逻辑。
- `FlutterRunbar`：SwiftUI MenuBarExtra / NavigationSplitView，AppKit 目录选择、退出确认、原生文本视图。
- `scripts/test-process.sh`：C 层过程集成测试，验证含空格目录、stdout/stderr、退出码、启动失败、大输出、进程组升级、无关进程保护，以及 24 路并行启动时独立日志与 EOF。

## CI 与验证边界

`.github/workflows/macos.yml` 在 main 分支推送时自动触发，也支持手动触发，使用标准 `macos-26` Apple Silicon runner 与 Xcode 26.6，运行测试并生成 ad hoc 签名应用产物，保留 3 天。默认工作流使用标准 runner；公开仓库的标准托管 runner 通常免费。若未来改为私有仓库，Actions 可能消耗账户额度或产生费用，确认预算后再运行。不配置证书、不创建凭据、不发布 Release。

官方 runner / Xcode 参考：
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md

创建时的 Linux 环境没有 Swift 编译器，也不能执行 SwiftUI/AppKit。此环境只运行 C 进程层测试和脚本静态检查；Swift 测试、macOS 编译及图形交互必须在 macOS 或经授权的 CI 上验证。不要把源代码准备完成理解为已通过原生验证。

建议原生验收：从 Finder 启动应用（非终端环境）、FVM PATH、真实 Flutter 项目含空格路径、重复运行/停止、两种流的大量输出、中文/Emoji、命令失败、无换行 DevTools、退出取消/确认、磁盘不可写、日志恢复及多条历史记录切换。并行场景需验证 A/B 同时启动、只停止 A、B 保持运行、各自 DevTools 链接，以及退出时等待全部项目完成。


菜单预览工作流仅在 `SCREENSHOT_PREVIEW` 编译条件下构造虚构运行状态，禁止执行命令，并在原生预览窗口中承载生产环境同一份菜单内容。截图中的预览窗口标题栏不代表实际菜单弹窗边框；生产应用使用 `MenuBarExtra` 的 window 样式。正常构建不包含这些预览分支。


主界面将项目导航、当前项目的命令控制、历史记录和输出日志分开显示。状态标签同时使用文字与图标，配色跟随 macOS 浅色/深色模式；紧凑菜单栏布局保持不变。日志区的本地文件路径和 Finder 按钮始终绑定当前选中的运行记录。

### 常用命令模板

主界面命令旁的「+」可选择 15 个模板，再点「填入下方编辑区」：macOS / Chrome 运行、获取依赖、检查依赖更新、清理构建缓存、代码检查、测试、Dart 格式化、设备列表、环境诊断，以及 macOS / Web / APK / App Bundle / iOS（不签名）构建。默认使用 FVM，也可取消勾选改用 PATH 中的 Flutter / Dart。模板说明会展示文件修改、清理、SDK 和签名要求。

模板仅填入可编辑草稿，保存后才加入当前项目，且仍需手动点击运行。不会自动执行、安装 SDK、上传构建或向已有项目批量添加配置。原有命令及选择保持不变；保存时拒绝当前项目中相同的命令文本（忽略首尾空白），不重写 shell 引号或参数。格式化会修改源文件；清理会删除生成目录。运行前请检查模板说明和实际命令。

命令参考：[Flutter CLI](https://docs.flutter.dev/reference/flutter-cli)、[Dart format](https://dart.dev/tools/dart-format)、[FVM 使用](https://fvm.app/documentation/getting-started/faq)、[Android 构建](https://docs.flutter.dev/deployment/android)、[iOS 构建](https://docs.flutter.dev/deployment/ios)、[Web 构建](https://docs.flutter.dev/deployment/web)。


### 清空 macOS App 沙盒（内置操作）

每个项目的命令列表（主界面与菜单栏）都有「清空 macOS App 沙盒」。这是原生操作，不拼接 shell、不添加 FVM 前缀，也不能编辑成命令字符串。旧自定义命令和当前选择不变。

- 先停止项目运行并退出目标 App。只发现该项目 `build/macos/Build/Products/<配置>/*.app` 的实际构建产物；多个候选时明确选择，不猜测 Debug / Release 或 flavor。尚未构建时先构建，不扫描其他项目或 Applications。
- 读取实际 App Bundle ID、验证签名及 App Sandbox entitlement，再核验当前用户的容器归属、路径及身份。未启用沙盒、无容器、符号链接重定向或无法核验时停止。
- 确认框列出 App 完整路径、Bundle ID 和整个 `~/Library/Containers/<Bundle ID>`，默认取消。确认后重新检查 App 已退出、容器归属与身份，然后使用系统废纸篓 API 移动整个容器，包含 Documents、Library、tmp 和容器元数据；不是只清缓存。
- 相同 Bundle ID 的其他安装副本也会受影响。不会递归跟随容器内链接清除外部文件；不清理 App Groups、钥匙串、iCloud 或其他容器外数据。
- macOS 的容器保护可能拒绝访问或移动，届时显示原始错误并停止，不使用 sudo、永久删除或更改系统权限。请停止 IDE 自动重启任务；跨进程启动无法由此工具原子锁住。
- 操作结果保存在本地历史与日志中，取消显示「已取消」，不是成功。原生操作没有 shell 退出码。移到废纸篓不等于彻底恢复出厂；下次启动通常重建容器。恢复前先退出 App，再在 Finder 中从废纸篓放回。

验证时只使用临时测试容器和替身签名/运行/废纸篓服务，不操作真实应用数据。真实 macOS 容器访问和恢复行为仍需在用户明确同意的测试 App 上验收。
