import Foundation
import RunbarProcess
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class ProcessRunner: @unchecked Sendable {
    public enum Event { case started(RunSession), output(String), updated(RunSession), finished(RunSession), failure(String), rejected(String), service(VMServiceEndpoint), flutterControls(FlutterRunControls?), interactionRejected(String) }
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
    private var serviceDiscovery = VMServiceDiscovery()
    private var start = DispatchTime.now()
    private var stopTime: DispatchTime?
    private var stopStage = 0
    private var inputFD: Int32 = -1
    private var flutterControls: FlutterRunControls?
    private var flutterOutput = FlutterRunOutput()
    private var requestedDetach = false
    private var flutterOperation: UUID?
    private var flutterReply = ""
    private var flutterSandboxDiagnostic: FlutterSandboxDiagnostic?
    public init(store: SessionStore, handler: @escaping (Event) -> Void) { self.store = store; self.handler = handler }
    deinit { if inputFD >= 0 { close(inputFD) } }
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
        guard preset.builtInAction == nil else { emit(.rejected("内置操作不能作为 shell 命令运行。")); return }
        guard session == nil else { emit(.rejected("已有命令正在运行，请先停止。")); return }
        guard !preset.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { emit(.rejected("命令不能为空。")); return }
        var next = RunSession(projectPath: project.path, command: preset.command)
        do {
            try store.save(next)
            log = try RunLog(directory: store.directory(next.id))
            var child: pid_t = 0; var output: Int32 = -1; var input: Int32 = -1
            let interactive = FlutterRunInput.enabled(project: project, preset: preset)
            let path = CommandEnvironment.extraPath(extraPath)
            let error = interactive
                ? rb_spawn_interactive(shell, preset.command, project.path, path, &child, &output, &input)
                : rb_spawn(shell, preset.command, project.path, path, &child, &output)
            guard error == 0 else { throw RunbarError.message("启动失败：\(String(cString: strerror(error)))") }
            pid = child; session = next; pipeEnded = false; stopped = false
            parser = OutputParser(); serviceDiscovery = VMServiceDiscovery(); start = .now(); stopTime = nil; stopStage = 0
            inputFD = input; flutterOutput = FlutterRunOutput(); requestedDetach = false
            flutterControls = interactive ? FlutterRunControls() : nil
            flutterOperation = nil; flutterReply = ""
            flutterSandboxDiagnostic = nil
            emit(.started(next))
            if interactive { emit(.flutterControls(flutterControls)) }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source; source.resume()
            // A single pipe merges stdout/stderr in OS arrival order. Do not claim
            // source-stream identity or exact originating timestamps.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer {
                    close(output)
                    self?.queue.async { self?.pipeEnded = true }
                }
                var buffer = [UInt8](repeating: 0, count: 16_384)
                while true {
                    // POSIX read returns currently available pipe bytes. Foundation's
                    // read(upToCount:) can wait to fill the requested size on macOS.
                    let count = buffer.withUnsafeMutableBytes { read(output, $0.baseAddress, $0.count) }
                    if count > 0 {
                        let data = Data(buffer.prefix(count))
                        // Backpressure bounds RAM; raw output is never truncated.
                        self?.queue.sync { self?.receive(data) }
                    } else if count == 0 {
                        break
                    } else if errno != EINTR {
                        let message = String(cString: strerror(errno))
                        self?.queue.sync { self?.loggingFailed("读取输出失败：\(message)") }
                        break
                    }
                }
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
        flutterSandboxDiagnostic?.consume(parsed.text)
        if var controls = flutterControls {
            let previous = controls
            flutterOutput.consume(parsed.text)
            if controls.workingAction != nil {
                flutterReply += parsed.text
                // Read chunks are 16 KiB. Retain just a small boundary tail;
                // completed operations stop inspecting application output.
                let pattern = "(?m)^(?:\\[[^\\]\\r\\n]*\\]\\s*)?(?:Reloaded [0-9]+[^\\r\\n]*libraries|Restarted application in |Hot reload was rejected:|Try again after fixing the above error\\(s\\)\\.)"
                if flutterReply.range(of: pattern, options: .regularExpression) != nil {
                    controls.workingAction = nil; flutterOperation = nil; flutterReply = ""
                    flutterSandboxDiagnostic = nil
                } else { flutterReply = String(decoding: flutterReply.utf8.suffix(8192), as: UTF8.self) }
            }
            controls.actions = flutterOutput.actions
            flutterControls = controls
            if controls != previous {
                emit(.flutterControls(controls))
            }
        }
        emit(.output(parsed.text)); addURLs(parsed.urls)
        for endpoint in serviceDiscovery.consume(parsed.text) { emit(.service(endpoint)) }
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
    public func sendFlutterAction(_ action: FlutterRunAction, sessionID: UUID) {
        queue.async {
            guard self.session?.id == sessionID, self.stopTime == nil else { return }
            guard self.inputFD >= 0, var controls = self.flutterControls, controls.canSend(action) else {
                self.emit(.flutterControls(self.flutterControls))
                self.emit(.interactionRejected("Flutter 尚未就绪、正在接收操作或不支持此功能。")); return
            }
            controls.isSending = true; self.flutterControls = controls
            self.emit(.flutterControls(controls))
            let error = rb_send_key(self.inputFD, CChar(bitPattern: action.rawValue.utf8.first!))
            guard error == 0 else {
                self.closeInput(); self.flutterControls = nil; self.emit(.flutterControls(nil))
                self.emit(.interactionRejected("无法向当前 Flutter 运行发送操作：\(String(cString: strerror(error)))")); return
            }
            if action == .hotReload || action == .hotRestart {
                controls.workingAction = action; self.flutterControls = controls; self.flutterReply = ""
                self.flutterSandboxDiagnostic = FlutterSandboxDiagnostic()
                let token = UUID(); self.flutterOperation = token
                self.emit(.flutterControls(controls))
                self.queue.asyncAfter(deadline: .now() + .seconds(120)) { [weak self] in
                    guard let self, self.session?.id == sessionID, self.stopTime == nil,
                          self.flutterOperation == token, var value = self.flutterControls else { return }
                    self.flutterOperation = nil; self.flutterReply = ""; value.workingAction = nil
                    self.flutterSandboxDiagnostic = nil
                    self.flutterControls = value; self.emit(.flutterControls(value))
                    self.emit(.interactionRejected("Flutter 尚未返回重载完成信息，请查看日志后重试。"))
                }
            }
            if action == .detach {
                self.requestedDetach = true; controls.isDetaching = true; self.flutterControls = controls
                self.emit(.flutterControls(controls))
                self.queue.asyncAfter(deadline: .now() + .seconds(15)) { [weak self] in
                    guard let self, self.session?.id == sessionID, self.stopTime == nil,
                          var value = self.flutterControls, value.isDetaching else { return }
                    self.requestedDetach = false; value.isDetaching = false
                    self.flutterControls = value; self.emit(.flutterControls(value))
                    self.emit(.interactionRejected("Flutter 命令尚未退出，请查看分离操作的输出后重试。"))
                }
            }
            // Flutter consumes a byte chunk as one key. Space out clicks to
            // reduce coalescing; reloads also wait for their completion output.
            // This indicates input delivery only; Flutter logs report results.
            self.queue.asyncAfter(deadline: .now() + .milliseconds(600)) { [weak self] in
                guard let self, self.session?.id == sessionID, self.stopTime == nil, var value = self.flutterControls else { return }
                value.isSending = false; self.flutterControls = value; self.emit(.flutterControls(value))
            }
        }
    }
    private func closeInput() {
        if inputFD >= 0 { close(inputFD); inputFD = -1 }
    }
    public func runningProcessID() async -> Int32? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.session != nil && self.pid > 1 ? self.pid : nil) }
        }
    }
    private func requestStop() {
        guard session != nil, stopTime == nil else { return }
        stopped = true; stopTime = .now(); stopStage = 1
        closeInput()
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
        closeInput(); flutterControls = nil
        flutterOperation = nil; flutterReply = ""
        let final = parser.consume(Data(), final: true); emit(.output(final.text)); addURLs(final.urls)
        flutterSandboxDiagnostic?.consume(final.text, final: true)
        for endpoint in serviceDiscovery.consume(final.text, final: true) { emit(.service(endpoint)) }
        guard var value = session else { return }
        value.endedAt = Date(); value.duration = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        value.exitCode = code
        do { try log?.close() } catch { value.error = "日志落盘失败，日志可能不完整：\(error.localizedDescription)" }
        log = nil
        if !stopped, let code, code != 0, value.error == nil, let failure = flutterSandboxDiagnostic?.failure {
            value.flutterSandboxAccessFailure = failure; value.error = failure.message
        }
        flutterSandboxDiagnostic = nil
        value.status = value.error != nil ? .failed : stopped ? .stopped : code == 0 ? (requestedDetach ? .detached : .succeeded) : .failed
        do { try store.save(value) } catch {
            value.error = "保存运行记录失败：\(error.localizedDescription)"; value.status = .failed
            value.flutterSandboxAccessFailure = nil
        }
        session = nil; pid = 0; emit(.finished(value))
    }
}
