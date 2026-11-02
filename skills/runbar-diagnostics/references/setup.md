# 接入与连接排查

Skill 教 AI 使用 Runbar 工具，不代替 MCP 连接。先在本机 Runbar 开启服务，再由用户配置一次 AI 客户端。

## 安装此 Skill

- 优先使用 Runbar 的「安装 / 更新 AI Skill」向导，勾选 Codex、Claude Code、Qoder、Qoder CN、WorkBuddy、OpenCode 等工具后直接安装，无需复制文件。目录可更改，也可添加其他客户端的 Skill 根目录。
- 新版 Runbar 附带 Skill 更新时，启动检查会提示更新；也可随时在向导点击「检查更新」。版本号和文件指纹一起检查，替换前保留旧版备份，本地手动改过的副本需要用户确认后才替换。同一次更新点「稍后」不会每次启动重复提示。
- 手动安装可在 MCP 窗口「导出 ZIP…」后解压；Codex 当前用户目录是 `~/.agents/skills/`，只给一个源码项目使用时放入项目 `.agents/skills/`，其他客户端按其目录约定安装。
- 文件结构应为 `runbar-diagnostics/SKILL.md`、`agents/openai.yaml` 和 `references/setup.md`，不要多套一层同名目录。安装向导仅管理这个 Skill，不更改其他 Skill 或客户端配置。
- 若客户端没有发现，刷新或重启后再选择。显式调用示例：`使用 $runbar-diagnostics 分析当前项目的最新错误日志和失败请求。`

## 配置连接

1. 使用包含 MCP 功能的 Runbar 构建，打开「设置 → AI 连接（MCP）」并开启；看到服务已开启后继续。
2. 在 Runbar 运行项目或关联 Flutter App，需要查看网络请求时开启对应来源的网络采集。
3. Codex 点击「复制 Codex 配置」，合并到 `~/.codex/config.toml`，保留其他设置。其他支持 Streamable HTTP 的客户端可使用「复制通用 HTTP 配置」，按客户端格式填写地址及 Authorization 请求头。
4. 重连客户端并确认 Runbar MCP 工具可用；保持 Runbar 运行。地址与令牌以该安装的窗口复制值为准，不假定端口未被修改。配置一次即可复用，重置令牌或修改端口后需重新复制配置。

该 Skill 不包含令牌，也不自动改写客户端配置或启动 / 连接业务 App。需要配置变更时按用户本次授权执行；日志和网络结果可能包含账号或凭证，AI 客户端对这些数据的处理遵从该客户端设置。

## 按错误定位

| 现象 | 检查 |
| --- | --- |
| 没有 Runbar 工具 | MCP 配置是否已加入、客户端是否已重连，所用 Runbar 构建是否包含并开启该功能。单独安装 Skill 不会创建连接。 |
| Connection refused / 超时 | Runbar 是否在运行，服务是否开启，地址是否仍是窗口显示值，端口是否占用。其他电脑或云端环境不能直接访问本机回环地址。 |
| HTTP 401 | 连接配置中的访问令牌是否已重置，重新从 Runbar 复制完整配置。不使用 OAuth 登录代替本机令牌。 |
| HTTP 403 | 客户端地址 / Host / Origin 是否是正确的本机服务地址；不要为连接外部域名而关闭本机校验。 |
| 正在等待查询结果 | 新版 Runbar 对重查询自动排队，最多 7 个等待、最长等待 30 秒；排队与执行合计仍受 40 秒服务端期限限制。等待期间不要重复提交；来源 / 会话列表不进入重查询队列。 |
| 队列已满 / 排队超时 / 查询超时 | 稍后重试，或减少页大小与筛选范围。不是业务请求失败，不通过并发重复调用绕过限额；旧版 Runbar 的繁忙提示也可按此处理。 |
| 没有网络记录 / 正文不可用 | 查看会话的采集状态和请求的 bodyState，区分未开启、未落盘、未缓存与正文超限；不把缺失当成空响应。 |

官方参考：[Codex Skill 安装位置](https://learn.chatgpt.com/docs/build-skills)、[Codex MCP 配置](https://developers.openai.com/codex/mcp)。
