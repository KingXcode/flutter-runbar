import Foundation
import RunbarCore

extension AppModel {
    /// Only snapshots memory on the main actor. MCP disk reads never depend on
    /// the selected project, log page, network filter or active UI tab.
    func mcpSnapshot() -> RunbarMCPSnapshot {
        var live: [UUID: RunbarMCPRuntime] = [:]
        let projects = config.projects.map { project -> RunbarMCPSource in
            let state = state(for: project.id), id = state.isBusy ? state.session?.id : nil
            if let id {
                live[id] = RunbarMCPRuntime(phase: String(describing: state.phase), networkState: network.states[id]?.text ?? "未开启采集")
            }
            return RunbarMCPSource(id: "project:" + project.id.uuidString, key: project.path, name: project.name,
                                   path: project.path, kind: project.kind.rawValue, activeSessionID: id)
        }
        let apps = applications.map { application -> RunbarMCPSource in
            let state = applicationConnections[application.id], id = state?.active == true ? state?.sessionID : nil
            if let id {
                live[id] = RunbarMCPRuntime(phase: state.map { String(describing: $0.phase) } ?? "idle",
                                           processID: state?.candidate?.processID, networkState: network.states[id]?.text ?? "未开启采集")
            }
            return RunbarMCPSource(id: "app:" + application.id.uuidString, key: "app:" + application.id.uuidString,
                                   name: application.name, path: application.bundlePath, kind: "attachedApp", activeSessionID: id)
        }
        return RunbarMCPSnapshot(sources: projects + apps, sessions: history, live: live)
    }
}
