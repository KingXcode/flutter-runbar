import Foundation
import RunbarCore

@MainActor
final class NetworkMonitor: ObservableObject {
    struct State: Equatable {
        var text = "等待 VM Service"
        var paused = false
        var canResumeApplication = false
        var error = false
    }
    private final class Runtime {
        let sessionID: UUID
        let projectID: UUID
        var endpoint: VMServiceEndpoint?
        var enabled: Bool
        var paused = false
        var capture: NetworkCaptureSession?
        var task: Task<Void, Never>?
        var bodyTask: Task<Void, Never>?
        var bodyRequestID: String?
        var bodyGeneration = UUID()
        var latestUpdate: NetworkCaptureUpdate?
        var generation = UUID()
        init(projectID: UUID, sessionID: UUID, enabled: Bool) {
            self.projectID = projectID; self.sessionID = sessionID; self.enabled = enabled
        }
    }
    @Published private(set) var states: [UUID: State] = [:]
    @Published private(set) var revision = 0
    @Published private(set) var loadingBodies = Set<String>()
    @Published private(set) var bodyErrors: [String: String] = [:]
    private var runtimes: [UUID: Runtime] = [:]
    private var finishing: [UUID: Task<Void, Never>] = [:]
    private var root: URL?
    var onFinished: (() -> Void)?
    var knownEndpoints: [VMServiceEndpoint] { runtimes.values.compactMap(\.endpoint) }
    func configure(root: URL) { self.root = root }
    func directory(_ id: UUID) -> URL? { root?.appendingPathComponent("sessions/\(id.uuidString)/network", isDirectory: true) }
    func started(projectID: UUID, sessionID: UUID, enabled: Bool) {
        runtimes[sessionID] = Runtime(projectID: projectID, sessionID: sessionID, enabled: enabled)
        states[sessionID] = State(text: enabled ? "等待 VM Service · Release / Web 可能不支持" : "未开启采集")
    }
    func discovered(_ endpoint: VMServiceEndpoint, sessionID: UUID) {
        guard let runtime = runtimes[sessionID], runtime.endpoint != endpoint else { return }
        let oldTask = runtime.task, oldCapture = runtime.capture
        let oldBodyTask = cancelBody(runtime)
        runtime.generation = UUID(); runtime.task?.cancel(); runtime.task = nil; runtime.capture = nil
        runtime.endpoint = endpoint
        // Joining the old operation prevents a previous connection from writing
        // into the same SQLite cache after the new one starts.
        runtime.task = Task { [weak self, weak runtime] in
            await oldTask?.value
            await oldBodyTask?.value
            try? await oldCapture?.finish()
            guard let self, let runtime, !Task.isCancelled, self.runtimes[sessionID] === runtime else { return }
            runtime.task = nil
            self.startReading(runtime)
        }
    }
    func setEnabled(_ enabled: Bool, projectID: UUID) {
        for runtime in runtimes.values where runtime.projectID == projectID {
            runtime.enabled = enabled
            if enabled { runtime.paused = false }
            else {
                _ = cancelBody(runtime)
                states[runtime.sessionID] = State(text: "未开启接收 · 目标采集缓冲可能仍在记录")
            }
            transition(runtime)
        }
        revision += 1
    }
    func togglePause(_ id: UUID) {
        guard let runtime = runtimes[id], runtime.enabled else { return }
        runtime.paused.toggle()
        if runtime.paused {
            states[id] = State(text: "已暂停接收", paused: true)
        }
        transition(runtime)
    }
    private func transition(_ runtime: Runtime) {
        let old = runtime.task; old?.cancel()
        let generation = UUID(); runtime.generation = generation
        runtime.task = Task { [weak self, weak runtime] in
            await old?.value
            guard let self, let runtime, !Task.isCancelled, runtime.generation == generation else { return }
            runtime.task = nil; self.startReading(runtime)
        }
    }
    private func startReading(_ runtime: Runtime) {
        guard runtime.enabled, runtime.task == nil else { return }
        guard let endpoint = runtime.endpoint, let directory = directory(runtime.sessionID) else {
            states[runtime.sessionID] = State(text: "等待 VM Service · Release / Web 可能不支持"); return
        }
        let capture = runtime.capture ?? NetworkCaptureSession(directory: directory, endpoint: endpoint)
        runtime.capture = capture
        let generation = UUID(); runtime.generation = generation
        states[runtime.sessionID] = State(text: "正在连接")
        runtime.task = Task { [weak self, weak runtime] in
            var failures = 0, storageFailures = 0, nextSummary = Date.distantPast, lastPublication = Date.distantPast
            var unpublished = false
            while !Task.isCancelled {
                guard let runtime else { return }
                var pending = 0
                do {
                    var refreshed = false
                    if !runtime.paused && Date() >= nextSummary {
                        runtime.latestUpdate = try await capture.poll(cacheBodies: false)
                        nextSummary = Date().addingTimeInterval(1); refreshed = true
                        unpublished = unpublished || (runtime.latestUpdate?.requestsUpdated ?? 0) > 0
                    }
                    let drain = try await capture.drainPendingBodies(refreshIncomplete: runtime.paused)
                    guard !Task.isCancelled, runtime.generation == generation else { return }
                    failures = 0; storageFailures = 0; pending = drain.pending
                    unpublished = unpublished || drain.processed > 0
                    let suffix = pending > 0 ? " · 正文待缓存 \(pending) 条" : ""
                    let text = runtime.paused ? "已暂停接收" + suffix :
                        runtime.latestUpdate?.supported == true ? "采集中" + suffix : "等待 HTTP 采集扩展 · 当前进程可能不支持"
                    // Catch up in small continuous batches, but never redraw the
                    // main window at the per-request / per-batch frequency.
                    if refreshed || Date().timeIntervalSince(lastPublication) >= 0.25 || (pending == 0 && drain.processed > 0) {
                        let state = State(text: text, paused: runtime.paused,
                                          canResumeApplication: runtime.latestUpdate?.pausedIsolates.isEmpty == false)
                        if self?.states[runtime.sessionID] != state { self?.states[runtime.sessionID] = state }
                        if unpublished { self?.revision += 1; unpublished = false }
                        lastPublication = Date()
                    }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, runtime.generation == generation else { return }
                    if let storage = error as? NetworkStorageError, storage.isTransient {
                        // Only a complete successful pass resets the budgets;
                        // alternating transport/cache failures stay bounded.
                        storageFailures += 1
                        if let delay = NetworkStorageRetry.delay(for: storage, failure: storageFailures) {
                            self?.states[runtime.sessionID] = State(
                                text: "缓存暂时繁忙，正在重试（\(storageFailures)/\(NetworkStorageRetry.maximumRetries)）· \(storage.localizedDescription)",
                                paused: runtime.paused)
                            self?.revision += 1
                            do { try await Task.sleep(for: delay) } catch { return }
                            continue
                        }
                        self?.states[runtime.sessionID] = State(
                            text: storage.localizedDescription + "；重试后仍未恢复，已暂停接收，可点击「继续」重试。",
                            paused: true, error: true)
                        self?.revision += 1
                        runtime.paused = true; runtime.task = nil; return
                    }
                    failures += 1
                    let retry = (error as? VMServiceError) == .unavailable && failures < 10
                    self?.states[runtime.sessionID] = State(text: retry ? "连接中断，正在重试（\(failures)/10）" : error.localizedDescription,
                                                          paused: !retry, error: true)
                    self?.revision += 1
                    if !retry { runtime.paused = true; runtime.task = nil; return }
                }
                do { try await Task.sleep(for: .milliseconds(failures > 0 ? 3000 : pending > 0 ? 10 : 200)) } catch { return }
            }
        }
    }
    /// One cancellable priority slot, independent of receiving new summaries.
    /// Selecting while paused may retrieve this already-recorded request.
    func prioritizeBody(_ id: String, sessionID: UUID) {
        guard let runtime = runtimes[sessionID], runtime.enabled, let capture = runtime.capture,
              runtime.bodyRequestID != id || runtime.bodyTask == nil else { return }
        let old = cancelBody(runtime), generation = UUID()
        runtime.bodyGeneration = generation; runtime.bodyRequestID = id
        loadingBodies.insert(id)
        runtime.bodyTask = Task { [weak self, weak runtime] in
            await old?.value
            guard let self, let runtime, !Task.isCancelled, runtime.bodyGeneration == generation else { return }
            do {
                var failures = 0
                while true {
                    do { _ = try await capture.cacheBody(id); break }
                    catch {
                        failures += 1
                        guard let delay = NetworkStorageRetry.delay(for: error, failure: failures) else { throw error }
                        try await Task.sleep(for: delay)
                    }
                }
                guard !Task.isCancelled, runtime.bodyGeneration == generation else { return }
            } catch {
                guard !Task.isCancelled, runtime.bodyGeneration == generation else { return }
                self.bodyErrors[id] = error.localizedDescription
            }
            self.loadingBodies.remove(id); runtime.bodyTask = nil
            self.revision += 1
        }
    }
    @discardableResult
    private func cancelBody(_ runtime: Runtime) -> Task<Void, Never>? {
        let old = runtime.bodyTask; old?.cancel(); runtime.bodyTask = nil; runtime.bodyGeneration = UUID()
        if let id = runtime.bodyRequestID { loadingBodies.remove(id); bodyErrors[id] = nil }
        runtime.bodyRequestID = nil; return old
    }

