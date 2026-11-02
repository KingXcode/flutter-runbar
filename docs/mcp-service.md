# Runbar 本机 MCP 服务

Runbar 可以作为只读的 MCP 服务，让 Codex 等本机 AI 客户端查询正在运行的项目、已关联的 Flutter App，以及保存在 Runbar 中的日志和 HTTP 网络缓存。服务不需要业务 App 修改代码，也不需要额外安装 Node.js、Python、Flutter 或 MCP 扩展。

## 开启与连接

1. 在 Runbar 应用菜单、菜单栏面板或设置中打开「AI 连接（MCP）」。首次默认关闭，点击「开启」。开启状态和端口会记住，下次启动 Runbar 自动恢复。
2. 默认地址是 `http://127.0.0.1:47821/mcp`。端口被占用时可填写 1024–65535 的其他端口并点「应用」，然后重新复制客户端配置。
3. 点击「复制 Codex 配置」，将配置合并到 `~/.codex/config.toml`，不要覆盖文件中其他设置；也可在支持相应字段的客户端 MCP 设置中填入地址和 Authorization 请求头。保存后按客户端要求重连或重启。
4. Cursor / Claude Code 等支持 Streamable HTTP 的客户端可以使用「复制通用 HTTP 配置」；各客户端的外层配置格式可能不同，关键参数是 HTTP 地址和 `Authorization: Bearer <访问令牌>`。
5. 保持 Runbar 运行。在 AI 中说明要使用 Runbar MCP 查询哪个项目或 App，必要时允许该客户端的工具读取权限。

Codex 配置示例（令牌以窗口复制的实际值为准）：

```toml
[mcp_servers.runbar]
url = "http://127.0.0.1:47821/mcp"
http_headers = { Authorization = "Bearer <Runbar 中复制的访问令牌>" }
tool_timeout_sec = 45
```

通用 HTTP 配置示例：

```json
{
  "mcpServers": {
    "runbar": {
      "type": "http",
      "url": "http://127.0.0.1:47821/mcp",
      "headers": { "Authorization": "Bearer <Runbar 中复制的访问令牌>" }
    }
  }
}
```

不自动写入 AI 客户端的全局配置。仅支持本机可访问的客户端；云端 AI 服务、其他电脑和某些隔离环境不能直接访问这个回环地址。只支持 HTTP 的客户端无需 stdio 启动命令；仅支持 stdio 的客户端需要自行使用兼容的 HTTP 桥接器。

## 可选：安装 Runbar 诊断 Skill

MCP 提供可查询的数据，`runbar-diagnostics` Skill 提供如何组合这些查询来诊断问题的工作方法。

1. 首次打开带有此功能的 Runbar 会显示「安装与更新 Runbar Skill」向导；也可从应用菜单、菜单栏、设置或 MCP 窗口的「安装 / 检查更新…」打开。可以选择「稍后」。
2. 勾选需要安装的 AI 工具，核对各行显示的安装目录，点击「安装 / 更新所选」。向导列出 Codex、Claude Code、Qoder、Qoder CN、WorkBuddy 和 OpenCode，默认勾选已发现配置目录且需要安装 / 更新的项目；这只是目录检测，不表示客户端正在运行。未发现配置也可手动勾选。
3. 目录不符时点击「更改目录…」，也可用「其他 AI 工具…」添加客户端或项目专用的 Skill 根目录。选择存放各个 Skill 的上一级目录，向导会创建其中的 `runbar-diagnostics` 文件夹。已选路径会记住；移除自定义条目只移除管理项，不删除已安装文件。
4. 安装后按 AI 客户端要求刷新 Skill、重开会话或重启客户端。默认允许根据请求自动选用，也可在支持该写法的客户端使用 `$runbar-diagnostics`；不同客户端的显式调用方式以其文档为准。
5. Skill 安装不要求先开启 MCP。完成上面的 MCP 连接配置并保持 Runbar 运行，然后提问：

> 使用 $runbar-diagnostics 查看当前项目最新的错误日志和失败请求，结合请求参数与响应正文定位原因。

Skill 指导 AI 选择正确来源与运行会话、按游标续查日志、区分网络失败类别、按页读取正文，并明确证据覆盖范围。它不会自动安装 MCP 或替代访问令牌；未连接时会引导连接，不会假装已经读取运行数据。

默认用户目录如下，均可在向导中修改；项目专用安装可另外添加项目的 Skill 目录。

