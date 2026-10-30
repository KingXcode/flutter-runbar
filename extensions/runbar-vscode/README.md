# Runbar Bridge

Runbar 的轻量 VS Code 扩展，源码随 Runbar 一起维护。当前以本地 VSIX 分发，不要求使用者注册发布者或安装 Node.js。

## 使用

1. 在 Runbar 运行 Flutter 项目的 **Debug** 命令，或通过「连接 App」监听正在运行的 Flutter Debug App，等待调试服务就绪。
2. 点击右上角 **VS Code**。关联 App 首次使用时选择对应的 Flutter 源码目录，之后 Runbar 会记住关联。缺少扩展时，按 Runbar 提示点击 **安装并连接**。
3. 首次使用时，在 VS Code 中确认打开连接链接，并信任自己选择的源码目录。随后在 Dart 源码中设置断点。

VS Code 未打开时会自动打开。接收请求的窗口已经包含此项目时直接使用；否则打开一个新的项目窗口，保留原窗口。此功能需要与运行版本一致的本机源码。关联 App 不需要由 Runbar 启动，但必须先选择源码目录；Profile / Release 和远程工作区不在支持范围。

需要 VS Code 1.101+、官方 Dart 扩展 3.144.0+，以及 Flutter 扩展。首次安装官方依赖需要访问 VS Code Marketplace。Runbar Bridge 的 VSIX 已包含在 Runbar.app 内，可以在 Runbar 设置 → VS Code → 安装 / 管理扩展中保存，随后用 VS Code 扩展页面的 **⋯ → 从 VSIX 安装** 手动安装。如果 VS Code 使用其他配置文件或扩展被禁用，请在实际调试窗口中安装、启用后重试。

Runbar 使用官方 Dart 调试器直接附加已有 VM，由原来的 Flutter CLI / IDE 继续管理运行与编译；关联 App 不会再启动一次运行命令。热重载、热重启使用 Runbar 按钮。结束附加调试不会重新执行运行命令。

## 开发和分发

纯 JavaScript，仅依赖 VS Code API 和 Node 内置模块，不需要 npm 运行依赖。主入口 `extension.js`，协议与有界 HTTP 客户端位于 `bridge.js`。

在仓库根目录执行：

```bash
python3 scripts/package-vscode-extension.py
```

产物：`dist/vscode-bridge/runbar-bridge.vsix` 与版本元数据。标准 Xcode 构建会自动执行同一脚本，将它们嵌入 App，原有 App / DMG 打包入口也会自动携带扩展。不上传源码，不发布到 Marketplace。

如需单独调试扩展，可使用 VS Code 的 Extension Development Host 打开此目录。真实附加调试请使用自己的 Flutter Debug 项目；不要对正在使用的业务 App 做自动断点测试。

## 连接协议

Runbar 启动仅监听 `127.0.0.1` 的短时服务，通过 `vscode://kingxcode.runbar-bridge/attach` 发送端口和随机一次性令牌。链接不含 VM 认证地址。扩展先查询目录，打开正确工作区后才领取 VM 地址，使用 `debug.startDebugging` 的 `attach` 模式连接。Runbar 每次查询、领取和结果回报都核对原项目 / App 与运行会话。关联 App 额外校验进程、源码映射及 VM PID，并只读检查 Flutter Debug 服务能力，不触发重载 / 重启 / 暂停；停止、重跑、关闭连接窗口或三分钟超时后不能继续领取。

跨窗口只保存短时令牌、项目路径和过期时间到扩展自己的私有目录；不写目标项目的 `launch.json`、源码或设置，不保存 VM 地址到扩展配置或跨窗口文件。HTTP 读取限制、连接数和超时都有上限，不跟随重定向。VS Code 自身的调试日志可能包含调试服务地址，分享调试日志前请留意。
