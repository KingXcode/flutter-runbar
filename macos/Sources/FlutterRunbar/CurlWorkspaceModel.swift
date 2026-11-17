import Foundation
import Combine
import RunbarCore

@MainActor
final class CurlWorkspaceModel: ObservableObject {
    struct Latest {
        let project: UUID
        let run: CurlRun
        let response: CurlResponse?
    }

    @Published private(set) var projects: [CurlProject] = []
    @Published private(set) var sendingProject: UUID?
    @Published private(set) var latest: Latest?
    @Published var error: String?
    private var store: CurlWorkspaceStore?
    private var dirty = Set<UUID>()
    private var pendingSave: Task<Void, Never>?
    private var running: Task<Void, Never>?

    func configure(root: URL) {
        let store = CurlWorkspaceStore(root: root.appendingPathComponent("curl-workspace", isDirectory: true))
        self.store = store
        do { projects = try store.projects() }
        catch { self.error = "无法读取 cURL 项目：\(error.localizedDescription)" }
    }

    func project(_ id: UUID) -> CurlProject? { projects.first { $0.id == id } }

    func create(name: String, text: String = "") throws -> UUID {
        let project = CurlProject(name: name.trimmingCharacters(in: .whitespacesAndNewlines), text: text)
        try storage().save(project)
        projects.append(project)
        return project.id
    }

    func saveCapturedRequest(_ request: CurlRequest, to id: UUID) throws -> Int {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            throw RunbarError.message("这个 cURL 项目已被移除。")
        }
        var project = projects[index]
        let separator = project.text.isEmpty ? "" : "\n\n"
        project.text += separator + request.projectBlock
        let document = CurlDocument(project.text)
        guard let block = document.blocks.last, block.request == request else {
            throw RunbarError.message(document.error ?? document.blocks.last?.error ?? "无法把请求追加到项目。")
        }
        try storage().save(project)
        projects[index] = project
        dirty.remove(id)
        return block.range.location
    }

    func rename(_ id: UUID, to name: String) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var project = projects[index]
        project.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try storage().save(project)
        projects[index] = project
        dirty.remove(id)
    }

    func edit(_ id: UUID, text: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }), projects[index].text != text else { return }
        guard text.utf8.count <= CurlDocument.maximumBytes else { error = "编辑区最多保存 256 KiB 的文本。"; return }
        projects[index].text = text
        dirty.insert(id)
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flush()
        }
    }

    func flush() {
        pendingSave?.cancel(); pendingSave = nil
        for id in Array(dirty) {
            guard let project = project(id) else { dirty.remove(id); continue }
            do { try storage().save(project); dirty.remove(id) }
            catch { self.error = "编辑内容尚未保存：\(error.localizedDescription)" }
        }
    }

    func remove(_ id: UUID) throws {
        guard sendingProject != id else { throw RunbarError.message("请先取消正在发送的请求。") }
        try storage().removeProject(id)
        projects.removeAll { $0.id == id }
        dirty.remove(id)
        if latest?.project == id { latest = nil }
    }

    func history(_ id: UUID) async throws -> [CurlRun] {
        let store = try storage()
        return try await Task.detached(priority: .utility) { try store.history(id) }.value
    }

    func response(_ run: CurlRun, project id: UUID) async throws -> CurlResponse? {
        if latest?.run.id == run.id { return latest?.response }
        let store = try storage()
        return try await Task.detached(priority: .utility) { try store.response(run, project: id) }.value
    }

    func clearHistory(_ id: UUID) throws {
        guard sendingProject != id else { throw RunbarError.message("请先取消正在发送的请求。") }
        try storage().clearHistory(id)
        if latest?.project == id { latest = nil }
    }

    func send(_ request: CurlRequest, project id: UUID) {
        guard running == nil, project(id) != nil else { return }
        flush()
        sendingProject = id
        let date = Date()
        running = Task { [weak self] in
            let response: CurlResponse?
            let message: String?
            do {
                response = try await CurlClient.send(request)
                message = nil
            } catch {
                response = nil
                message = error is CancellationError ? "已取消请求。" : error.localizedDescription
            }
            guard let self else { return }
            let run = CurlRun(date: date, request: request, response: response?.head, error: message)
            do {
                let store = try storage()
                _ = try await Task.detached(priority: .utility) { try store.record(run, body: response?.body, project: id) }.value
            } catch {
                self.error = "未能保存请求历史：\(error.localizedDescription)"
            }
            latest = Latest(project: id, run: run, response: response)
            running = nil; sendingProject = nil
        }
    }

    func cancel(_ id: UUID) { if sendingProject == id { running?.cancel() } }

    private func storage() throws -> CurlWorkspaceStore {
        guard let store else { throw RunbarError.message("cURL 项目存储不可用。") }
        return store
    }
}