    func clearTargetBuffer(_ id: UUID) {
        perform(id) { try await $0.clearTargetBuffer() }
    }
    func resumeApplication(_ id: UUID) {
        perform(id) { try await $0.resumePausedApplication() }
    }
    private func perform(_ id: UUID, operation: @escaping (NetworkCaptureSession) async throws -> Void) {
        guard let runtime = runtimes[id], let capture = runtime.capture else { return }
        let old = runtime.task, oldBody = cancelBody(runtime)
        runtime.generation = UUID(); runtime.task?.cancel(); runtime.task = nil
        runtime.task = Task { [weak self, weak runtime] in
            await old?.value
            await oldBody?.value
            guard let self, let runtime, self.runtimes[id] === runtime, !Task.isCancelled else { return }
            do {
                try await operation(capture)
                guard !Task.isCancelled else { return }
                runtime.task = nil; self.revision += 1
                self.startReading(runtime)
            } catch {
                guard !Task.isCancelled else { return }
                runtime.task = nil; runtime.paused = true
                self.states[id] = State(text: error.localizedDescription, paused: true, error: true)
            }
        }
    }
    var writingSessionIDs: Set<UUID> { Set(runtimes.keys).union(finishing.keys) }
    func isLive(_ id: UUID) -> Bool { runtimes[id] != nil }
    func hasConnection(_ id: UUID) -> Bool { runtimes[id]?.capture != nil }
    func finished(_ id: UUID) {
        guard let runtime = runtimes.removeValue(forKey: id) else { return }
        let old = runtime.task, oldBody = cancelBody(runtime); runtime.generation = UUID(); old?.cancel()
        states[id] = nil
        finishing[id] = Task { [weak self] in
            await old?.value
            await oldBody?.value
            do { try await runtime.capture?.finish() }
            catch { self?.states[id] = State(text: "采集已结束；网络缓存收尾失败", error: true) }
            self?.finishing[id] = nil; self?.revision += 1
            self?.onFinished?()
        }
    }
    func shutdown() async {
        for id in Array(runtimes.keys) { finished(id) }
        for task in Array(finishing.values) { await task.value }
    }
}
