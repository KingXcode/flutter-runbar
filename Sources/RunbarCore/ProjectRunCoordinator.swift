import Foundation

public enum ProjectRunPhase: Equatable { case idle, starting, running, stopping }

public struct ProjectRunState {
    public var phase: ProjectRunPhase = .idle
    public var session: RunSession?
    public var command: String?
    public var error: String?
    public var isBusy: Bool { phase != .idle }
    // Links are valid only for the owning run, never during stop or from history.
    public var liveDevToolsURLs: [String] {
        guard phase == .running else { return [] }
        return session?.devToolsURLs.filter { DevToolsLink.validatedURL($0) != nil } ?? []
    }
    public init() {}
}

public enum DevToolsLink {
    public static func validatedURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}

public protocol ProjectCommandRunning: AnyObject {
    func start(project: Project, preset: CommandPreset, extraPath: String)
    func stop()
}
extension ProcessRunner: ProjectCommandRunning {
    public func start(project: Project, preset: CommandPreset, extraPath: String) {
        run(project: project, preset: preset, extraPath: extraPath)
    }
}

/// Main-actor state machine. Each project owns a fresh runner and generation token.
/// Retains runners through terminal completion; stale callbacks cannot affect a new run.
@MainActor
public final class ProjectRunCoordinator {
    public enum Event {
        case stateChanged(UUID, ProjectRunState)
        case started(UUID, RunSession)
        case output(projectID: UUID, sessionID: UUID, text: String)
        case updated(UUID, RunSession)
        case finished(UUID, RunSession)
        case failure(UUID, String)
    }
    public typealias Factory = (SessionStore, @escaping (ProcessRunner.Event) -> Void) -> ProjectCommandRunning
    public var onEvent: ((Event) -> Void)?
    public private(set) var states: [UUID: ProjectRunState] = [:]
    public var isBusy: Bool { states.values.contains(where: \.isBusy) }
    private let store: SessionStore
    private let factory: Factory
    private var runners: [UUID: ProjectCommandRunning] = [:]
    private var generations: [UUID: UUID] = [:]
    private var activePaths: [UUID: String] = [:]
    private var displayBuffers: [UUID: String] = [:]

    public init(store: SessionStore, factory: @escaping Factory = { store, handler in ProcessRunner(store: store, handler: handler) }) {
        self.store = store; self.factory = factory
    }
    public func state(for id: UUID) -> ProjectRunState { states[id] ?? ProjectRunState() }
    public func liveLog(for sessionID: UUID) -> String? {
        guard let id = states.first(where: { $0.value.isBusy && $0.value.session?.id == sessionID })?.key else { return nil }
        return displayBuffers[id] ?? ""
    }
    @discardableResult
    public func start(project: Project, preset: CommandPreset, extraPath: String) -> Bool {
        guard preset.builtInAction == nil else {
            onEvent?(.failure(project.id, "内置操作不能作为 shell 命令运行。")); return false
        }
        guard !state(for: project.id).isBusy else { return false }
        guard !preset.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onEvent?(.failure(project.id, "命令不能为空。")); return false
        }
        let path = URL(fileURLWithPath: project.path).standardizedFileURL.resolvingSymlinksInPath().path
        guard !activePaths.values.contains(path) else {
            onEvent?(.failure(project.id, "该项目目录已有运行中的命令。")); return false
        }
        let generation = UUID()
        generations[project.id] = generation; activePaths[project.id] = path
        displayBuffers[project.id] = ""
        var state = ProjectRunState(); state.phase = .starting; state.command = preset.command
        update(project.id, state)
        let runner = factory(store) { [weak self] event in
            // ProcessRunner's documented delivery queue is the main queue.
            self?.handle(event, projectID: project.id, generation: generation)
        }
        runners[project.id] = runner
        runner.start(project: project, preset: preset, extraPath: extraPath)
        return true
    }
    public func stop(projectID: UUID) {
        var state = state(for: projectID)
        guard state.isBusy, state.phase != .stopping else { return }
        state.phase = .stopping; update(projectID, state)
        runners[projectID]?.stop()
    }
    public func stopAll() {
        for id in Array(runners.keys) { stop(projectID: id) }
    }
    private func update(_ id: UUID, _ state: ProjectRunState) {
        states[id] = state; onEvent?(.stateChanged(id, state))
    }
    private func clear(_ id: UUID, error: String?) {
        runners[id] = nil; generations[id] = nil; activePaths[id] = nil; displayBuffers[id] = nil
        var state = ProjectRunState(); state.error = error; update(id, state)
    }
    private func handle(_ event: ProcessRunner.Event, projectID: UUID, generation: UUID) {
        guard generations[projectID] == generation else { return }
        var state = state(for: projectID)
        switch event {
        case .started(let session):
            state.session = session
            if state.phase != .stopping { state.phase = .running }
            update(projectID, state); onEvent?(.started(projectID, session))
        case .output(let text):
            if let session = state.session {
                var buffer = displayBuffers[projectID] ?? ""
                buffer += text
                if buffer.utf8.count > 200_000 {
                    buffer = "[实时视图已截断；完整输出仍保存在本地]\n" + String(decoding: buffer.utf8.suffix(100_000), as: UTF8.self)
                }
                displayBuffers[projectID] = buffer
                onEvent?(.output(projectID: projectID, sessionID: session.id, text: text))
            }
        case .updated(let session):
            guard state.session?.id == session.id else { return }
            state.session = session; update(projectID, state); onEvent?(.updated(projectID, session))
        case .finished(let session):
            // Launch failure can finish without .started; generation still owns it.
            clear(projectID, error: session.error); onEvent?(.finished(projectID, session))
        case .failure(let message):
            state.error = message; state.phase = .stopping; update(projectID, state)
            runners[projectID]?.stop(); onEvent?(.failure(projectID, message))
        case .rejected(let message):
            clear(projectID, error: message); onEvent?(.failure(projectID, message))
        }
    }
}
