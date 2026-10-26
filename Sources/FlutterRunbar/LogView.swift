import AppKit
import SwiftUI
import RunbarCore

/// One bounded TextKit document plus a separate, whole-file byte scrollbar.
struct LogView: NSViewRepresentable {
    var page: LogFilePage?
    var totalBytes: UInt64
    var wrapsLines: Bool
    var scrollRevision: Int
    var placement: LogScrollPlacement
    var followsOutput: Bool
    var loading: Bool
    var onScrollAway: () -> Void
    var onLoadWindow: (UInt64) -> Void
    var onSeek: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> LogViewport {
        let host = LogViewport()
        let coordinator = context.coordinator
        coordinator.host = host
        host.onLayout = { [weak coordinator] in coordinator?.settleLayout() }
        host.scroll.onScrolled = { [weak coordinator] delta in coordinator?.userScrolled(delta) }
        host.text.onNavigation = { [weak coordinator] key, command in coordinator?.navigate(key, command: command) }
        host.bar.onSeek = { [weak coordinator] value in coordinator?.seek(value) }
        host.scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: host.scroll.contentView, queue: .main
        ) { [weak coordinator] _ in coordinator?.clipChanged() }
        return host
    }
    func updateNSView(_ host: LogViewport, context: Context) {
        let coordinator = context.coordinator
        let text = page?.text ?? ""
        let view = host.text
        coordinator.parent = self
        coordinator.updating = true
        defer { coordinator.updating = false; coordinator.settleLayout() }
        if coordinator.wasLoading && !loading { coordinator.pendingWindow = false }
        coordinator.wasLoading = loading
        let newNavigation = coordinator.revision != scrollRevision
        let x = host.scroll.contentView.bounds.origin.x
        let oldY = host.scroll.contentView.bounds.origin.y
        var anchorDelta: CGFloat = 0
        if newNavigation, placement == .preserveAnchor, let anchor = page?.anchorByteOffset, let old = coordinator.page {
            if anchor == old.startOffset { anchorDelta = oldY - host.characterY(0) }
            else if anchor == old.endOffset { anchorDelta = oldY - host.characterY(coordinator.text.utf16.count) }
        }
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        if coordinator.wrapsLines != wrapsLines {
            coordinator.wrapsLines = wrapsLines
            host.scroll.hasHorizontalScroller = !wrapsLines
            view.isHorizontallyResizable = !wrapsLines
            view.autoresizingMask = wrapsLines ? [.width] : []
            view.textContainer?.widthTracksTextView = wrapsLines
            view.textContainer?.containerSize = NSSize(width: wrapsLines ? host.scroll.contentSize.width : CGFloat.greatestFiniteMagnitude,
                                                      height: CGFloat.greatestFiniteMagnitude)
            if wrapsLines { view.setFrameSize(NSSize(width: host.scroll.contentSize.width, height: view.frame.height)) }
            host.needsLayout = true
        }
        if coordinator.text != text {
            if !coordinator.text.isEmpty, text.hasPrefix(coordinator.text) {
                view.textStorage?.append(NSAttributedString(string: String(text.dropFirst(coordinator.text.count)), attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor
                ]))
            } else { view.string = text }
            coordinator.text = text
        }
        coordinator.page = page
        if page == nil {
            coordinator.pendingSeek = nil; coordinator.pendingWindow = false
            host.bar.setProgress(0, proportion: 1)
        }
        if newNavigation {
            coordinator.revision = scrollRevision
            coordinator.pendingWindow = false; coordinator.pendingSeek = nil
            coordinator.navigation = (placement, anchorDelta, x)
        }
    }

    final class Coordinator {
        weak var host: LogViewport?
        var parent: LogView?
        var page: LogFilePage?
        var text = ""
        var wrapsLines: Bool?
        var revision = -1
        var updating = false
        var wasLoading = false
        var pendingWindow = false
        var pendingSeek: Double?
        var lastY: CGFloat = 0
        var lastDocumentHeight: CGFloat?
        var lastViewportSize: NSSize?
        var navigation: (placement: LogScrollPlacement, anchorDelta: CGFloat, x: CGFloat)?
        var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func settleLayout() {
            guard !updating, let host, let parent, host.scroll.contentSize.width > 20, host.scroll.contentSize.height > 0 else { return }
            updating = true
            host.prepareDocument(wraps: parent.wrapsLines)
            if let navigation {
                self.navigation = nil
                switch navigation.placement {
                case .start: host.scrollTo(y: 0, x: 0)
                case .end: host.scrollToEnd(x: 0)
                case .anchor, .preserveAnchor:
                    host.scrollTo(y: host.characterY(page?.anchorUTF16Offset ?? 0) + navigation.anchorDelta, x: navigation.x)
                }
            } else if parent.followsOutput { host.scrollToEnd(x: host.scroll.contentView.bounds.origin.x) }
            updating = false
            updateProgress()
        }

        func updateProgress() {
            guard !updating, pendingSeek == nil, let host, let parent, let page else { return }
            updating = true
            defer { updating = false }
            let height = max(1, host.text.bounds.height)
            let visible = host.scroll.contentView.bounds.height
            let y = host.scroll.contentView.bounds.origin.y
            let range = host.visibleByteFractions(in: text)
            let metrics = LogScrollMetrics(start: page.startOffset, end: page.endOffset, total: parent.totalBytes,
                                           localProgress: range?.progress ?? Double(y / max(1, height - visible)),
                                           visibleFraction: range?.visible ?? Double(min(1, visible / height)))
            let atEnd = parent.totalBytes > 0 && page.endOffset >= parent.totalBytes && y + visible >= host.text.bounds.height - 1
            host.bar.setProgress(atEnd ? 1 : metrics.value, proportion: metrics.knobProportion)
        }
        func clipChanged() {
            guard let host else { return }
            let clip = host.scroll.contentView.bounds
            let height = host.text.bounds.height
            let stableLayout = lastDocumentHeight == height && lastViewportSize == clip.size
            let delta = lastY - clip.origin.y
            lastY = clip.origin.y; lastDocumentHeight = height; lastViewportSize = clip.size
            guard !updating else { return }
            // Accessibility scrolling and native scrollbar/keyboard operations
            // can move the clip without generating scrollWheel. Distinguish
            // those moves from initial layout or document resizing.
            if stableLayout && delta != 0 { userScrolled(delta) }
            else { updateProgress() }
        }
        func seek(_ value: Double) {
            guard !updating else { return }
            pendingSeek = LogScrollMetrics.clamp(value)
            pendingWindow = false
            parent?.onSeek(value)
        }
        func userScrolled(_ delta: CGFloat) {
            guard delta != 0, !updating, let host, let parent, let page else { return }
            // Wheel delta is positive toward older output. Freeze before asking
            // for another window so a pending live refresh cannot move the text.
            if delta > 0 { parent.onScrollAway() }
            updateProgress()
            guard !parent.loading, !pendingWindow, pendingSeek == nil else { return }
            let rect = host.scroll.contentView.bounds
            let threshold = max(80, rect.height / 2)
            if delta > 0, rect.minY <= threshold, page.hasEarlier {
                pendingWindow = true; parent.onLoadWindow(page.startOffset)
            } else if delta < 0, rect.maxY >= host.text.bounds.maxY - threshold, page.endOffset < parent.totalBytes {
                pendingWindow = true; parent.onLoadWindow(page.endOffset)
            } else if delta < 0, rect.maxY >= host.text.bounds.maxY - 2, page.endOffset >= parent.totalBytes {
                // Returning to the real file end resumes following live output.
                if !parent.followsOutput { seek(1) }
            }
        }
        func navigate(_ key: UInt16, command: Bool) {
            guard let host else { return }
            if key == 115 || (command && key == 126) { seek(0); return }
            if key == 119 || (command && key == 125) { seek(1); return }
            let up = key == 116 || key == 126
            let distance: CGFloat = (key == 116 || key == 121) ? host.scroll.contentView.bounds.height * 0.9 : 18
            parent?.onScrollAway()
            host.scrollTo(y: host.scroll.contentView.bounds.origin.y + (up ? -distance : distance))
            userScrolled(up ? 1 : -1)
        }
    }
}

