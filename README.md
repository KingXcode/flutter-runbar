# Runbar

macOS 26+ 的原生 SwiftUI 菜单栏项目命令工具。可为任意项目目录保存并运行终端命令，根据项目类型提供可选模板。

## 关联正在运行的 Flutter App

侧栏底部点「连接 App」，选择正在运行的应用。Runbar 尝试识别本机调试服务；未发现完整地址时，可粘贴 IDE 输出的 DevTools 或 VM Service 链接。此功能不要求选择源码目录、不需要修改业务代码。

连接后在「应用监听」分组中查看实时 Dart 日志、HTTP / HTTPS 请求和本地历史。断开、退出 Runbar 都只结束监听，目标 App 继续运行；每次连接保存一条记录，应用重启后的新 PID 仍归入相同应用。DevTools 按钮优先使用输入的有效链接，否则按需启动本机 Dart SDK 的 DevTools 服务。

普通 Release 包通常不提供调试服务。自动发现受认证配置影响，无法仅凭 PID 得到认证路径；带认证的服务可能需要粘贴完整链接。日志从订阅后开始接收，不保证包含此前历史、构建输出或所有原生插件日志。详见 [应用监听说明](docs/application-attachment.md)。

## 第一版功能

- 选择并保存多个项目目录，添加、编辑每个项目的命令预设。
- 支持任意项目和空目录；新项目没有默认命令，所有命令由用户选择模板或自行保存。
- 自动识别 Flutter、Xcode、Android、Swift Package、Node.js、Python、Rust、Go、Dart、Gradle；可手动调整项目类型或重新识别。
- 在项目目录中执行你明确保存的命令；每个项目同一时刻只允许运行一条，不同项目可以同时运行。
- 菜单栏项目列表：每行项目名、独立命令选择、运行、停止；本次运行识别出的 DevTools 地址显示在该项目下面，点击后打开。保留「打开主界面」。列表支持滚动、长文本省略与辅助功能标签。
- 默认全局 F3 呼出主界面，同时前置本次运行的 macOS 应用；在设置中点击录制其他快捷键，可关闭并自动保留配置。部分键盘需配合 Fn。
- 保存每次运行的命令快照、开始/结束时间、持续时间、状态、退出码。
- 连续读取合并的 stdout/stderr，保存全部原始字节及有顺序号的接收时间索引。
- 实时日志窗口、历史日志、本地日志目录入口。显示窗口有内存上限，磁盘日志不截断。
- 可勾选显示 / 隐藏每行输出的接收时间，时间侧栏不影响正文搜索或复制。运行详细信息默认折叠。
- 日志使用最多 1 MB 的滚动窗口；上下滚动会自动读取相邻内容，右侧滚动条表示整份日志的字节进度，可直接拖到任意位置、最早或最新。自动跟随、换行和展开日志均可切换。
- 日志状态仅显示原始日志总大小和当前阅读位置百分比；应用筛选时百分比按筛选结果计算，总大小仍为原始日志。
- 输出支持多个包含、排除关键词和起止时间筛选。小浮层内回车生效，点 × 移除；最近关键词和整组方案可一键复用、删除，条件自动保存。
- `⌘F` 搜索完整日志，显示总数和当前序号，支持上一个 / 下一个、Enter / Shift+Enter 和命中高亮。搜索不受筛选限制，查看隐藏行时明确显示搜索上下文，可返回筛选结果。
- 筛选与搜索在后台按 64 KB 分块扫描，结果位置索引保存在磁盘；运行中只扫描新增内容，超长行与海量命中不会整份驻留内存。详见 [日志筛选与搜索](docs/log-query.md)。
- 增量处理 UTF-8 / ANSI / 分块 URL，识别实际的本机 DevTools 地址，而不是把 Dart VM Service 地址当成 DevTools。
- DevTools 由你点击打开或复制，不自动打开；历史运行的打开按钮禁用。
- 停止采用独立进程组 SIGINT → 3 秒后 SIGTERM → 6 秒后 SIGKILL，不使用 killall。
- 退出时若仍有命令运行，明确询问并等待所有项目停止和各自日志保存；异常退出留下的记录标为中断，不追杀历史 PID。

DevTools 网络请求采集的接口与独立原型验证见 [可行性分析](docs/devtools-network-capture.md)。现已接入日志 / 网络面板，支持正文缓存、请求跟随和格式化。

