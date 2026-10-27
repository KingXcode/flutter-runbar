import SwiftUI
import RunbarCore

/// The sheet owns a complete immutable request. Using an item avoids the first
/// presentation capturing stale values from several separately updated states.
struct CommandEditorRequest: Identifiable {
    let id = UUID()
    let project: Project
    let preset: CommandPreset?
    let templates: [CommandTemplate]
    init(project: Project, preset: CommandPreset? = nil) {
        self.project = project; self.preset = preset
        templates = preset == nil ? CommandTemplate.templates(for: project) : []
    }
}

struct CommandEditorView: View {
    @ObservedObject var model: AppModel
    let request: CommandEditorRequest
    @Environment(\.dismiss) private var dismiss
    @State private var presetName: String
    @State private var command: String
    @State private var templateID: String?
    @State private var useFVM: Bool
    @State private var flutterRunMode: FlutterRunMode = .debug
    @State private var editorError: String?
    private let templates: [CommandTemplate]

    init(model: AppModel, request: CommandEditorRequest) {
        self.model = model; self.request = request
        let templates = request.templates
        self.templates = templates
        _presetName = State(initialValue: request.preset?.name ?? "")
        _command = State(initialValue: request.preset?.command ?? "")
        _templateID = State(initialValue: templates.first?.id)
        _useFVM = State(initialValue: request.project.kind == .flutter)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(request.preset == nil ? "添加命令" : "编辑命令").font(.title2)
                    if request.preset == nil { templatePicker }
                    TextField("名称", text: $presetName)
                    TextEditor(text: $command).font(.system(.body, design: .monospaced)).frame(height: 120)
                    Text("命令由登录 zsh 执行，支持参数、引号与管道。只保存你信任的命令，它拥有你当前用户的权限。运行输出永远不会作为命令执行。不要使用后台化或守护进程命令。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let editorError {
                        Text(editorError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: request.preset == nil ? 420 : 280)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    if model.savePreset(name: presetName, command: command, id: request.preset?.id, projectID: request.project.id) { dismiss() }
                    else { editorError = model.error ?? "项目正在运行或不可用，暂时无法保存。"; model.error = nil }
                }.disabled(presetName.isEmpty || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 520)
    }

    @ViewBuilder
    private var templatePicker: some View {
        if templates.isEmpty {
            Text("此项目没有预设模板，请直接填写自定义命令。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("常用模板", selection: $templateID) {
                        ForEach(templates) { template in Text(template.name).tag(Optional(template.id)) }
                    }
                    if templates.first(where: { $0.id == templateID })?.supportsFVM == true {
                        Toggle("使用 FVM", isOn: $useFVM).fixedSize()
                    }
                }
                if let template = templates.first(where: { $0.id == templateID }) {
                    if template.supportsFlutterRunMode {
                        Picker("运行模式", selection: $flutterRunMode) {
                            ForEach(FlutterRunMode.allCases) { mode in Text(mode.name).tag(mode) }
                        }.pickerStyle(.segmented).accessibilityLabel("Flutter 运行模式")
                    }
                    Text(template.command(useFVM: useFVM, runMode: flutterRunMode)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text(template.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("填入下方编辑区") {
                        presetName = template.presetName(runMode: flutterRunMode)
                        command = template.command(useFVM: useFVM, runMode: flutterRunMode)
                    }.help("替换下方草稿，不保存也不执行；可继续编辑")
                }
                Text("模板仅供选择和编辑，保存后仍需手动运行；所需工具链请自行安装。")
                    .font(.caption2).foregroundStyle(.secondary)
                Divider()
            }
        }
    }

}
