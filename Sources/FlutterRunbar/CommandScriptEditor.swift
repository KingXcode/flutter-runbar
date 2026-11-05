import AppKit
import SwiftUI
import RunbarCore

struct CommandScriptEditor: NSViewRepresentable {
    @Binding var text: String
    let workflow: CommandWorkflow
    let enableVariables: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.widthTracksTextView = true

        let editor = ScriptTextView(frame: .zero, textContainer: container)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 2, height: 4)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text
        editor.delegate = context.coordinator
        editor.onBackslash = { [weak coordinator = context.coordinator] in coordinator?.showSuggestions() }
        editor.onKey = { [weak coordinator = context.coordinator] event in coordinator?.handleKey(event) == true }
        editor.onBlur = { [weak coordinator = context.coordinator] in coordinator?.dismissSuggestions() }

        let scroll = ScriptScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        context.coordinator.editor = editor
        context.coordinator.updateColors()
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let variablesChanged = coordinator.parent.workflow.variableNames != workflow.variableNames ||
            coordinator.parent.workflow.expandVariables != workflow.expandVariables
        coordinator.parent = self
        guard let editor = coordinator.editor else { return }
        if editor.string != text {
            coordinator.dismissSuggestions()
            let location = min(editor.selectedRange().location, text.utf16.count)
            editor.string = text
            editor.setSelectedRange(NSRange(location: location, length: 0))
            coordinator.updateColors()
        } else if variablesChanged {
            coordinator.dismissSuggestions()
            coordinator.updateColors()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.dismissSuggestions()
        coordinator.editor?.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandScriptEditor
        fileprivate weak var editor: ScriptTextView?
        private var panel: SuggestionPanel?
        private var outsideClick: Any?
        private var trigger: NSRange?
        private var choices: [VariableChoice] = []
        private let selection = VariableSelection()

        init(_ parent: CommandScriptEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            dismissSuggestions()
            parent.text = editor.string
            updateColors()
        }

        func updateColors() {
            guard let editor, let layout = editor.layoutManager else { return }
            let length = editor.string.utf16.count
            guard length > 0 else { return }
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
            for match in parent.workflow.recognizedPlaceholders(in: editor.string) {
                layout.addTemporaryAttribute(.foregroundColor, value: VariableChoice.color(system: match.system),
                                             forCharacterRange: match.range)
            }
        }

        func showSuggestions() {
            guard let editor, let window = editor.window else { return }
            let caret = editor.selectedRange()
            let text = editor.string as NSString
            guard caret.length == 0, caret.location > 0, caret.location <= text.length,
                  text.character(at: caret.location - 1) == 92 else { return }
            let index = caret.location - 1
            guard index == 0 || text.character(at: index - 1) != 92 else { return }
            dismissSuggestions()
            trigger = NSRange(location: index, length: 1)
            choices = parent.workflow.variableNames.map { VariableChoice(name: $0, system: false) } +
                CommandWorkflow.systemVariables.map { VariableChoice(name: $0, system: true) }
            selection.index = nil

            let anchor = editor.firstRect(forCharacterRange: caret, actualRange: nil)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? window.screen else { return }
            let bounds = screen.visibleFrame
            let width = min(310, bounds.width)
            let height = min(295, bounds.height)
            let x = min(max(anchor.minX, bounds.minX), bounds.maxX - width)
            let below = anchor.minY - height - 5
            let y = below >= bounds.minY ? below : min(anchor.maxY + 5, bounds.maxY - height)
            let popup = SuggestionPanel(contentRect: NSRect(x: x, y: y, width: width, height: height),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            popup.isReleasedWhenClosed = false
            popup.isOpaque = false
            popup.backgroundColor = .clear
            popup.hasShadow = true
            popup.hidesOnDeactivate = true
            popup.worksWhenModal = true
            popup.contentView = SuggestionHostingView(rootView: VariableSuggestions(choices: choices, selection: selection) { [weak self] in
                self?.insertChoice(at: $0)
            })
            panel = popup
            window.addChildWindow(popup, ordered: .above)
            popup.orderFront(nil)
            outsideClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
                if let self, event.window !== self.panel { self.dismissSuggestions() }
                return event
            }
        }

        func handleKey(_ event: NSEvent) -> Bool {
            guard panel != nil else { return false }
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                switch event.keyCode {
                case 53:
                    dismissSuggestions()
                    return true
                case 125, 126:
                    let delta = event.keyCode == 125 ? 1 : -1
                    let start = selection.index ?? (delta == 1 ? -1 : choices.count)
                    selection.index = min(max(start + delta, 0), choices.count - 1)
                    return true
                case 36, 48, 76:
                    if let index = selection.index {
                        insertChoice(at: index)
                        return true
                    }
                default: break
                }
            }
            // Return and ordinary typing keep the literal backslash unless a
            // suggestion was selected, including a shell line continuation.
            dismissSuggestions()
            return false
        }

        private func insertChoice(at index: Int) {
            guard choices.indices.contains(index), let editor, let trigger else { return }
            let text = editor.string as NSString
            let value = choices[index].placeholder
            dismissSuggestions()
            guard NSMaxRange(trigger) <= text.length, text.substring(with: trigger) == "\\" else { return }
            parent.enableVariables()
            editor.insertText(value, replacementRange: trigger)
        }

        func dismissSuggestions() {
            if let outsideClick { NSEvent.removeMonitor(outsideClick) }
            outsideClick = nil
            trigger = nil
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.close()
            }
            panel = nil
        }
    }
}

private final class ScriptScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView else { return }
        let minimum = NSSize(width: 0, height: contentSize.height)
        if editor.minSize != minimum { editor.minSize = minimum }
        let size = NSSize(width: contentSize.width, height: max(editor.frame.height, minimum.height))
        if editor.frame.size != size { editor.setFrameSize(size) }
    }
}

private final class ScriptTextView: NSTextView {
    var onBackslash: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onBlur: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        let backslash = event.characters == "\\" && !event.isARepeat &&
            event.modifierFlags.intersection([.command, .control]).isEmpty
        super.keyDown(with: event)
        if backslash, !hasMarkedText() { onBackslash?() }
    }

    override func resignFirstResponder() -> Bool {
        onBlur?()
        return super.resignFirstResponder()
    }
}

private final class SuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SuggestionHostingView: NSHostingView<VariableSuggestions> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct VariableChoice {
    let name: String
    let system: Bool
    var placeholder: String { "{{\(name)}}" }
    static func color(system: Bool) -> NSColor { system ? .systemPurple : .systemBlue }
}

private final class VariableSelection: ObservableObject {
    @Published var index: Int?
}

private struct VariableSuggestions: View {
    let choices: [VariableChoice]
    @ObservedObject var selection: VariableSelection
    let onChoose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(choices.indices, id: \.self) { index in
                            let choice = choices[index]
                            if index == 0 || choice.system != choices[index - 1].system {
                                Text(choice.system ? "系统变量" : "环境变量")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 7).padding(.top, 4)
                            }
                            Button { onChoose(index) } label: {
                                Text(choice.placeholder)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(Color(nsColor: VariableChoice.color(system: choice.system)))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(selection.index == index ? Color.accentColor.opacity(0.16) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 4))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(index)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: selection.index) { _, index in
                    if let index { reader.scrollTo(index) }
                }
            }
            Text("方向键选择，回车插入，Esc 关闭")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 7)
        }.padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
