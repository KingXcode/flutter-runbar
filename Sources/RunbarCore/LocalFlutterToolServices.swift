import Foundation
import RunbarProcess

/// Desktop Flutter engines need not publish Bonjour. A resident Flutter tool
/// may expose the upstream authenticated VM URI in its own DDS child's argv.
/// Scope reads to that launcher family; never enumerate all command lines,
/// inspect environments, read terminal history, or log authentication paths.
enum LocalFlutterToolServices {
    static func endpoints(processID: Int32, ports: [Int]) async -> [VMServiceEndpoint] {
        let task = Task.detached(priority: .utility) {
            guard processID > 1 else { return [VMServiceEndpoint]() }
            let parent = rb_parent_process(processID)
            guard parent > 1,
                  let launcher = query("/bin/ps", ["-ww", "-p", String(parent), "-o", "args="]),
                  isFlutterLauncher(launcher), !Task.isCancelled,
                  let children = query("/usr/bin/pgrep", ["-P", String(parent)]) else { return [] }
            let pids = Array(Set(children.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) })
                .filter { $0 > 1 && $0 != processID }.sorted().prefix(16))
            guard !pids.isEmpty, !Task.isCancelled,
                  let rows = query("/bin/ps", ["-ww", "-p", pids.map { String($0) }.joined(separator: ","), "-o", "pid=,ppid=,args="]),
                  rb_parent_process(processID) == parent else { return [] }
            var result: [VMServiceEndpoint] = []
            for row in rows.split(separator: "\n") {
                guard !Task.isCancelled else { return [] }
                let fields = row.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count == 3, let pid = Int32(fields[0]), pids.contains(pid),
                      Int32(fields[1]) == parent, rb_parent_process(pid) == parent,
                      let endpoint = ddsEndpoint(arguments: String(fields[2])),
                      ports.isEmpty || ports.contains(endpoint.url.port ?? (endpoint.url.scheme == "https" ? 443 : 80)),
                      !result.contains(endpoint) else { continue }
                result.append(endpoint)
            }
            return result
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private static func isFlutterLauncher(_ arguments: String) -> Bool {
        arguments.range(of: #"(?:^|/)flutter_tools\.(?:snapshot|dart)(?:\s|$)"#, options: .regularExpression) != nil &&
        arguments.range(of: #"(?:^|\s)(?:run|attach)(?:\s|$)"#, options: .regularExpression) != nil
    }

    static func ddsEndpoint(arguments: String) -> VMServiceEndpoint? {
        guard arguments.utf8.count <= 65_536,
              arguments.range(of: #"^.*(?:/|^)(?:dart|dartaotruntime)\s"#, options: .regularExpression) != nil,
              arguments.range(of: #"(?:^|\s|/)(?:development-service|dds(?:_aot)?\.dart\.snapshot)(?:\s|$)"#, options: .regularExpression) != nil,
              let regex = try? NSRegularExpression(pattern: #"(?:^|\s)--vm-service-uri(?:=|\s+)((?:https?|wss?)://[^\s\"']+)"#) else { return nil }
        let matches = regex.matches(in: arguments, range: NSRange(arguments.startIndex..., in: arguments))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: arguments) else { return nil }
        return VMServiceEndpoint(String(arguments[range]))
    }

    private static func query(_ executable: String, _ arguments: [String]) -> String? {
        guard !Task.isCancelled else { return nil }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(2), execute: deadline)
        defer {
            deadline.cancel(); try? pipe.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        var data = Data()
        do {
            while !Task.isCancelled {
                guard let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty else { break }
                guard data.count <= 65_536 - chunk.count else { return nil }
                data.append(chunk)
            }
        } catch { return nil }
        process.waitUntilExit()
        guard !Task.isCancelled, process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
