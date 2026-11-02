import SwiftUI

struct MCPSettingsView: View {
    @ObservedObject var service: MCPServiceController
    @ObservedObject var installer: SkillInstallationModel
    let onInstallSkill: () -> Void
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.title)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI 连接 · MCP 服务").font(.title2)
                    Text("让 Codex 等 AI 查询 Runbar 已采集的运行数据").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("开启", isOn: Binding(get: { service.enabled }, set: service.setEnabled)).toggleStyle(.switch)
            }
            HStack {
                Circle().fill(service.running ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(service.message).font(.callout)
                if service.starting { ProgressView().controlSize(.small) }
                Spacer()
                if service.enabled && !service.running && !service.starting { Button("重试", action: service.restart) }
            }
            if let error = service.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("本机端口")
                TextField("47821", text: $service.portText).frame(width: 85).textFieldStyle(.roundedBorder)
                    .onSubmit(service.applyPort).disabled(service.starting)
                Button("应用", action: service.applyPort).disabled(service.starting)
                Spacer()
                Button("重置访问令牌", action: service.resetToken).disabled(service.starting)
                    .help("立即使旧配置失效；重置后需要重新复制配置给 AI 客户端。")
            }
            Text(service.address).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Divider()
            Text("可查询的数据").font(.headline)
            Text("项目与关联 App、当前及历史会话、命令与退出状态、Git 分支；日志分页与全文字面搜索；HTTP 请求列表、请求头、请求参数、响应正文及缓存状态。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("只读查询，不启动或停止任务、不清理缓存。日志和正文按页读取，大文件搜索按游标分批继续；未缓存的网络正文会明确标记。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("连接 AI 客户端").font(.headline)
            HStack {
                Button("复制 Codex 配置") { service.copyConfiguration(codex: true) }.disabled(!service.running)
                Button("复制通用 HTTP 配置") { service.copyConfiguration(codex: false) }.disabled(!service.running)
                Spacer()
                Button("复制示例提问", action: service.copyExample)
            }
            Text("Codex：将配置合并到 ~/.codex/config.toml，或在客户端的 MCP 设置中填入地址及 Authorization 请求头，保存后重连。其他客户端选择 Streamable HTTP。Runbar 需要保持运行；云端 AI 无法直接访问本机地址。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let copied = service.copied { Text(copied).font(.caption).foregroundStyle(.secondary) }
            SkillManagementEntry(installer: installer, onOpen: onInstallSkill)
            HStack(alignment: .top) {
                Text("勾选 Codex、Claude Code 等工具即可直接安装或更新。Skill 变化时会提示；MCP 连接仍需配置一次。")
                Spacer()
                Button("导出 ZIP…", action: service.saveSkillPackage).disabled(!service.skillPackageAvailable)
            }
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text("连接配置含访问令牌；日志、请求头和正文可能含账号或凭证，仅提供给你信任的 AI 客户端。令牌保存在本机受限文件中，重启保留；关闭服务立即停止访问。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Text("本次启动已调用 \(service.callCount) 次").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let tool = service.lastCall, let date = service.lastCallAt {
                    Text("\(date.formatted(date: .omitted, time: .standard)) · \(tool)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }.padding(22)
        }.frame(width: 620, height: 600)
    }
}

struct MCPSettingsEntry: View {
    @ObservedObject var service: MCPServiceController
    let onOpen: () -> Void
    var body: some View {
        HStack {
            Text("AI 连接（MCP）").font(.headline)
            Spacer()
            Text(service.running ? "已开启 · 只读" : "未开启").font(.caption).foregroundStyle(.secondary)
            Button("配置…", action: onOpen)
        }
    }
}

struct MCPMenuEntry: View {
    @ObservedObject var service: MCPServiceController
    let onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            Label(service.running ? "AI 连接（MCP）· 已开启" : "AI 连接（MCP）…", systemImage: "point.3.connected.trianglepath.dotted")
        }.buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 7)
    }
}