final class LogViewport: NSView {
    let scroll = LogScrollView()
    let text = LogTextView()
    let bar = GlobalLogScroller()
    var onLayout: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        text.isEditable = false; text.isSelectable = true; text.allowsUndo = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Layout is complete only for this bounded window. Stable geometry is
        // essential when preserving a reading anchor across overlapping windows.
        text.layoutManager?.allowsNonContiguousLayout = false
        text.setAccessibilityLabel("运行日志")
        scroll.documentView = text
        bar.scrollerStyle = .legacy; bar.controlSize = .small
        bar.setAccessibilityLabel("整份日志进度（按字节）")
        addSubview(scroll); addSubview(bar)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let width: CGFloat = 15
        scroll.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        bar.frame = NSRect(x: max(0, bounds.width - width), y: 0, width: width, height: bounds.height)
        onLayout?()
    }
    func prepareDocument(wraps: Bool) {
        guard let layout = text.layoutManager, let container = text.textContainer else { return }
        if wraps && text.frame.width != scroll.contentSize.width {
            text.setFrameSize(NSSize(width: scroll.contentSize.width, height: text.frame.height))
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let width = wraps ? scroll.contentSize.width : max(scroll.contentSize.width, used.maxX + 24)
        let size = NSSize(width: width, height: max(scroll.contentSize.height, used.maxY + 24))
        if text.frame.size != size { text.setFrameSize(size) }
    }
    func characterY(_ utf16Offset: Int) -> CGFloat {
        guard let layout = text.layoutManager, let container = text.textContainer else { return 0 }
        let count = text.textStorage?.length ?? 0
        guard count > 0 else { return 0 }
        let offset = min(count, max(0, utf16Offset))
        // Accurate local anchor geometry, bounded by the one-megabyte document.
        layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: max(1, offset)))
        if offset == count, layout.extraLineFragmentRect.height > 0 {
            return layout.extraLineFragmentRect.minY + text.textContainerOrigin.y
        }
        let glyph = layout.glyphIndexForCharacter(at: min(offset, count - 1))
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return (offset == count ? rect.maxY : rect.minY) + text.textContainerOrigin.y
    }
    func visibleByteFractions(in value: String) -> (progress: Double, visible: Double)? {
        guard !value.isEmpty, let layout = text.layoutManager, let container = text.textContainer else { return nil }
        var rect = scroll.contentView.bounds
        rect.origin.x = 0; rect.size.width = max(text.bounds.width, rect.width)
        rect.origin.y -= text.textContainerOrigin.y
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let count = value.utf16.count
        let lower = String.Index(utf16Offset: min(count, characters.location), in: value)
        let upper = String.Index(utf16Offset: min(count, NSMaxRange(characters)), in: value)
        let total = value.utf8.count
        let before = value[..<lower].utf8.count
        let visible = value[lower..<upper].utf8.count
        guard total > 0, visible > 0 else { return nil }
        return (Double(before) / Double(max(1, total - visible)), Double(visible) / Double(total))
    }
    func scrollTo(y: CGFloat, x: CGFloat? = nil) {
        let clip = scroll.contentView
        let point = NSPoint(x: max(0, x ?? clip.bounds.origin.x),
                            y: min(max(0, y), max(0, text.bounds.height - clip.bounds.height)))
        clip.scroll(to: point); scroll.reflectScrolledClipView(clip)
    }
    func scrollToEnd(x: CGFloat) {
        text.scrollToEndOfDocument(nil)
        scrollTo(y: max(0, text.bounds.height - scroll.contentView.bounds.height), x: x)
    }
}