| AI 工具 | 默认 Skill 根目录 |
| --- | --- |
| Codex | `~/.agents/skills/`；发现已有 `~/.codex/skills/runbar-diagnostics` 时额外列出兼容目录，不为新用户创建第二份。 |
| Claude Code | `~/.claude/skills/`；不等同于网页 Claude。 |
| Qoder | `~/.qoder/skills/` |
| Qoder CN | `~/.qoder-cn/skills/` |
| WorkBuddy | `~/.workbuddy/skills/` |
| OpenCode | `~/.config/opencode/skills/`；Runbar 进程环境中设置了绝对路径 `XDG_CONFIG_HOME` 时使用其中的 `opencode/skills/`。 |

Qoder CN 与 WorkBuddy 的默认目录依据本机安装及客户端资源核对，未在所有客户端版本中做加载验收。客户端设置、配置档案、环境变量或同步方式不同时，以其实际 Skill 目录为准；多个工具指向同一个实际目录时只写一次。

### 检查与更新已安装 Skill

- 向导的「检查更新」将已安装文件与当前 Runbar 内置 Skill 比较，显示版本和「未安装 / 已安装 / 可更新 / 本地有修改」状态。检查不联网，也不会直接修改文件；Skill 随新版 Runbar 分发，本版不独立从 GitHub 下载 Skill。
- 内置 `manifest.json` 记录版本及三个文件的 SHA-256 指纹。安装后写入本 Skill 目录中的 `.runbar-install.json`，记录安装版本和文件指纹；后续即使版本号未变，只要内置内容变化也能发现更新。其他来源的副本若没有有效安装记录，无法可靠区分所有定制内容，默认保留，需用户明确确认才能替换。较新的已安装版本不会默认降级。
- 首次使用提示安装；此后在 Runbar 启动时检查，内置 Skill 内容变化且发现已安装旧副本时提示更新。同一内容版本无论选择「稍后」还是关闭窗口都不反复弹；仍可随时手动检查。未安装 Skill 且已跳过首次向导时，不会因为每次 Runbar 更新重复要求安装。
- 每次替换先把完整旧目录保留到 `~/Library/Application Support/FlutterRunbar/skill-backups/<随机编号>/runbar-diagnostics/`，位于 AI 工具扫描目录之外。向导本次安装结果提供「显示旧版备份」；之后也可从上述目录找回。检测到手动改动、附加文件或其他来源同名 Skill 时，必须勾选「先备份已有 Skill，再替换为 Runbar 内置版本」。旧版备份不自动清理。
- 安装先在临时目录写入并校验，普通替换失败时尝试恢复原副本并显示错误；如果恢复失败会给出备份位置。目录权限、符号链接或路径冲突会提示原因。只管理本 Skill，不删除其他 Skill、不修改 MCP / AI 配置、不启动客户端；文件写入期间正常退出 Runbar 会暂缓。

### 导出与维护

需要手动安装到其他环境时，MCP 窗口保留「导出 ZIP…」。解压后将整个 `runbar-diagnostics` 放到目标 Skill 目录，不要多套一层同名文件夹。ZIP 仅包含公开说明和元数据，不含令牌、用户配置、日志或网络记录。

Skill 源码位于 `skills/runbar-diagnostics/`，修改时应同步提升 `SKILL.md` 中的 `metadata.version`。`scripts/package-mcp-skill.py` 按白名单只打包 `SKILL.md`、`agents/openai.yaml` 和 `references/setup.md`，同时生成带版本 / 文件指纹清单的展开资源供向导安装。Xcode 构建将 ZIP 和展开资源放入 App 的 `Contents/Resources/Skills/`；签名 App / DMG 包含同一份资源。本地单独运行脚本输出到 `dist/skills/`，不从用户的技能目录收集文件。

