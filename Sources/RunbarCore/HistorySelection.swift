import Foundation

public struct HistorySelection {
    public enum Mode { case single, toggle, range }
    public private(set) var ids = Set<UUID>()
    public private(set) var focusedID: UUID?
    private var anchorID: UUID?
    public init() {}
    public mutating func setSingle(_ id: UUID?) {
        ids = id.map { [$0] } ?? []; focusedID = id; anchorID = id
    }
    public mutating func selectAll(_ visible: [UUID]) {
        ids = Set(visible)
        if focusedID.map({ ids.contains($0) }) != true { focusedID = visible.first }
        anchorID = focusedID
    }
    public mutating func select(_ id: UUID, visible: [UUID], mode: Mode = .single) {
        guard visible.contains(id) else { return }
        switch mode {
        case .single:
            setSingle(ids == [id] ? nil : id)
        case .toggle:
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            if ids.contains(id) { focusedID = id }
            else if focusedID.map({ ids.contains($0) }) != true { focusedID = visible.first(where: { ids.contains($0) }) }
            anchorID = id
        case .range:
            if let anchor = anchorID, let from = visible.firstIndex(of: anchor), let to = visible.firstIndex(of: id) {
                ids = Set(visible[min(from, to)...max(from, to)])
                focusedID = id
            } else { setSingle(id) }
        }
        ids.formIntersection(visible)
    }
    public mutating func remove(_ deleted: Set<UUID>, visible: [UUID]) {
        ids.subtract(deleted)
        ids.formIntersection(visible)
        if let focusedID, !ids.contains(focusedID) { self.focusedID = visible.first(where: { ids.contains($0) }) }
        if let anchorID, !visible.contains(anchorID) { self.anchorID = focusedID }
    }
}
