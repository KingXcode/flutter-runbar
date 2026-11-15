import SwiftUI
import AppKit
import RunbarCore

/// NSTableView keeps even wide market tables virtualized; values remain lexical JSON.
struct ResponseRewriteTableView: NSViewRepresentable {
    let table: ResponseRewriteTable
    let changesByCell: [String: [ResponseRewriteChange]]
    let ruleName: String
    var rewriteMenu: ((ResponseRewriteTarget) -> NSMenu?)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let view = ResponseRewriteContextTableView(); view.rowHeight = 25; view.usesAlternatingRowBackgroundColors = true
        view.columnAutoresizingStyle = .noColumnAutoresizing; view.allowsEmptySelection = true
        view.delegate = context.coordinator; view.dataSource = context.coordinator
        view.target = context.coordinator; view.action = #selector(Coordinator.clicked(_:))
        view.rewriteContextMenu = { [weak view, weak coordinator = context.coordinator] row, column in
            guard let view else { return nil }
            return coordinator?.contextMenu(for: view, row: row, visualColumn: column)
        }
        view.headerView = ResponseRewriteContextHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 25))
        view.setAccessibilityLabel("响应表格，修改值可查看原值")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTableView else { return }
        let previous = context.coordinator.parent
        if previous.table.path != table.path || previous.table.headers != table.headers || previous.table.rows != table.rows ||
            previous.changesByCell != changesByCell || previous.ruleName != ruleName {
            context.coordinator.closePopover()
        }
        context.coordinator.parent = self
        if previous.table.headers != table.headers || view.tableColumns.isEmpty {
            for column in view.tableColumns { view.removeTableColumn(column) }
            for (index, name) in table.headers.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                column.title = name; column.width = max(90, min(200, CGFloat(name.count) * 13 + 24))
                column.minWidth = 50; column.resizingMask = .userResizingMask
                view.addTableColumn(column)
            }
        }
        view.reloadData()
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ResponseRewriteTableView
        private var popover: NSPopover?
        init(_ parent: ResponseRewriteTableView) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.table.rows.count }
        func closePopover() { popover?.close(); popover = nil }
        func contextMenu(for tableView: NSTableView, row: Int, visualColumn: Int) -> NSMenu? {
            guard tableView.tableColumns.indices.contains(visualColumn),
                  let column = Int(tableView.tableColumns[visualColumn].identifier.rawValue),
                  let target = ResponseRewritePresentation.target(table: parent.table, row: row, column: column),
                  let menu = parent.rewriteMenu?(target) else { return nil }
            closePopover()
            return menu
        }
        private func changes(row: Int, column: Int) -> [ResponseRewriteChange] {
            parent.changesByCell[parent.table.path + "[\(row + parent.table.headerRow + 1)][\(column)]"] ?? []
        }
        private func tooltip(_ changes: [ResponseRewriteChange]) -> String {
            changes.map { "原始值：\($0.originalJSON)\n修改后：\($0.replacementJSON)\n规则：\(parent.ruleName)\n位置：\($0.path)" }
                .joined(separator: "\n\n")
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, let column = Int(id.rawValue),
                  parent.table.rows.indices.contains(row), parent.table.rows[row].indices.contains(column) else { return nil }
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? NSTableCellView()
            if cell.textField == nil {
                cell.identifier = id
                let text = NSTextField(labelWithString: ""); text.translatesAutoresizingMaskIntoConstraints = false
                text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                text.lineBreakMode = .byTruncatingTail; text.maximumNumberOfLines = 1
                cell.addSubview(text); cell.textField = text
                NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            let value = parent.table.rows[row][column]
            cell.textField?.stringValue = value
            let changes = changes(row: row, column: column)
            if !changes.isEmpty {
                cell.textField?.drawsBackground = true
                cell.textField?.backgroundColor = .systemOrange.withAlphaComponent(0.22)
                cell.toolTip = tooltip(changes); cell.textField?.setAccessibilityHelp(tooltip(changes))
            } else {
                cell.textField?.drawsBackground = false; cell.toolTip = value
                cell.textField?.setAccessibilityHelp(nil)
            }
            return cell
        }
        @objc func clicked(_ sender: NSTableView) {
            closePopover()
            guard sender.clickedRow >= 0, sender.clickedColumn >= 0,
                  let column = Int(sender.tableColumns[sender.clickedColumn].identifier.rawValue) else { return }
            let changes = changes(row: sender.clickedRow, column: column)
            guard !changes.isEmpty else { return }
            let text = NSTextView(); text.isEditable = false; text.isSelectable = true
            text.string = tooltip(changes); text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.textContainerInset = NSSize(width: 10, height: 10)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 180))
            scroll.hasVerticalScroller = true; scroll.documentView = text
            text.frame = scroll.bounds; text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            let controller = NSViewController(); controller.view = scroll
            let popup = NSPopover(); popup.behavior = .transient; popup.contentViewController = controller
            popup.show(relativeTo: sender.frameOfCell(atColumn: sender.clickedColumn, row: sender.clickedRow), of: sender, preferredEdge: .maxY)
            popover = popup
        }
    }
}

/// Context targets always come from the pointer, including after column reordering.
/// A previously selected row must never redirect a rewrite action elsewhere.
private final class ResponseRewriteContextTableView: NSTableView {
    var rewriteContextMenu: ((Int, Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        guard row >= 0, row < numberOfRows, column >= 0, column < tableColumns.count else { return nil }
        return rewriteContextMenu?(row, column)
    }
}

private final class ResponseRewriteContextHeaderView: NSTableHeaderView {
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let table = tableView as? ResponseRewriteContextTableView else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let column = column(at: point)
        guard column >= 0, column < table.tableColumns.count, headerRect(ofColumn: column).contains(point) else { return nil }
        // The presentation helper uses the first data value as the draft value,
        // and returns nil for an empty table. The header itself is never a target.
        return table.rewriteContextMenu?(-1, column)
    }
}