目录与调用方式参考：[Codex](https://learn.chatgpt.com/docs/build-skills)、[Claude Code](https://code.claude.com/docs/en/skills)、[Qoder](https://docs.qoder.com/cli/Skills)、[OpenCode](https://opencode.ai/docs/skills/)、[WorkBuddy](https://www.codebuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Skills-Market)。

## AI 能查询什么

所有工具都标记 `readOnlyHint=true`，不提供运行命令、停止项目、热更新、清缓存、连接 App 或启用网络采集的操作。查询不会改变 Runbar 当前选中的项目、日志位置、搜索条件或网络页面。

| 工具 | 内容及分页方式 |
| --- | --- |
| `runbar_list_sources` | 项目 / 关联 App 的 sourceId、名称、路径、类型、Git 分支和当前 sessionId；`offset` / `limit` 分页，默认 50 项，最多 100 项。 |
| `runbar_list_sessions` | 当前 / 历史会话，含命令摘要、状态、开始 / 结束时间、退出码、来源和是否仍在运行；可按 `sourceId`、`runningOnly` 筛选，默认 30 项，最多 100 项，按开始时间倒序。 |
| `runbar_get_session` | 指定 `sessionId` 的运行详情、命令（最多 16384 字符）、错误、运行阶段、可用的 PID、日志大小、网络采集状态及请求总数。缺失的字段返回 null，不从历史 PID 猜测当前进程。 |
| `runbar_read_logs` | 指定会话的日志窗口，默认最新 32 KiB，最多 64 KiB；`position` 为 latest / first / after / before / around。返回原始字节的 startOffset / endOffset / nextOffset / previousOffset 以及全文 totalBytes。 |
| `runbar_search_logs` | 对原始日志执行区分大小写的 UTF-8 字面搜索，返回命中字节位置和附近上下文；默认 20 个命中、最多 50 个。每次最多扫描 8 MiB，按 `nextOffset` 继续，直到 `complete=true`。不支持正则，不把单次扫描的命中数称作全文总数。 |
| `runbar_list_network_requests` | 指定会话的 HTTP 请求摘要，按时间从旧到新。可同时按 URL、请求 / 响应头、请求参数、响应正文关键词、排除关键词、方法及状态过滤；默认 30 项，最多 100 项。 |
| `runbar_get_network_request` | 指定 `sessionId` + `requestId` 的完整 URL、请求 / 响应头、时间、状态、耗时、大小、错误和正文缓存状态。列表过长的 URL 仅展示前 2048 字符，详情可读取完整 URL。 |
| `runbar_read_network_body` | 指定会话 / 请求的 request 或 response 正文；默认 raw，可选 json / xml，每页 32 KiB，按 nextPage 继续。文本为 UTF-8，二进制原始页以 base64 返回并标明 encoding。 |

建议先查询来源、再查运行中的会话，从返回的 ID 继续查询。所有时间使用带时区的 ISO 8601 字符串；日志的 offset 始终是原始文件字节位置，不是字符或行号。命令摘要 / URL 有截断时会返回相应标记。

读取更多日志：`position:"after", offset:<上一次的 endOffset>`；向前读取：`position:"before", offset:<上一次的 startOffset>`。日志仍在增长时，可稍后继续从 endOffset 读取；如果尾部还有未写完的 UTF-8 字符，等待后续输出后再读。

日志搜索针对原始字节匹配，返回上下文会移除 ANSI 控制符；如果关键词被 ANSI 颜色序列分开，原始字面搜索不会跨控制序列拼接匹配。搜索结果的 `offset` 可配合 `runbar_read_logs` 的 around 定位，不会改变日志页面当前显示的位置。

### 网络筛选示例

```json
{
  "sessionId": "从会话列表取得的 UUID",
  "url": ["/login", "/session"],
  "headers": ["application/json"],
  "request": ["username"],
  "response": ["error", "failed"],
  "exclude": ["heartbeat", "keepalive"],
  "method": "POST",
  "offset": 0,
  "limit": 30
}
```

同一字段的包含关键词满足任一个即可，不同字段需同时满足，随后排除全字段命中 exclude 的记录。正文 / 请求头筛选使用已经缓存的内容；内容索引未扫描完成时返回 `matchingIsComplete:false`，此时 matching 是当前已发现数量，保持相同筛选条件和 offset 再查询即可继续。查询复杂内容时请顺序调用，避免不断切换条件导致临时索引重建。

正文 pending / omitted / failed / unavailable 会返回实际状态及原因，MCP 不会为查询触发目标 App 重新请求或补采。对未缓存正文无法判断的过滤条件，不会宣称已经匹配所有历史请求。原缓存单条大小限制、缺失或采集结束前尚未写入的数据边界继续有效。

JSON / XML 格式错误会返回工具错误，可以改用 raw；XML 禁用 DTD 和外部实体。文本分页不会切断 UTF-8 字符，逐页拼接即可恢复完整的缓存文本。每次格式化最多读取 1 MiB 原始正文，格式化结果最多 4 MiB；更大的原始文件以 raw/base64 分页读取。

## 示例提问

> 使用 Runbar MCP 找出 flutter-pc 当前的运行会话，查看最近的错误日志和失败的 POST 请求，读取相关请求头、请求参数和响应正文后分析原因。只分析，不执行命令。

> 使用 Runbar MCP 在当前会话的完整日志里查找 “SocketException”，按 nextOffset 继续扫描到 complete=true，再结合前后日志分析。

查询按需读取本地文件，通常能看到请求时刻已经落盘的数据；日志写入和网络缓存存在正常的短暂延迟。关联 Flutter App 的数据范围仍取决于既有 VM Service 日志订阅及 HTTP profiling 能力；WebView、WebSocket、Flutter Web、未开启采集或无法调试的 Release App 不会因开启 MCP 而增加可见数据。

## 开关、访问控制与资源上限

- 服务只绑定 `127.0.0.1`，校验 Host / Origin，要求随机生成的 256 位 bearer 令牌。令牌不放在 URL 中，也不写入运行日志或安装包；保存在应用支持目录独立的 `mcp/access-token` 文件，目录权限 0700、文件权限 0600，重启和替换 App 后继续使用。
- 复制连接配置会把令牌写入系统剪贴板，配置文件也包含令牌。只交给信任的 AI 客户端，避免把配置提交到源码库。点击「重置访问令牌」后旧配置立即失效，需要重新复制并重连；关闭服务立即停止访问，退出 Runbar 也停止监听。
- 启用即允许持有令牌的本机客户端读取全部 Runbar 记录；本版不按客户端或项目分别授权。日志、命令、请求头和正文可能包含账号、业务内容或访问凭据。AI 客户端可能将读取结果发送到其模型服务，遵循该客户端的数据设置；Runbar 不自动发起模型请求或上传记录。
- 最多 8 个同时进行的 HTTP 连接，每个请求最多 64 KiB、响应最多 2 MiB；读取请求和发送响应各有 10 秒超时，HTTP 查询等待有 40 秒上限，MCP 专用 SQLite 读取设置 30 秒截止并可协作取消。日志、网络等重查询一次只执行一个，其他请求自动按进入队列顺序等待，最多 7 个等待项、最长等待 30 秒；前一个成功、失败或取消并释放执行位置后自动执行下一个。普通排队不再要求 AI 手动重试，队列已满或等候超时才返回明确错误。排队时间计入原有 40 秒总期限，不会额外延长；客户端的工具超时应覆盖服务端处理时间。
- 排队采用异步挂起，不轮询等待，也不在等待期间打开缓存、提前加载正文或保留查询结果。任务取消会移出等待队列；连接失败和服务端请求截止会取消对应工作任务，关闭服务或退出 Runbar 会结束全部等待项。来源列表与会话列表不进入重查询队列，但仍受 HTTP 连接总数限制。此队列只调度查询，不提供每个 AI 会话独立的正文筛选索引；来回切换条件仍可能重建该索引。
- 日志搜索按 64 KiB 分块，单次最多扫描 8 MiB；日志窗口最多 64 KiB；网络列表只保留最多 256 条附近摘要，正文 32 KiB 分页，SQLite 页缓存维持原来的上限。MCP 另有临时内容搜索索引，与 UI 的筛选和选择相互独立；关闭服务会清理该索引。
- 仅能使用已知会话 ID / 请求 ID，不接受任意文件路径，读取时拒绝符号链接重定向。返回的数据是待分析内容，不是对 AI 的指令。
- MCP 设置窗口显示累计工具调用数、最近调用的工具与时间，不记录查询参数或返回正文。

## 协议与验证边界

实现 MCP Streamable HTTP 的无状态 JSON 请求 / 响应模式，可协商 2025-11-25、2025-06-18、2025-03-26 协议；GET 返回 405，不提供 SSE 主动推送、资源订阅或 OAuth 登录。客户端通过轮询游标读取新增输出；返回 HTTP 401 时检查令牌和配置，不能通过 MCP OAuth 登录取得这个本机令牌。

回归用例覆盖协议握手、只读工具标记、请求大小、鉴权 / Host / Origin、HTTP 分帧、日志分块搜索与游标、正文分页、缓存保持及路径隔离。按当前用户要求只编译 App 与测试目标，不运行额外测试、真实业务 App 或 AI 客户端联调；编译结果不等同于已经通过 Codex / 其他客户端的运行验收。

参考：[MCP 传输规范](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)、[MCP 工具规范](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)、[Codex MCP 配置](https://developers.openai.com/codex/mcp)。
