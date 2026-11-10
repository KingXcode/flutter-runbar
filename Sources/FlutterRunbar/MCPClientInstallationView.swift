import SwiftUI
import RunbarCore

struct MCPClientInstallationView: View {
    @ObservedObject var model: MCPClientInstallationModel
    let connection: RunbarMCPConnection?
    let revision: UUID
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("安装到 AI Agent").font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("刷新状态") { Task { await model.refresh(connection: connection) } }.disabled(model.busy)
            }
            Text("勾选 Agent，一键安装、更新或卸载 Runbar MCP。配置位置可更改；使用用户级配置。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(model.targets) { target in
                targetRow(target)
                if target.id != model.targets.last?.id { Divider() }
            }
            HStack {
                Button("安装 / 更新所选（\(model.selection.count)）") { Task { await model.installSelected() } }
                    .buttonStyle(.borderedProminent).disabled(!model.canInstall)
                Button("从所选 Agent 卸载") { Task { await model.uninstallSelected() } }.disabled(!model.canUninstall)
            }
            if connection == nil {
                Text("开启 MCP 服务后可安装或更新；服务关闭时仍可卸载。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("安装及卸载前备份原配置，只管理 Runbar 条目。修改端口或重置令牌后，重新更新所选 Agent 并重连。其他 Agent 可使用下方的手动配置。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.task(id: revision) { await model.refresh(connection: connection) }
    }
    private func targetRow(_ target: MCPClientTarget) -> some View {
        let state = model.states[target.id]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(get: { model.selection.contains(target.id) }, set: { selected in
                    if selected { model.selection.insert(target.id) } else { model.selection.remove(target.id) }
                })) { Text(target.agent.title).font(.callout.weight(.medium)) }
                    .toggleStyle(.checkbox).disabled(model.busy)
                Spacer()
                Text(label(state)).font(.caption).foregroundStyle(color(state))
                Menu {
                    Button("更改配置文件…") { model.chooseFile(target) }
                    if model.hasCustomFile(target) { Button("恢复默认位置") { model.restoreDefaultFile(target) } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
            }
            Text(target.file.path).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if let state, [.conflict, .unavailable].contains(state.state) {
                Text(state.message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let outcome = model.outcomes[target.id] {
                HStack {
                    Text(outcome).font(.caption).textSelection(.enabled)
                    if model.backups[target.id] != nil {
                        Button("显示配置备份") { model.showBackup(target) }.controlSize(.small)
                    }
                }
            }
        }
    }
    private func label(_ state: RunbarMCPInspection?) -> String {
        switch state?.state {
        case .missing: return "未安装"
        case .installed: return "已安装"
        case .needsUpdate: return "配置需更新"
        case .conflict: return "同名配置冲突"
        case .unavailable: return "无法读取配置"
        case nil: return "正在检查…"
        }
    }
    private func color(_ state: RunbarMCPInspection?) -> Color {
        switch state?.state {
        case .installed: return .green
        case .needsUpdate, .conflict, .unavailable: return .orange
        default: return .secondary
        }
    }
}