## 运行环境

- macOS 26 或更新版本。
- 从源码开发或打包需 Xcode 26（Swift 6.2）或更新版本。已打包应用执行普通命令不要求安装 Xcode。项目使用 Swift 5 语言模式，UI 使用 SwiftUI，日志显示与目录选择采用 AppKit 桥接。
- 按实际命令安装所需工具链；应用本身不要求安装 Flutter / FVM。
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
open 'dist/Runbar.app'
```

### 一键打包到桌面

在项目根目录运行：

```sh
./build_macos_app.sh
```

脚本执行 Release 构建和签名校验，同时生成 `dist/Runbar.app` 与 `~/Desktop/Runbar.app`，只生成 `.app`。也可从任何目录用脚本的绝对路径运行，或在 Runbar 中把命令设为 `./build_macos_app.sh`。

首次改名安装会同时备份并移走桌面旧名 `Flutter Runbar.app`，桌面只保留新版 `Runbar.app`。应用标识和数据目录保持不变，原有配置、命令与运行记录继续使用。

替换桌面应用前，安装器先请求正在运行的 Runbar 正常退出，确认退出后整体备份旧包并替换，不合并旧文件，也不自动启动新版。若还有项目任务，会显示应用原有的「停止并退出 / 取消」确认；取消或 120 秒内未退出就停止安装，保留桌面旧包，不强制杀进程。旧包备份到 `.build/package-backups/<时间>/`，确认不再需要后可自行删除。

从 Runbar 自身执行打包时，会把桌面替换交给独立安装器，避免退出旧版时连同安装器一起停止。此时脚本会明确提示安装仍在进行，最终结果查看 `.build/logs/install-*.log` 中的「桌面安装完成」。构建日志位于 `.build/logs/package-*.log`；从终端执行时会等待桌面替换完成，失败返回非零退出码。

CI 继续使用 `bash scripts/build-app.sh`，只输出到 `dist/`；加 `--desktop` 可同时复制到桌面。`--help` 可查看参数。截图预览构建使用独立的 Derived Data，避免混入正式构建。

构建脚本生成可放进 Applications 的 `.app`，仅使用本机 ad hoc 签名，不是 Developer ID 签名，未公证。跨机器分发可能遇到 Gatekeeper；不要关闭系统安全功能。正式分发需单独配置合法签名与公证。当前构建只生成所在机器架构的应用。

`FlutterRunbar.xcodeproj`、共享 Scheme 和 `Resources/Info.plist` 已保存在仓库中，正常使用 Xcode 不需要安装额外工具。`Package.swift` 管理共享的 `RunbarCore` / `RunbarProcess` 模块，应用 Target 和测试 Target 使用同一份源码。`project.yml` 是 XcodeGen 工程生成配置；需要重新生成时使用 XcodeGen 2.46+ 执行 `xcodegen generate`。如果直接在 Xcode 修改工程设置，应同步修改 `project.yml`，避免重新生成时覆盖设置。

### Xcode 控制台系统日志

共享 Scheme 的 `Run > Arguments > Environment Variables` 默认启用 `OS_ACTIVITY_MODE=disable` 与 `IDELogRedirectionPolicy=oslogToStdio`，用于减少 macOS App Intents / `com.apple.linkd.autoShortcut` 等系统服务日志。它会抑制调试进程的统一系统日志，不是只过滤某一个错误；需要排查系统框架时取消勾选这两个变量即可恢复。普通 stdout/stderr 和应用保存的命令原始日志仍正常工作。测试和 Profile 使用默认日志模式，Release 归档不会写入这些运行环境变量。系统服务连接问题本身不由这项设置修复。

日志模式说明参考 [WebKit 官方调试文档](https://webkit.org/debugging-webkit/#logging)。

## 使用

1. 从菜单栏打开管理窗口，点击「添加项目」选择任意目录。根据根目录中的工程文件识别类型；Flutter 优先于其平台子工程，Xcode 工程优先于同目录的 Package.swift。不执行项目代码或扫描全部子目录。目录可包含空格或中文。
2. 在项目标题旁可调整类型或「重新识别项目类型」。点击「+」选用该类型的模板或直接输入自定义命令；新项目不会自动加入任何命令。支持 zsh 引号、管道与环境变量赋值，例如 `npm run dev`、`swift test`、`fvm flutter run -d macos`。
3. 在菜单栏列表选择该项目的命令，点击右侧「运行」。不同项目互不影响；运行中不能改选/编辑该项目命令。DevTools 出现后，直接点击该行下方的链接。停止时链接立即隐藏，新一轮运行不会复用旧链接。主界面保留详细日志与历史记录。
4. 点击「停止」。界面等待最多约 6 秒的正常升级阶段，并继续排空输出，再保存最终退出结果。
5. 运行记录只显示左侧所选项目的数据，记录数量也随项目切换更新；按完整项目目录匹配，同名不同目录的项目不会混在一起。项目分组可折叠或展开，新记录在前。点击记录可选中高亮并查看输出，再次点击同一条取消选中，右侧恢复默认空白。取消查看不停止命令；任务结束也不会改变当前选中状态。选中记录后点击「在 Finder 中显示日志文件」定位该记录的 `output.raw`；未选中或文件不存在时按钮不可用。
6. 右键运行记录可删除；点击「多选」勾选、⌘ 点选或 Shift 连选后，可批量删除。「全选」只选当前项目的可删除记录。确认后记录及完整日志一起移到系统废纸篓，运行中的记录不能删除；删除失败会恢复整个批次。
7. 右键项目选择「移除项目」，或点击项目栏底部的「−」。仅移除应用内的项目与命令配置，保留磁盘项目目录和历史日志；运行中的项目需先停止。重新添加同一目录仍可查看历史，但需重新配置命令。不提供批量移除项目。
8. 点击主界面右上角齿轮进入「设置」，切换「在 Dock 中显示」。默认关闭，切换立即生效并自动记住；开启后启动会显示主界面，点击 Dock 图标可重新打开主界面。关闭后仍可从菜单栏使用，运行中的命令不受影响。

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
- 实时跟随使用最多 256 KB 的活动窗口，历史浏览最多 1 MB，上下滚动到窗口边缘会自动读取相邻的重叠窗口，保留当前阅读位置，直到文件两端；不会把经过的窗口累积在内存中。右侧滚动条按整个原始文件的字节位置和当前可见范围计算（不是逐行精确索引），拖到顶部读取文件开头，拖到底部读取文件末尾，拖到中间按比例定位。快速拖动合并为最后一次读取请求。页面只在后台读取固定大小的数据和少量边界上下文，不将整个文件载入内存；不同记录间切换会丢弃旧页面。实时输出最多约每 300 毫秒合并刷新一次；跟随时缓存解析状态，只读取上次位置之后的新增字节，原生文本控件按差量追加，并在窗口超限时分批淘汰头部，避免每次重读和替换整个窗口。后台刷新不显示加载圈，显式导航等待超过 200 毫秒时才显示。向上滚动会暂停跟随，滚动回文件最末尾、拖到底部或点击「最新」恢复；暂停时仍更新文件总大小和全局滚动条进度。默认长行横向滚动，可开启「自动换行」；「展开日志」隐藏运行记录栏以增加显示空间。原始字节、ANSI 和 UTF-8 边界按磁盘偏移读取，ANSI 控制码不显示，原文件保持不变。完整日志始终在磁盘，直到用户自行管理文件，没有自动清理，会持续占用磁盘。
- 删除的记录按批次存放在废纸篓的 `Runbar Deleted Records …` 文件夹中，可找回原始日志。若要恢复到运行列表，将批次中的 UUID 目录放回 `~/Library/Application Support/FlutterRunbar/sessions/` 后重启应用；不要覆盖已有的同名目录。
- 磁盘写入、同步或读取失败会显式报错，并停止命令；不把不完整日志宣称为成功。异常中断无法准确知道结束时间，因此保留为空。
- 损坏的单条历史记录保留原文件、跳过并提醒；损坏配置不会自动覆盖。
- 无遥测、无日志上传、无云同步。命令本身可联网；你手动打开 DevTools 后，浏览器会访问该本机服务。
- 日志、项目路径、命令和 DevTools 地址可能包含令牌、环境信息或业务数据。不要把运行数据提交到 GitHub。历史数据不加密，依赖 macOS 用户权限和磁盘保护。

## 工程结构

- `FlutterRunbar.xcodeproj`：标准 macOS App Target、XCTest Target 和共享 Scheme。
- `Resources/Info.plist`：应用名称、版本变量和菜单栏应用配置。
- `project.yml`：可重新生成 Xcode 工程的 XcodeGen 配置。
- `RunbarCore`：配置/运行模型、原始日志、增量解析、运行生命周期，以及每项目独立的 `ProjectRunCoordinator` 状态机，可由 XCTest 单独测试。
- `RunbarProcess`：`posix_spawn`、独立进程组、信号、waitpid；避免在多线程 GUI 中使用 fork 后复杂逻辑。
- `FlutterRunbar`：SwiftUI MenuBarExtra / NavigationSplitView，AppKit 目录选择、退出确认、原生文本视图。
- `scripts/test-process.sh`：C 层过程集成测试，验证含空格目录、stdout/stderr、退出码、启动失败、大输出、进程组升级、无关进程保护，以及 24 路并行启动时独立日志与 EOF。

## CI 与验证边界

`.github/workflows/macos.yml` 在 main 分支推送时自动触发，也支持手动触发，使用标准 `macos-26` Apple Silicon runner 与 Xcode 26.6，运行测试并生成 ad hoc 签名应用产物，保留 3 天。默认工作流使用标准 runner；公开仓库的标准托管 runner 通常免费。若未来改为私有仓库，Actions 可能消耗账户额度或产生费用，确认预算后再运行。不配置证书、不创建凭据、不发布 Release。

官方 runner / Xcode 参考：
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md

最初在 Linux 环境创建，后续已在本机 macOS / Xcode 环境执行 Swift 测试、C 进程集成测试和原生应用构建。Xcode 工程的测试与 Release Archive 也需在 macOS 上验证；CI 使用上述标准 macOS runner。

建议原生验收：从 Finder 启动应用（非终端环境）、FVM PATH、真实 Flutter 项目含空格路径、重复运行/停止、两种流的大量输出、中文/Emoji、命令失败、无换行 DevTools、退出取消/确认、磁盘不可写、日志恢复及多条历史记录切换。并行场景需验证 A/B 同时启动、只停止 A、B 保持运行、各自 DevTools 链接，以及退出时等待全部项目完成。


菜单预览工作流仅在 `SCREENSHOT_PREVIEW` 编译条件下构造虚构运行状态，禁止执行命令，并在原生预览窗口中承载生产环境同一份菜单内容。截图中的预览窗口标题栏不代表实际菜单弹窗边框；生产应用使用 `MenuBarExtra` 的 window 样式。正常构建不包含这些预览分支。


主界面将项目导航、当前项目的命令控制、历史记录和输出日志分开显示。状态标签同时使用文字与图标，配色跟随 macOS 浅色/深色模式；紧凑菜单栏布局保持不变。日志区的本地文件路径和 Finder 按钮始终绑定当前选中的运行记录。

### 常用命令模板

主界面命令旁的「+」根据项目类型提供模板，点击「填入下方编辑区」后仍可编辑：

| 项目类型 | 模板来源及示例 |
| --- | --- |
| Flutter | `pubspec.yaml` 中的 Flutter SDK 依赖；运行 macOS/Chrome 可选 Debug、Profile、Release，另有依赖、检查、测试、格式化及各平台构建。FVM 仅是这一类模板的可选前缀。 |
| Xcode | 根目录 `.xcodeproj` / `.xcworkspace`；列出 Scheme、查看模拟器，为找到的共享 Scheme 生成构建命令。多个容器时不猜测目标，需自行补充参数。 |
| Android | Android Manifest 或 Gradle Android 插件；列出任务、Debug APK、Lint、测试、清理。存在 `gradlew` 时优先使用 Wrapper。 |
| Swift Package | `Package.swift`；构建、Release、测试、解析依赖和清理。 |
| Node.js / Web | `package.json`；按 `packageManager` 或锁文件选择 npm/pnpm/yarn/bun，只提供实际存在的 scripts，不假定 dev/build/test 一定存在。 |
| Python | `pyproject.toml` / requirements / setup.py / Pipfile；虚拟环境、版本、unittest，按文件提供 requirements 或 uv 同步。 |
| Rust / Go / Dart / Gradle | 根据对应清单提供构建、检查、测试、依赖等命令。 |
| 通用 / 自定义 | 不提供模板或内置操作，全部由用户自定义。 |

识别仅影响建议与工具选项，不限制可运行的命令。手动类型会保存；旧配置首次读取时识别类型，已有命令的内容、UUID、选择及历史不会重写。未识别的类型也可使用任意终端命令。

模板仅填入可编辑草稿，保存后才加入当前项目，且仍需手动点击运行。不会自动执行、安装 SDK、上传构建或向已有项目批量添加配置。原有命令及选择保持不变；保存时拒绝当前项目中相同的命令文本（忽略首尾空白），不重写 shell 引号或参数。格式化会修改源文件；清理会删除生成目录。运行前请检查模板说明和实际命令。

命令参考：[Flutter CLI](https://docs.flutter.dev/reference/flutter-cli)、[Xcode 命令行工具](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference)、[Gradle CLI](https://docs.gradle.org/current/userguide/command_line_interface.html)、[Swift Package](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/)、[npm scripts](https://docs.npmjs.com/cli/v7/commands/npm-run-script/)。

Flutter 项目添加命令时，选择运行模板和运行模式，再点「填入下方编辑区」，会生成带 `--debug` / `--profile` / `--release` 的命令和对应名称。三个模式可分别保存，也可继续编辑设备 ID、flavor、入口文件等参数；已有命令不会被自动改写。模式支持范围以当前 Flutter 工具链和目标设备为准，参考 [Flutter 构建模式](https://docs.flutter.dev/testing/build-modes)。


### 清空 macOS App 沙盒（内置操作）

Flutter 类型项目的命令列表（主界面与菜单栏）提供「清空 macOS App 沙盒」。其他类型不显示这一 Flutter 构建目录专用操作。这是原生操作，不拼接 shell、不添加 FVM 前缀，也不能编辑成命令字符串。旧自定义命令和当前选择不变。

- 先停止项目运行并退出目标 App。只发现该项目 `build/macos/Build/Products/<配置>/*.app` 的实际构建产物；多个候选时明确选择，不猜测 Debug / Release 或 flavor。尚未构建时先构建，不扫描其他项目或 Applications。
- 读取实际 App Bundle ID、验证签名及 App Sandbox entitlement，再核验当前用户的容器归属、路径及身份。未启用沙盒、无容器、符号链接重定向或无法核验时停止。
- 确认框列出 App 完整路径、Bundle ID 和整个 `~/Library/Containers/<Bundle ID>`，默认取消。确认后重新检查 App 已退出、容器归属与身份，然后使用系统废纸篓 API 移动整个容器，包含 Documents、Library、tmp 和容器元数据；不是只清缓存。
- 相同 Bundle ID 的其他安装副本也会受影响。不会递归跟随容器内链接清除外部文件；不清理 App Groups、钥匙串、iCloud 或其他容器外数据。
- macOS 的容器保护可能拒绝访问或移动，届时显示原始错误并停止，不使用 sudo、永久删除或更改系统权限。请停止 IDE 自动重启任务；跨进程启动无法由此工具原子锁住。
- 操作结果保存在本地历史与日志中，取消显示「已取消」，不是成功。原生操作没有 shell 退出码。移到废纸篓不等于彻底恢复出厂；下次启动通常重建容器。恢复前先退出 App，再在 Finder 中从废纸篓放回。

验证时只使用临时测试容器和替身签名/运行/废纸篓服务，不操作真实应用数据。真实 macOS 容器访问和恢复行为仍需在用户明确同意的测试 App 上验收。

### 网络请求采集

输出面板切换到「网络」，勾选「网络采集」即可记住当前项目的开关。连接到运行进程的 Dart VM Service 后，显示 HTTP / HTTPS 请求、Headers、请求 / 响应正文，并提供地址、方法、状态筛选和完整历史列表。列表从旧到新连续滚动，滚动条对应全部匹配记录；支持跟随最新、跳到最早 / 最新，内存只保留附近最多 256 条轻量摘要，选中的详情和正文按需读取。已缓存数据绑定运行记录，程序退出后仍可查看。默认每个方向的正文最多 1 MiB，每次运行正文合计 128 MiB、摘要最多 50,000 条；缺失和超限内容有明确标记。

支持范围、启动阶段采集、暂停 / 清理目标缓冲的区别及容量验证见 [网络采集说明](docs/devtools-network-capture.md)。Flutter Web、WebView、未接入 profiling 的原生网络请求和 WebSocket 不在本版采集范围。
