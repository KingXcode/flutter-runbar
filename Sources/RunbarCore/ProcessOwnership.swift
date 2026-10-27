import Foundation

public enum ProcessOwnership {
    public static func belongsToRun(_ pid: Int32, roots: Set<Int32>, parent: (Int32) -> Int32,
                                    group: (Int32) -> Int32) -> Bool {
        let roots = roots.filter { $0 > 1 }
        guard pid > 1, !roots.isEmpty else { return false }
        if roots.contains(pid) || roots.contains(group(pid)) { return true }
        var candidate = pid, visited = Set<Int32>()
        for _ in 0..<128 {
            guard candidate > 1, visited.insert(candidate).inserted else { return false }
            if roots.contains(candidate) { return true }
            candidate = parent(candidate)
        }
        return false
    }
    /// Covers apps launched through LaunchServices, which may be reparented to
    /// launchd: only a newly launched bundle inside the running project qualifies.
    public static func isNewProjectApplication(_ bundle: URL?, launchedAt: Date?, projectPath: String, startedAt: Date) -> Bool {
        guard let bundle, let launchedAt, launchedAt >= startedAt else { return false }
        let root = URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let path = bundle.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return path.count > root.count && path.starts(with: root) && bundle.pathExtension.lowercased() == "app"
    }
}
