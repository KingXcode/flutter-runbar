import AppKit
import SwiftUI

struct CurlTextEditor: NSViewRepresentable {
    struct Jump: Equatable {
        let id = UUID()
        let offset: Int
    }

    @Binding var text: String
    @Binding var caret: Int
    let jump: Jump?
    let maximumBytes: Int
    let onLimit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 9, height: 9)
        editor.setAccessibilityLabel("cURL 请求编辑区")
        editor.string = text
        editor.delegate = context.coordinator
        context.coordinator.highlight(editor)
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.updating = true
        defer { coordinator.updating = false }
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(caret, text.utf16.count), length: 0))
            coordinator.highlight(editor)
        }
        if let jump, coordinator.jump != jump {
            coordinator.jump = jump
            let range = NSRange(location: min(jump.offset, text.utf16.count), length: 0)
            editor.setSelectedRange(range)
            editor.scrollRangeToVisible(range)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CurlTextEditor
        var jump: Jump?
        var updating = false
        private static let comments = try! NSRegularExpression(pattern: #"(?m)^\h*(?:#|//).*"#)
        private static let verbs = try! NSRegularExpression(pattern: #"(?m)^\h*(?:curl|GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS)\b"#)
        init(_ parent: CurlTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            parent.caret = editor.selectedRange().location
            highlight(editor)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            parent.caret = editor.selectedRange().location
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            let old = (textView.string as NSString).substring(with: range)
            if textView.string.utf8.count - old.utf8.count + replacementString.utf8.count > parent.maximumBytes {
                parent.onLimit(); return false
            }
            return true
        }
        func highlight(_ editor: NSTextView) {
            guard let layout = editor.layoutManager else { return }
            let range = NSRange(location: 0, length: editor.string.utf16.count)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            for (pattern, color) in [(Self.comments, NSColor.secondaryLabelColor), (Self.verbs, NSColor.systemBlue)] {
                for match in pattern.matches(in: editor.string, range: range) {
                    layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: match.range)
                }
            }
        }
    }
}
