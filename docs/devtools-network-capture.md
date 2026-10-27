# DevTools 网络请求采集可行性

结论：可实现独立的网络请求列表与本地缓存。适用对象是启用了 VM Service 和 HTTP profiling 的 Dart / Flutter 调试进程；不需要读取 DevTools 网页。现已接入 Runbar 的「日志 / 网络」面板，支持请求列表、详情、本地历史缓存与基本筛选。原型和正式 Swift 采集器均使用自建回环测试服务验证。

## 数据来源

DevTools Network 使用 Dart VM Service。可以从当前运行输出中的 DevTools URI 取得 VM Service 地址，查询 `getVM` / `getIsolate` 选择支持网络扩展的 isolate，再使用：

- `ext.dart.io.httpEnableTimelineLogging` 查询或开启记录。
- `ext.dart.io.getHttpProfile` 读取请求摘要；`updatedSince` 使用 Unix epoch 微秒，可增量查询更新。
- `ext.dart.io.getHttpProfileRequest` 按请求 ID 读取请求 / 响应正文。

摘要提供方法、URL、开始 / 完成时间、状态码及请求 / 响应信息；详细响应可带正文。方法与字段来自 [Dart VM Service 扩展协议](https://github.com/dart-lang/sdk/blob/main/runtime/vm/service/service_extension.md) 和 [getHttpProfileRequest API](https://api.flutter.dev/flutter/vm_service/DartIOExtension/getHttpProfileRequest.html)。

## 支持范围

- `dart:io` HttpClient 流量，包括通过它发送的 Dio 请求，以及通过 `http_profile` 接入的客户端。可以显示 HTTP / HTTPS 请求；WebSocket / SOCKET 需要分别实现对应的 profiling 扩展，不能把 socket 统计当成完整 HTTP 报文。
- WebView、浏览器和没有接入 profiling 的原生网络库，不保证出现在这套接口中；Flutter Web 应使用浏览器的网络工具。
- 记录开启前未收集的请求无法追溯。如果要覆盖应用启动时的请求，应采用 `--start-paused` 等方式，在恢复运行前开启采集。
- Release / product 进程不应假定有可用的 VM Service，连接前必须检测实际扩展能力。

这些范围与 [Flutter 官方 Network View 文档](https://docs.flutter.dev/tools/devtools/network) 一致。

## 独立原型验证（2026-10-27）

`scripts/probe-devtools-network.dart` 只启动自建 loopback HTTP 服务与测试进程，不连接用户的业务 App。VM Service 保留认证，其地址不会写入原型缓存或输出。

在本机 Flutter 3.47.5 的 Dart 3.13.4 `dartvm` 中验证：

1. 调用扩展开启 HTTP profiling，发送测试 POST 请求。
2. 读取 HTTP 200 状态、请求正文和响应正文，校验测试内容。
3. 再发一个请求，使用前次 profile 的 `timestamp` 做 `updatedSince` 增量读取，确认出现新请求。
4. 写入 JSONL 缓存并读取校验，测试进程退出后文件仍存在。

输出摘要：`requestBodyVerified=true`、`responseBodyVerified=true`、`incrementalReadVerified=true`、`cachedRecords=2`。运行方式：

```sh
/path/to/dart-sdk/bin/dartvm scripts/probe-devtools-network.dart
```

缓存默认位于 `.build/devtools-network-probe/`。本机旧版定制 Dart 3.6.2 的命令行 VM 未提供可启动的 VM Service，因此该二进制未能完成原型；这不等于使用同版 Flutter 引擎的调试 App 不支持采集，实际接入时仍须按运行进程检测能力。

## 已接入的使用方式

在输出区域选择「网络」，勾选「网络采集」。开关按项目保存，默认关闭；支持任意项目类型，按当前运行进程的实际 VM 能力连接。也可在运行开始前，选中一条历史记录的网络页开启开关，供下次运行使用。无需安装额外 Dart SDK 才能运行 Runbar，采集器由 Swift 实现。

- 列表显示毫秒时间、方法、地址、状态和耗时；可按地址字面搜索、方法及状态筛选。每页 100 条，用前后页浏览历史。
- 选中请求查看概览、Headers、Request、Response。宽面板左右分栏，较窄面板上下分栏；正文可选择、复制，并按 128 KB 页面读取。
- 「暂停」仅暂停 Runbar 接收，目标 VM 仍可能记录；继续后按增量游标补采可用数据。关闭项目开关也不修改其他 DevTools 客户端的共享记录开关。
- 首次连接使用 VM 自己的时钟建立游标，并保留 1 秒重叠；从连接附近开始采集，避免拉取 VM 已保留的整份旧历史。请求身份由本次连接代次、isolate、请求 ID 组成，重叠读取更新同一条记录。VM 的 startTime 可能有毫秒抖动，因此优先以 PID 判断 VM 更换；isolate 身份区分热重启。
- 停止运行、切换连接与正常退出会取消并等待旧采集任务，再标记未完成正文并关闭数据库；历史网络数据随整条运行记录保留，也随运行记录一起移到废纸篓。历史 PID / 服务地址不会被用于自动重连。
- 使用 `--start-paused` 启动的程序可在开启采集后，点「恢复程序」继续执行。Runbar 不会自动改写已有运行命令，也不会未经操作恢复调试暂停。

网络页的「… → 清理目标采集缓冲」需要明确确认。这会影响同一个 VM 的 DevTools 记录，并使仍在进行中的请求停止记录；Runbar 本地缓存保留。没有后台自动清理或自动关闭共享 HTTP profiler。

## 本地存储与容量

每次运行的 `network/requests.sqlite` 保存摘要和正文缓存状态，`network/bodies/` 单独保存正文。完成请求由后台限量队列及时取回正文，无需先点开请求。尚未获取、进程已退出、格式不支持、超限和读写失败均有明确状态；不把缺失正文显示为成功缓存的空正文。

默认限制：

| 项目 | 上限 / 行为 |
| --- | --- |
| 摘要 | 50,000 条；数据库最大 8192 页 × 4096 B（32 MiB），达到上限暂停接收 |
| 请求 / 响应正文 | 每个方向各 1 MiB；超限保留摘要并标记正文未缓存 |
| 正文合计 | 每次运行 128 MiB，达到上限继续保存摘要 |
| 单次 VM 返回 | 8 MiB，按传输块检查并在 JSON 解码前中止超限响应 |
| 单批请求 | 2000 条，超限暂停接收并提示 |
| 并发 / 轮询 | 每会话顺序执行，每轮最多取回 8 条正文，约 1 秒刷新；isolate 轮换优先级 |
| 正文预览 | 每页 128 KiB；二进制仅显示本页前 4096 字节十六进制 |

摘要分页、筛选、数据库写入和正文读取均在后台 actor 中执行。SQLite 内存页缓存为 1 MiB，正文不保存在列表数组中；保留量随上述窗口和返回上限受限。进程 RSS 仍包含 AppKit、JSON 对象和系统缓存，不承诺一个固定 RSS 数值。容量按数据库页和正文逻辑字节计算，文件系统元数据、临时事务日志等会另占少量空间。

`updatedSince` 不是服务端分页，也不会清理目标 VM 自己保存的 profile；Runbar 的返回大小限制也不能限制目标 App 的 profiler 内存。长时间、大流量采集需要用户在适当时候清理目标采集缓冲。

只连接运行输出明确公告的回环地址，保留 VM 认证，不跟随重定向，不使用共享 Cookie / 响应缓存。网络目录为当前用户私有，数据库和正文文件权限为 0600。认证服务地址不额外写入网络数据库、请求身份、配置或错误信息；原始运行日志仍按原有规则保存终端输出，可能包含工具自行打印的服务地址。

## 正式接入验证（2026-10-27）

- 完整 Xcode XCTest：121 项，0 失败，其中真实 Dart VM 环境测试默认跳过 1 项。
- 显式指定本机 Dart VM，网络相关 12 项专项全部通过，包含真实 Swift 采集器的回环集成测试：请求 / 响应正文、增量去重、目标进程退出后读取缓存、超限传输取消和重定向拒绝。
- 测试覆盖：VM 时间抖动、重启身份、跨会话事件路由、旧配置兼容、时间排序与字面筛选、10,000 条历史分页、UTF-8 正文分页、正文单项 / 总量限制、崩溃遗留正文计量、数据库容量失败原子回退、取消及未知正文。
- 隔离 HOME、独立 Bundle ID 的原生应用验证：采集到两次真实回环请求并查看响应正文，暂停后缓存数量保持 2，恢复后补采为 3 且无重复；地址筛选、宽 / 窄面板布局、进程结束及重启 Runbar 后读取历史正文均已验证。

以上只使用自建测试程序与回环 HTTP 服务，未连接用户业务 App。Flutter 实际项目的插件差异、WebView / 原生网络库与 WebSocket 不应据此推断为已支持。