final class LogScrollView: NSScrollView {
    var onScrolled: ((CGFloat) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        // Pause before AppKit processes a gesture; react again afterwards at the
        // actual edge, including when the local view cannot scroll any further.
        if event.scrollingDeltaY > 0 { onScrolled?(event.scrollingDeltaY) }
        super.scrollWheel(with: event)
        onScrolled?(event.scrollingDeltaY)
    }
}
final class LogTextView: NSTextView {
    var onNavigation: ((UInt16, Bool) -> Void)?
    override func keyDown(with event: NSEvent) {
        if [115, 116, 119, 121, 125, 126].contains(event.keyCode) {
            onNavigation?(event.keyCode, event.modifierFlags.contains(.command))
        } else { super.keyDown(with: event) }
    }
}

final class GlobalLogScroller: NSScroller {
    var onSeek: ((Double) -> Void)?
    private var synchronizing = false
    private var tracking = false
    override var doubleValue: Double {
        didSet { if !synchronizing { onSeek?(LogScrollMetrics.clamp(doubleValue)) } }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self; action = #selector(moved)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setProgress(_ value: Double, proportion: Double) {
        guard !tracking else { return }
        synchronizing = true
        knobProportion = CGFloat(max(0.000001, proportion))
        doubleValue = value
        isEnabled = proportion < 1
        synchronizing = false
    }
    override func mouseDown(with event: NSEvent) {
        tracking = true
        super.mouseDown(with: event)
        tracking = false
    }
    @objc private func moved() {
        let step = Double(knobProportion)
        switch hitPart {
        case .decrementLine: onSeek?(max(0, doubleValue - step / 10))
        case .incrementLine: onSeek?(min(1, doubleValue + step / 10))
        case .decrementPage: onSeek?(max(0, doubleValue - step))
        case .incrementPage: onSeek?(min(1, doubleValue + step))
        default: onSeek?(doubleValue)
        }
    }
}
