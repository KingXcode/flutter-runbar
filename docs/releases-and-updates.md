# GitHub 发布与应用更新

## 日常一键发布

1. 完成代码改动后，改写 `CHANGELOG.md` 的「下一版本」：分别写清新增 / 修复、用户如何使用、影响范围和已知限制。首次公开发布的已有能力要与本次新增区分。不要只贴提交标题或写「优化体验」。
2. 在 `project.yml` 设置 `MARKETING_VERSION`（三个数字，例如 `0.10.0`），需要改工程时执行 `xcodegen generate`。提交并推送到 `origin/main`，保证工作区干净。打包构建号自动取当前 Git 提交计数，不需要每次手动递增工程中的默认构建号；发布后不重写 main 历史。
3. 确保已安装并登录 `gh`，账号有本仓库 Release 写权限。运行以下一个入口：

```sh
./build_macos_app.sh      # dist + 桌面 App，Release 附件为 ZIP + SHA-256
./build_macos_dmg.sh      # dist + 桌面 DMG，Release 附件为 DMG + SHA-256
```

两个入口都编译 Apple Silicon / Intel 通用应用。底层 `bash scripts/build-app.sh` 也默认发布，但不复制到桌面。公开发布库固定为 `KingXcode/flutter-runbar`，不自动修改仓库可见性或创建凭据。构建时记录版本、构建号及源码 SHA；标签如 `v0.10.0+47`，同一提交的 App / DMG 加入同一条 Release。

DMG 默认要求唯一可用的 Developer ID Application 证书，可用 `--signing-identity` 指定。没有分发证书时显式传 `--signing-identity -` 生成 ad hoc DMG。App 默认 ad hoc 签名。签名时间戳可能访问 Apple 签名服务；**不调用 notarytool、不公证、不向 Apple 上传安装包**。

只打本地开发包时用：

```sh
./build_macos_app.sh --no-publish
./build_macos_dmg.sh --no-publish
bash scripts/build-app.sh --no-publish
```

源码 ZIP 没有 Git 历史时仅支持 `--no-publish`，使用工程默认构建号。Xcode 的普通 Run / Archive 不会触发 GitHub 发布。CI / 截图工作流明确使用 `--no-publish`，不会发布；本地发布只运行构建与签名 / 映像校验，不自动运行测试或启动业务项目。

## 更新说明与发布完整性

- 发布脚本提取 `CHANGELOG.md` 的「下一版本」，同一份内容写入 GitHub Release，Runbar 更新窗口读取 Release 正文。发布后历史说明留在对应 Release，不被下一次编辑覆盖。
- 说明至少要有分节与多个条目；与上次发布摘要完全相同的新版本会被拒绝。脚本检查结构和变化，说明的准确性仍需作者逐项核对。
- 发布前核对 main、干净工作区、origin、远端 main SHA、公开仓库以及已有版本。拒绝覆盖不同提交的同名标签或将较低版本设为最新。
- 仅上传 `dist/` 中明确指定的 ZIP / DMG 与对应 `.sha256`；不打包用户配置目录、业务项目或本机记录。首次创建草稿并指定精确源码 SHA，上传完毕且 GitHub 返回的 SHA-256 匹配后才公开。
- 同一提交的同名附件不会覆盖；签名时间戳可能使重复构建的二进制字节不同，但线上原包保持不变。中途上传失败可重试；已有同名文件内容冲突时需检查草稿，脚本不擅自删除它。
- Release 发布发生在桌面 App 安装器退出旧版之前。发布失败返回非零，保留 `dist/` 产物与 `.build/logs/package-*.log`，不继续替换桌面 App。
- DMG 不退出 Runbar、不替换桌面 App。App 入口沿用正常退出 / 备份 / 整体替换机制；不自动启动新版。

需要仅重试已构建产物的发布时：

```sh
python3 scripts/github-release.py publish \
  --artifact 'dist/Runbar-0.10.0-47-macOS26.0-universal-signed.dmg' \
  --app '.build/xcode-universal/Build/Products/Release/Runbar.app'
```

路径中的版本与构建号以实际产物为准，必须对应当前已推送提交。默认不会删除本机旧版本或历史 Release。

## Runbar 内如何更新

从应用菜单、菜单栏面板或设置点击「检查更新」。窗口显示当前版本、检查结果、上次成功检查时间和发布的完整中文说明。发现更高版本且有兼容附件时显示下载按钮，优先选择签名通用 DMG；没有适配附件时说明原因，并保留 GitHub 发布页入口。

- 默认每天自动检查一次，使用本机日历日期；请求发起前即持久化当天记录，网络失败、应用重开或开关反复切换都不会当天反复自动请求。保持应用运行时每 15 分钟只检查是否跨天，到下一天才允许新请求。
- 手动检查不受每日限制；正在检查时合并请求，不重复并发。可随时关闭自动检查。自动发现新版本后在菜单栏面板和设置显示提示，不打断正在运行的项目。
- 检查使用公开 GitHub `releases/latest` API，不要求用户登录 GitHub，仅接受本仓库 HTTPS 发布页及下载地址。草稿和预发布不作为正式更新；按数字比较产品版本与构建号，不按字符串排序。
- 使用无 cookie / 磁盘响应缓存的会话，超时与返回大小有上限；只将验证过的发布信息缓存到用户偏好。失败显示原因并保留上次有效信息；404 表示暂未发布。公开 API 有速率限制，遇到限制可稍后手动检查或打开发布页。
- 下载交给默认浏览器，不自动运行安装器。停止任务、退出旧版，再手动用下载的 App 替换。用户配置与记录位于独立应用支持目录，替换 App 不清理它们。

本功能不会上传项目路径、命令、日志或网络记录。GitHub 仍会收到正常 HTTP 请求信息（如访问 IP 与 User-Agent）。无 Apple 公证的包可能被 macOS 拦截，确认来源后按系统提示允许打开；不要关闭系统安全功能。

参考：[GitHub 最新 Release API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)、[gh release create](https://cli.github.com/manual/gh_release_create)、[gh release upload](https://cli.github.com/manual/gh_release_upload)。
