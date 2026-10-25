import Foundation
import RunbarProcess
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class ProcessRunner: @unchecked Sendable {
    public enum Event { case started(RunSession), output(String), updated(RunSession), finished(RunSession), failure(String), rejected(String) }
    private let queue = DispatchQueue(label: "runbar.process")
    private let outputLock = NSLock()
    private var pendingOutput = ""
    private var deliveryScheduled = false
    private let store: SessionStore
    private let handler: (Event) -> Void
    private var session: RunSession?
    private var pid: pid_t = 0
    private var pipeEnded = false
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private var log: RunLog?
    private var parser = OutputParser()
    private var start = DispatchTime.now()
    private var stopTime: DispatchTime?
    private var stopStage = 0
    public init(store: SessionStore, handler: @escaping (Event) -> Void) { self.store = store; self.handler = handler }
    private func emit(_ event: Event) {
        guard case .output(let text) = event else { DispatchQueue.main.async { self.handler(event) }; return }
        guard !text.isEmpty else { return }
        outputLock.lock()
        pendingOutput += text
        if pendingOutput.utf8.count > 200_000 {
            pendingOutput = "[显示缓冲已截断；完整输出保存在本地]\n" + String(decoding: pendingOutput.utf8.suffix(100_000), as: UTF8.self)
        }
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        outputLock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.main.async {
            self.outputLock.lock()
            let text = self.pendingOutput
            self.pendingOutput = ""; self.deliveryScheduled = false
            self.outputLock.unlock()
            self.handler(.output(text))
        }
    }
    public func run(project: Project, preset: CommandPreset, extraPath: String, shell: String = "/bin/zsh") {
        queue.async { self.launch(project: project, preset: preset, extraPath: extraPath, shell: shell) }
    }
    private func launch(project: Project, preset: CommandPreset, extraPath: String, shell: String) {
        guard session == nil else { emit(.rejected("已有命令正在运行，请先停止。")); return }
        guard !preset.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { emit(.rejected("命令不能为空。")); return }
        var next = RunSession(projectPath: project.path, command: preset.command)
        do {
            try store.save(next)
            log = try RunLog(directory: store.directory(next.id))
            var child: pid_t = 0; var output: Int32 = -1
            let error = rb_spawn(shell, preset.command, project.path, extraPath, &child, &output)
            guard error == 0 else { throw RunbarError.message("启动失败：\(String(cString: strerror(error)))") }
            pid = child; session = next; pipeEnded = false; stopped = false
            parser = OutputParser(); start = .now(); stopTime = nil; stopStage = 0
            emit(.started(next))
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source; source.resume()
            // A single pipe merges stdout/stderr in OS arrival order. Do not claim
            // source-stream identity or exact originating timestamps.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
                do {
                    var buffer = [UInt8](repeating: 0, count: 16_384)
                    while true {
                        // One POSIX read returns currently available pipe bytes.
                        // FileHandle.read(upToCount:) can wait to fill its requested
                        // count on macOS, hiding short live output until EOF.
                        let (count, readError) = buffer.withUnsafeMutableBytes { bytes in
                            let count = read(output, bytes.baseAddress, bytes.count)
                            return (count, errno)
                        }
                        if count == 0 { break }
                        if count < 0 {
                            if readError == EINTR { continue }
                            throw RunbarError.message(String(cString: strerror(readError)))
                        }
                        let data = Data(buffer.prefix(count))
                        // Backpressure bounds RAM; raw output is never truncated.
                        self?.queue.sync { self?.receive(data) }
                    }
                } catch { self?.queue.sync { self?.loggingFailed("读取输出失败：\(error.localizedDescription)") } }
                try? handle.close()
                self?.queue.async { self?.pipeEnded = true }
            }
        } catch {
            next.status = .failed; next.endedAt = Date(); next.error = error.localizedDescription
            do { try store.save(next) } catch { next.error = (next.error ?? "") + "；保存失败：\(error.localizedDescription)" }
            try? log?.close(); log = nil
            emit(.finished(next))
        }
    }
    private func receive(_ data: Data) {
        do { try log?.append(data) } catch { loggingFailed("日志写入失败，正在停止命令。日志可能不完整：\(error.localizedDescription)") }
        let parsed = parser.consume(data)
        emit(.output(parsed.text)); addURLs(parsed.urls)
    }
    private func addURLs(_ urls: [String]) {
        guard !urls.isEmpty, var value = session, value.devToolsURLs.count < 32 else { return }
        let merged = Array(Array(Set(value.devToolsURLs + urls)).sorted().prefix(32))
        guard merged != value.devToolsURLs else { return }
        value.devToolsURLs = merged; session = value; emit(.updated(value))
    }
    private func loggingFailed(_ message: String) {
        guard session?.error == nil else { return }
        // A partial raw/index write cannot safely resume: drain only from now on.
        log = nil
        session?.error = message; emit(.failure(message)); requestStop()
    }
    public func stop() { queue.async { self.requestStop() } }
    private func requestStop() {
        guard session != nil, stopTime == nil else { return }
        stopped = true; stopTime = .now(); stopStage = 1
        signal(SIGINT)
    }
    private func signal(_ signal: Int32) {
        let error = rb_signal(pid, signal)
        if error != 0 && error != ESRCH { emit(.failure("无法停止进程组：\(String(cString: strerror(error)))")) }
    }
    private func tick() {
        guard session != nil else { return }
        if let time = stopTime {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - time.uptimeNanoseconds) / 1e9
            if elapsed >= 6 && stopStage < 3 { signal(SIGKILL); stopStage = 3 }
            else if elapsed >= 3 && stopStage < 2 { signal(SIGTERM); stopStage = 2 }
        }
        // Hold the direct child unreaped until EOF, preventing PID reuse while
        // descendants retain the pipe and while group escalation is pending.
        guard pipeEnded else { return }
        // Even after the leader closes output, redirected descendants can remain.
        // Keep its PID unreaped until escalation finishes, so group identity cannot
        // be recycled while signals are still scheduled.
        if stopTime != nil && stopStage < 3 { return }
        var code: Int32 = 0
        let result = rb_poll(pid, &code)
        guard result != 0 else { return }
        if result < 0 { session?.error = "等待进程失败：\(String(cString: strerror(-result)))" }
        finish(code: result > 0 ? code : nil)
    }
    private func finish(code: Int32?) {
        timer?.cancel(); timer = nil
        let final = parser.consume(Data(), final: true); emit(.output(final.text)); addURLs(final.urls)
        guard var value = session else { return }
        value.endedAt = Date(); value.duration = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        value.exitCode = code
        do { try log?.close() } catch { value.error = "日志落盘失败，日志可能不完整：\(error.localizedDescription)" }
        log = nil
        value.status = value.error != nil ? .failed : stopped ? .stopped : code == 0 ? .succeeded : .failed
        do { try store.save(value) } catch { value.error = "保存运行记录失败：\(error.localizedDescription)"; value.status = .failed }
        session = nil; pid = 0; emit(.finished(value))
    }
}
