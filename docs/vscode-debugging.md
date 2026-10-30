# VS Code 调试接入

## 交互

- 运行 Flutter 项目的 Debug 命令后，右上角显示「VS Code」。调试服务与 Flutter Debug 交互能力就绪后启用；其他运行模式不提供断点连接。
- 点击按钮时检测 VS Code 与扩展。已安装时直接打开项目并附加；缺少扩展时显示「安装并连接」和可展开的手动安装说明。用户也可从设置 → VS Code →「安装 / 管理扩展」独立安装。
- VS Code 未打开时自动打开。接收链接的窗口包含同一真实项目路径时复用；否则新开项目窗口，不关闭原来的其他项目窗口。不枚举或保证复用另一个后台窗口。
- 首次使用时 VS Code 可能要求允许此扩展处理链接，及信任源码目录；需使用者确认。扩展不会绕过工作区信任。安装成功但被禁用、切换了 VS Code 配置文件、首次安装需重新加载窗口时，按提示处理后回 Runbar 重试。
- 附加成功后在 VS Code 设置 Dart 断点。热重载、热重启继续使用 Runbar 的运行按钮。Runbar 不重新启动 App，不写入源码、`.vscode/launch.json` 或目标项目设置。

当前支持 macOS 本机稳定版 VS Code 1.101+、官方 Dart 扩展 3.144.0+ 与 Flutter 扩展。只连接有源码项目目录的当前 Debug 运行；不把历史运行的调试地址拿来连接。「关联 App」尚无源码目录映射，不显示此入口。远程 SSH、容器、WSL、VS Code Insiders 和其他编辑器不在本次范围内。

## 安装与分发

`extensions/runbar-vscode` 保存完整扩展源码，无 npm 运行依赖。扩展 ID 为 `kingxcode.runbar-bridge`，当前使用私有 VSIX 分发，不发布 Marketplace。

标准 Xcode 工程在资源复制后、签名前执行 `scripts/package-vscode-extension.py`，用 Python 标准库按 VSIX 格式生成扩展及版本元数据到：

```text
Runbar.app/Contents/Resources/VSCodeBridge/
  runbar-bridge.vsix
  metadata.json
```

`build_macos_app.sh`、`build_macos_dmg.sh` 都通过相同 Xcode 工程构建，安装包因此自动随 App 或 DMG 分发。打包不执行 npm 安装、不发布扩展、不上传 App/DMG、不公证。使用者无需 Node.js/Python 或仓库源码，官方 Dart / Flutter 扩展缺失或过旧时，VS Code 的安装/更新需要网络。

独立生成 VSIX：

```sh
python3 scripts/package-vscode-extension.py
```

输出在 `dist/vscode-bridge/`。脚本只打入清单中的扩展源码、说明和 manifest，不采集项目、运行历史、设置或认证地址。更新扩展时修改 `extensions/runbar-vscode/package.json` 的版本号；Runbar 根据嵌入的元数据检查是否需要更新。

Runbar 从 VS Code 的 App Bundle 读取真实的可执行文件路径，再调用其自带的 CLI，以参数数组检测及安装扩展，不拼接 shell 命令，不写死主程序名为 Electron 或 Code。命令行组件无法检测时显示具体原因，不据此判定扩展缺失或提示重复安装。手动安装时在 Runbar 导出 VSIX，然后在实际使用的 VS Code 窗口选择扩展页面的 **⋯ → 从 VSIX 安装**。如果使用其他 VS Code 配置文件，请在该配置文件中安装并启用所需扩展。

## 生命周期与边界

1. `ProjectRunState` 只在内存保存当前运行识别到的 VM Service 地址，结束或重新运行时清除；不增加历史或配置中的认证字段。
2. 连接时建立仅监听 `127.0.0.1` 的短时服务。系统链接只有随机 64 位十六进制令牌与临时端口，没有 VM 认证 URL。每次查询、领取、回报都重新检查原项目、运行 UUID、运行状态和 Debug 能力。
3. 扩展先查询目录。如果需要新窗口，只向扩展私有目录写入短时令牌、目录和过期时间。新窗口启动后重新查询、核对目录和信任状态，再一次性领取 VM 地址。每次领取绑定独立 claim ID，其他窗口不能覆盖已领取请求的完成状态。
4. 扩展探测 VM 后再次向 Runbar 核对会话，调用 VS Code 官方 `debug.startDebugging` API，以 `type: dart`、`request: attach`、显式 `debuggerType: dart` 附加，避免额外启动第二个 Flutter 编译器。不存在重试或重新启动目标 App 的隐式操作。
5. 请求三分钟过期；关闭连接窗口会停止提供本次桥接服务，已在 VS Code 启动的调试会话会保留。桥接服务最多接纳 8 个短连接，单请求最多 8 KiB、正文最多 2 KiB，读入超时 5 秒。扩展桥接响应最多 32 KiB、VM 探测响应最多 256 KiB，绝对超时 8 秒。跨窗口最多保留 8 个有效待办，启动读取有界并清除过期文件。

工作区信任、SDK 初始化与 VS Code 的 URI 允许提示可能延迟连接。发生超时后重新点击连接；请勿使用历史链接。VM 地址只短时用于进程内的附加配置，不主动写扩展配置或跨窗口文件；VS Code / Dart 自身的调试日志与最近调试配置可能保留调试参数，分享相关信息前需检查。Runbar 的原始 Flutter 日志本身仍可能包含 Flutter 输出的调试地址。

实现依据：[VS Code API](https://code.visualstudio.com/api/references/vscode-api)、[VSIX 本地分发](https://code.visualstudio.com/api/working-with-extensions/publishing-extension)、[Dart-Code 调试配置](https://dartcode.org/docs/launch-configuration/)。
