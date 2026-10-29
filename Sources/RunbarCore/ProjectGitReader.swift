import Foundation

public enum ProjectGitHead: Equatable, Sendable {
    case branch(String)
    case detached(String)

    public var title: String {
        switch self {
        case .branch(let name): return name
        case .detached(let revision): return "HEAD · " + String(revision.prefix(7))
        }
    }
    public var help: String {
        switch self {
        case .branch(let name): return "当前 Git 分支：\(name)"
        case .detached(let revision): return "分离 HEAD：\(revision)"
        }
    }
}

/// Read only a repository's HEAD, never its index, working tree or shell config.
/// A .git file points at the per-worktree / submodule git directory, whose HEAD
/// must be used instead of the main repository's HEAD.
public enum ProjectGitReader {
    public static func snapshot(paths: [String]) async -> [String: ProjectGitHead] {
        let task = Task.detached(priority: .utility) {
            var result: [String: ProjectGitHead] = [:]
            var heads: [URL: ProjectGitHead] = [:]
            var inspected = Set<URL>()
            for path in Set(paths) {
                guard !Task.isCancelled else { break }
                guard let directory = gitDirectory(for: path) else { continue }
                if inspected.insert(directory).inserted { heads[directory] = readHead(in: directory) }
                result[path] = heads[directory]
            }
            return result
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private static func gitDirectory(for path: String) -> URL? {
        guard path.hasPrefix("/"), path.utf8.count <= 16_384 else { return nil }
        var directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        while !Task.isCancelled {
            let metadata = directory.appendingPathComponent(".git", isDirectory: false)
            var isFolder = ObjCBool(false)
            if FileManager.default.fileExists(atPath: metadata.path, isDirectory: &isFolder) {
                if isFolder.boolValue { return metadata }
                guard let value = smallText(metadata), value.hasPrefix("gitdir: ") else { return nil }
                let target = String(value.dropFirst(8)).trimmingCharacters(in: .newlines)
                guard !target.isEmpty, !target.contains("\n"), !target.contains("\r") else { return nil }
                return URL(fileURLWithPath: target, isDirectory: true, relativeTo: directory)
                    .standardizedFileURL.resolvingSymlinksInPath()
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return nil
    }

    private static func readHead(in directory: URL) -> ProjectGitHead? {
        guard let text = smallText(directory.appendingPathComponent("HEAD")) else { return nil }
        let value = text.trimmingCharacters(in: .newlines)
        let prefix = "ref: refs/heads/"
        if value.hasPrefix(prefix) {
            let name = String(value.dropFirst(prefix.count))
            guard !name.isEmpty, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !name.contains(where: \.isWhitespace) else { return nil }
            // Includes unborn branches: a new repository need not have a commit.
            return .branch(name)
        }
        guard [40, 64].contains(value.utf8.count), value.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return .detached(value)
    }

    private static func smallText(_ url: URL) -> String? {
        // Do not block on a pipe/device if metadata has been replaced. Limit the
        // read before decoding so malformed files cannot grow the UI's memory.
        let file = url.resolvingSymlinksInPath()
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 16_385), bytes.count <= 16_384 else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}
