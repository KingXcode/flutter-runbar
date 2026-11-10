import SwiftUI
import RunbarCore

struct SkillInstallationView: View {
    @ObservedObject var installer: SkillInstallationModel
    let onOpenMCP: () -> Void
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "puzzlepiece.extension").font(.title)
                VStack(alignment: .leading, spacing: 3) {
                    Text("安装与更新 Runbar Skill").font(.title2)
                    Text(installer.version.isEmpty ? "正在读取内置 Skill…" : "内置版本 \(installer.version) · 选择要安装的 AI 工具")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if installer.busy { ProgressView().controlSize(.small) }
                Button("检查更新") { Task { await installer.refresh() } }.disabled(installer.busy)
            }
            Text("选择后直接安装到对应工具的 Skill 目录，使用者无需复制文件。新版 Runbar 附带 Skill 更新时，会检查已安装副本并提示更新。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if let error = installer.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(installer.targets) { target in
                        targetRow(target)
                        Divider().padding(.vertical, 8)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 250)
            HStack {
                Button("其他 AI 工具…", action: installer.addTarget).disabled(installer.busy)
                Spacer()
                if let message = installer.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Text("更新前保留旧 Skill 备份；检测到手动修改或其他来源的同名 Skill 时，需勾选「先备份再替换」。Skill 使用 Runbar 数据还需连接 MCP，可在 MCP 窗口选择 Agent 一键安装。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("连接 MCP…", action: onOpenMCP).disabled(installer.installing)
                Spacer()
                Button("稍后") { dismissWindow(id: "skill-installer") }.disabled(installer.installing)
                Button("安装 / 更新所选（\(installer.selection.count)）") { Task { await installer.installSelected() } }
                    .buttonStyle(.borderedProminent).disabled(!installer.canInstall)
            }
        }.padding(22).frame(width: 690, height: 620)
            .task { await installer.refresh() }
    }
    private func targetRow(_ target: SkillAgentTarget) -> some View {
        let state = installer.states[target.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(get: { installer.selection.contains(target.id) }, set: { value in
                    if value { installer.selection.insert(target.id) } else { installer.selection.remove(target.id) }
                })) {
                    Text(target.name).font(.headline)
                }.toggleStyle(.checkbox).disabled(installer.busy || state?.canInstall != true)
                Text(target.detected ? "已发现目录" : "未发现配置，也可安装").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let state {
                    Text(label(state)).font(.caption).foregroundStyle(state.hasUpdate ? Color.orange : state.state == .current ? Color.green : Color.secondary)
                }
                Button("更改目录…") { installer.chooseDirectory(target) }.disabled(installer.busy)
                if target.custom { Button("移除条目") { installer.removeTarget(target) }.disabled(installer.busy) }
            }
            Text(target.root.path + "/" + RunbarSkillPayload.name).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            if let state, [.modified, .unmanaged, .unavailable].contains(state.state) {
                Text(state.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if installer.selection.contains(target.id), state?.requiresReplacementApproval == true {
                Toggle("先备份已有 Skill，再替换为 Runbar 内置版本", isOn: Binding(get: { installer.replaceCustom.contains(target.id) }, set: { value in
                    if value { installer.replaceCustom.insert(target.id) } else { installer.replaceCustom.remove(target.id) }
                })).font(.caption).disabled(installer.busy)
            }
            if let result = installer.outcomes[target.id] {
                HStack {
                    Text(result).font(.caption).textSelection(.enabled)
                    if installer.backups[target.id] != nil { Button("显示旧版备份") { installer.showBackup(target) }.controlSize(.small) }
                }
            }
        }
    }
    private func label(_ state: RunbarSkillInspection) -> String {
        let version = state.installedVersion.map { " " + $0 } ?? ""
        switch state.state {
        case .missing: return "未安装"
        case .current: return "已安装" + version
        case .updateAvailable: return state.installedVersion == installer.version ? "内容有更新" + version : "可更新" + version + " → " + installer.version
        case .modified: return state.hasUpdate ? "有更新 · 本地有修改" : "本地有修改"
        case .unmanaged: return state.hasUpdate ? "可更新" + version + " · 需确认" : "已有同名 Skill" + version
        case .unavailable: return "需处理目录"
        }
    }
}

struct SkillManagementEntry: View {
    @ObservedObject var installer: SkillInstallationModel
    let onOpen: () -> Void
    var body: some View {
        HStack {
            Text("AI 诊断 Skill").font(.headline)
            Spacer()
            if installer.updateCount > 0 { Text("\(installer.updateCount) 处可更新").font(.caption).foregroundStyle(.orange) }
            Button("安装 / 检查更新…", action: onOpen)
        }
    }
}

struct SkillMenuEntry: View {
    @ObservedObject var installer: SkillInstallationModel
    let onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            Label(installer.updateCount > 0 ? "AI Skill · \(installer.updateCount) 处可更新" : "安装 / 更新 AI Skill…", systemImage: "puzzlepiece.extension")
        }.buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 7)
    }
}
