# 接入与连接排查

Skill 教 AI 使用 Runbar 工具，不代替 MCP 连接。先在本机 Runbar 开启服务，再由用户选择 Agent 一键安装连接，或手动配置客户端。

## 安装此 Skill

- 优先使用 Runbar 的「安装 / 更新 AI Skill」向导，勾选 Codex、Claude Code、Qoder、Qoder CN、WorkBuddy、OpenCode 等工具后直接安装，无需复制文件。目录可更改，也可添加其他客户端的 Skill 根目录。
- 新版 Runbar 附带 Skill 更新时，启动检查会提示更新；也可随时在向导点击「检查更新」。版本号和文件指纹一起检查，替换前保留旧版备份，本地手动改过的副本需要用户确认后才替换。同一次更新点「稍后」不会每次启动重复提示。
- 手动安装可在 MCP 窗口「导出 ZIP…」后解压；Codex 当前用户目录是 `~/.agents/skills/`，只给一个源码项目使用时放入项目 `.agents/skills/`，其他客户端按其目录约定安装。
- 文件结构应为 `runbar-diagnostics/SKILL.md`、`agents/openai.yaml` 和 `references/setup.md`，不要多套一层同名目录。安装向导仅管理这个 Skill，不更改其他 Skill 或客户端配置。
- 若客户端没有发现，刷新或重启后再选择。显式调用示例：`使用 $runbar-diagnostics 分析当前项目的最新错误日志和失败请求。`

## 配置连接

1. 使用包含 MCP 功能的 Runbar 构建，打开「设置 → AI 连接（MCP）」并开启；看到服务已开启后继续。
2. 在 Runbar 运行项目或关联 Flutter App，需要查看网络请求时开启对应来源的网络采集。
3. 在「安装到 AI Agent」勾选 Codex、Claude Code、Cursor、Qoder CLI、Qoder CN CLI 或 WorkBuddy，核对配置位置后点击「安装 / 更新所选」。可以批量选择；位置不同可从对应行选择已有配置文件。安装前备份原配置，只管理 Runbar 条目。
4. 重连 MCP 或重启客户端并确认 Runbar 工具可用；Qoder CLI 可执行 `/mcp reload`，客户端仍可能要求启用服务器或批准工具权限。保持 Runbar 运行。重置令牌或修改端口后，重新更新对应 Agent 并重连，不假定旧配置仍有效。

默认文件：Codex `~/.codex/config.toml`、Claude Code `~/.claude.json`、Cursor `~/.cursor/mcp.json`、Qoder CLI `~/.qoder/settings.json`、Qoder CN CLI `~/.qoder-cn/settings.json`、WorkBuddy `~/.workbuddy/mcp.json`。Qoder CLI 与 IDE 配置不同。JSON 配置需无注释和尾逗号；配置格式无法安全处理或有同名冲突时，安装器显示原因并保留原文件，可使用手动配置。

OpenCode 等其他支持 Streamable HTTP 的客户端可用「复制通用 HTTP 配置」，按其实际格式填写地址及 Authorization 请求头。Codex 也可手动合并「复制 Codex 配置」，保留其他设置。需要移除时，在 Runbar 勾选对应 Agent，点击「从所选 Agent 卸载」；服务关闭时仍可卸载，只移除所选文件中的 Runbar 连接，诊断 Skill 单独管理。原配置备份位于 `~/Library/Application Support/FlutterRunbar/mcp-config-backups/`，本次操作结果可在 Finder 中显示备份。

该 Skill 不包含令牌，也不自动改写客户端配置或启动 / 连接业务 App。需要配置变更时按用户本次授权执行；日志和网络结果可能包含账号或凭证，AI 客户端对这些数据的处理遵从该客户端设置。

## 按错误定位

| 现象 | 检查 |
| --- | --- |
| 没有 Runbar 工具 | MCP 配置是否已加入、客户端是否已重连，所用 Runbar 构建是否包含并开启该功能。单独安装 Skill 不会创建连接。 |
| 有日志 / HTTP 工具，没有 WebSocket 工具 | 使用包含 WebSocket MCP 的新版 Runbar，重新连接 MCP 或刷新客户端工具列表。更新 Skill 本身不会给旧服务端增加工具，不将工具缺失解释成没有 WebSocket 流量。 |
| Connection refused / 超时 | Runbar 是否在运行，服务是否开启，地址是否仍是窗口显示值，端口是否占用。其他电脑或云端环境不能直接访问本机回环地址。 |
| HTTP 401 | 连接配置中的访问令牌是否已重置，在 Runbar 重新更新对应 Agent，或重新复制完整配置并手动同步。不使用 OAuth 登录代替本机令牌。 |
| HTTP 403 | 客户端地址 / Host / Origin 是否是正确的本机服务地址；不要为连接外部域名而关闭本机校验。 |
| 正在等待查询结果 | 新版 Runbar 对重查询自动排队，最多 7 个等待、最长等待 30 秒；排队与执行合计仍受 40 秒服务端期限限制。等待期间不要重复提交；来源 / 会话列表不进入重查询队列。 |
| 队列已满 / 排队超时 / 查询超时 | 稍后重试，或减少页大小与筛选范围。不是业务请求失败，不通过并发重复调用绕过限额；旧版 Runbar 的繁忙提示也可按此处理。 |
| 没有网络记录 / 正文不可用 | 查看会话的采集状态和请求的 bodyState，区分未开启、未落盘、未缓存与正文超限；不把缺失当成空响应。 |
| WebSocket available:false / 没有消息 | 确认选中正确的 sessionId，是否为该次运行开启代理抓包，以及消息是否实际通过代理并已保存。WebSocket 使用代理缓存，关联 App 的 DevTools HTTP 采集不自动提供 WebSocket。 |

官方参考：[Codex Skill 安装位置](https://learn.chatgpt.com/docs/build-skills)、[Codex MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)、[Claude Code MCP](https://code.claude.com/docs/en/mcp)、[Cursor MCP](https://prod.cursor.com/help/customization/mcp)、[Qoder CLI MCP](https://docs.qoder.com/cli/mcp-reference)、[Qoder CN CLI 配置](https://docs.qoder.cn/cli/settings-reference)、[WorkBuddy MCP](https://www.codebuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/MCP-Guide)。
