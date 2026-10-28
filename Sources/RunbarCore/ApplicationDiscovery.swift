import AppKit
import Foundation

public struct RunningApplicationCandidate: Identifiable, Sendable {
    public var id: Int32 { processID }
    public let processID: Int32
    public let application: ApplicationTarget
    public let launchedAt: Date?
    public let flutterDetected: Bool
    public init(processID: Int32, application: ApplicationTarget, launchedAt: Date?, flutterDetected: Bool) {
        self.processID = processID; self.application = application; self.launchedAt = launchedAt; self.flutterDetected = flutterDetected
    }
}

public enum ApplicationDiscovery {
    @MainActor public static func running() -> [RunningApplicationCandidate] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let url = app.bundleURL, let name = app.localizedName else { return nil }
            let frameworks = url.appendingPathComponent("Contents/Frameworks")
            let flutter = ["FlutterMacOS.framework", "Flutter.framework"].contains {
                FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path)
            }
            guard flutter else { return nil }
            return RunningApplicationCandidate(processID: app.processIdentifier,
                application: ApplicationTarget(name: name, bundleIdentifier: app.bundleIdentifier, bundlePath: url.path),
                launchedAt: app.launchDate, flutterDetected: flutter)
        }.sorted { $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending }
    }
    @MainActor public static func isCurrent(_ candidate: RunningApplicationCandidate) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: candidate.processID), !app.isTerminated,
              let url = app.bundleURL,
              url.standardizedFileURL.resolvingSymlinksInPath().path == candidate.application.bundlePath,
              app.bundleIdentifier == candidate.application.bundleIdentifier else { return false }
        return candidate.launchedAt == app.launchDate
    }

    /// Only the selected process's listeners; never scan the machine's port range.
    public static func listeningPorts(processID: Int32) async -> [Int] {
        await Task.detached(priority: .utility) {
            guard processID > 1 else { return [] }
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-nP", "-a", "-p", String(processID), "-iTCP", "-sTCP:LISTEN", "-Fn"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return [] }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: timeout)
            let data = (try? pipe.fileHandleForReading.read(upToCount: 65_537)) ?? Data()
            if data.count > 65_536, process.isRunning { process.terminate() }
            try? pipe.fileHandleForReading.close(); process.waitUntilExit(); timeout.cancel()
            guard data.count <= 65_536 else { return [] }
            return ports(from: String(decoding: data, as: UTF8.self))
        }.value
    }
    public static func ports(from output: String) -> [Int] {
        var seen = Set<Int>(), ports: [Int] = []
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            guard let suffix = line.split(separator: ":").last, let port = Int(suffix), (1...65535).contains(port), seen.insert(port).inserted else { continue }
            ports.append(port); if ports.count == 8 { break }
        }
        return ports
    }

    /// Race known / unauthenticated addresses against locally published Dart
    /// services. Authentication is preserved and every result is PID-validated.
    public static func serviceEndpoint(for candidate: RunningApplicationCandidate, known: [VMServiceEndpoint]) async throws -> VMServiceEndpoint? {
        let ports = await listeningPorts(processID: candidate.processID)
        try Task.checkCancellation()
        let probe = ApplicationServiceProbe()
        return try await withThrowingTaskGroup(of: VMServiceEndpoint?.self) { group in
            group.addTask {
                try await probe.discover(processID: candidate.processID, flutterDetected: candidate.flutterDetected, known: known, ports: ports)
            }
            group.addTask {
                let advertised = await LocalDartVMServices.endpoints(ports: ports)
                try Task.checkCancellation()
                return try await probe.discover(processID: candidate.processID, flutterDetected: candidate.flutterDetected, known: advertised, ports: [])
            }
            for try await result in group {
                if let result { group.cancelAll(); return result }
            }
            return nil
        }
    }
}

public struct ApplicationServiceProbe: Sendable {
    private let transport: any VMServiceTransport
    public init(transport: any VMServiceTransport = HTTPVMServiceTransport(limit: 256 * 1024)) { self.transport = transport }
    /// getVM's PID is mandatory: never attach merely because a port responds.
    public func validate(_ endpoint: VMServiceEndpoint, processID: Int32, flutterDetected: Bool) async throws {
        let data = try await transport.call(endpoint: endpoint, method: "getVM", parameters: [:])
        guard data.count <= 256 * 1024, let result = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any],
              (result["pid"] as? NSNumber)?.int64Value == Int64(processID) else {
            throw RunbarError.message("连接地址不属于所选 App，请复制该 App 当前运行的完整调试链接。")
        }
        if !flutterDetected {
            let views = try await transport.call(endpoint: endpoint, method: "_flutter.listViews", parameters: [:])
            guard let result = (try JSONSerialization.jsonObject(with: views) as? [String: Any])?["result"] as? [String: Any],
                  let list = result["views"] as? [[String: Any]], !list.isEmpty else {
                throw RunbarError.message("该进程未提供 Flutter 调试能力，暂不能关联。")
            }
        }
        try Task.checkCancellation()
    }
    public func discover(processID: Int32, flutterDetected: Bool, known: [VMServiceEndpoint] = [], ports: [Int]) async throws -> VMServiceEndpoint? {
        var endpoints: [VMServiceEndpoint] = []
        let relevant = known.filter { ports.isEmpty || ports.contains($0.url.port ?? ($0.url.scheme == "https" ? 443 : 80)) }
        let local = ports.flatMap { port in ["127.0.0.1", "[::1]"].compactMap { VMServiceEndpoint("http://\($0):\(port)/") } }
        for endpoint in relevant + local where !endpoints.contains(endpoint) {
            endpoints.append(endpoint); if endpoints.count == 16 { break }
        }
        return try await withThrowingTaskGroup(of: VMServiceEndpoint?.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    do { try await validate(endpoint, processID: processID, flutterDetected: flutterDetected); return endpoint }
                    catch is CancellationError { throw CancellationError() }
                    catch { return nil }
                }
            }
            for try await endpoint in group { if let endpoint { group.cancelAll(); return endpoint } }
            return nil
        }
    }
}
