import AppKit
import Darwin
import Foundation

public struct ApplicationLaunch {
    /// Launch an existing bundle directly, using only the startup announcement
    /// for discovery. The running app belongs to the user, even after timeout.
    @MainActor public static func connectableApplication(at location: URL) async throws
        -> (RunningApplicationCandidate, VMServiceEndpoint) {
        let url = location.standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "app", ApplicationDiscovery.isFlutterBundle(url),
              let bundle = Bundle(url: url), let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RunbarError.message("请选择一个有效的 macOS Flutter .app 构建产物。")
        }
        if ApplicationDiscovery.running().contains(where: { $0.application.bundlePath == url.path }) {
            throw RunbarError.message("这个 App 正在运行。可直接选择它，或退出该 App 后再用这个入口启动。")
        }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = url.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        let output = try ApplicationLaunchOutput()
        try Task.checkCancellation()
        try output.start(process)
        defer { output.stopDiscovery() }

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        let probe = ApplicationServiceProbe()
        var candidate: RunningApplicationCandidate?
        while clock.now < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw RunbarError.message("App 在取得调试地址前已退出。请检查构建产物能否正常启动。")
            }
            if candidate == nil {
                candidate = ApplicationDiscovery.running().first {
                    $0.processID == process.processIdentifier && $0.application.bundlePath == url.path
                }
            }
            if let candidate {
                let endpoints = output.takeEndpoints()
                if !endpoints.isEmpty,
                   let endpoint = try await probe.discover(processID: candidate.processID, flutterDetected: true, known: endpoints) {
                    guard process.isRunning, ApplicationDiscovery.isCurrent(candidate) else {
                        throw RunbarError.message("App 已退出，请重新选择并启动。")
                    }
                    return (candidate, endpoint)
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RunbarError.message("App 已启动，但未取得调试地址。请确认是提供 Dart VM Service 的 Debug 或 Profile 构建。")
    }
}

/// Drain the launch output for the life of the child, parsing only during
/// startup. The write socket suppresses SIGPIPE if Runbar exits first.
final class ApplicationLaunchOutput: @unchecked Sendable {
    private let writer: FileHandle
    private let reader: DispatchSourceRead
    private let lock = NSLock()
    private var discovery: VMServiceDiscovery? = VMServiceDiscovery()
    private var endpoints: [VMServiceEndpoint] = []

    init() throws {
        let failure = RunbarError.message("无法准备读取 App 的启动输出。")
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw failure }
        let readFD = descriptors[0], writeFD = descriptors[1]
        var suppressSignal: Int32 = 1
        let flags = fcntl(readFD, F_GETFL)
        guard flags >= 0, fcntl(readFD, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(readFD, F_SETFD, FD_CLOEXEC) == 0, fcntl(writeFD, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(writeFD, SOL_SOCKET, SO_NOSIGPIPE, &suppressSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(readFD)
            Darwin.close(writeFD)
            throw failure
        }
        writer = FileHandle(fileDescriptor: writeFD, closeOnDealloc: true)
        reader = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: .global(qos: .utility))
        reader.setCancelHandler { Darwin.close(readFD) }
        reader.setEventHandler { [weak self] in self?.readOutput(readFD) }
        reader.resume()
    }

    func start(_ process: Process) throws {
        process.standardOutput = writer
        process.standardError = writer
        process.terminationHandler = { [self] _ in close() }
        defer { try? writer.close() }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            close()
            throw RunbarError.message("无法启动选中的 App。请检查它是否可在这台 Mac 上运行。")
        }
    }

    func takeEndpoints() -> [VMServiceEndpoint] {
        lock.withLock {
            let found = endpoints
            endpoints.removeAll()
            return found
        }
    }

    func stopDiscovery() {
        lock.withLock {
            discovery = nil
            endpoints.removeAll()
        }
    }

    func close() { reader.cancel() }

    deinit { reader.cancel() }

    private func readOutput(_ fd: Int32) {
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count <= 0 {
            if count == 0 || (errno != EAGAIN && errno != EINTR) { close() }
            return
        }
        lock.withLock {
            guard discovery != nil else { return }
            let found = discovery?.consume(String(decoding: bytes.prefix(count), as: UTF8.self)) ?? []
            for endpoint in found where endpoints.count < 8 && !endpoints.contains(endpoint) {
                endpoints.append(endpoint)
            }
        }
    }
}
