// AppStateStore+ProjectXPC.swift

import BattyXPCCore
import Foundation

extension AppStateStore {
    public enum ProjectOpenXPCOutcome: Equatable {
        case opened(ProjectOpenReply)
        case failed(String)
    }

    /// The `projectList` verb's reply.
    public func projectListReplyForXPC() -> ProjectListReply {
        let open = openProjectIDs
        return ProjectListReply(projects: ProjectRecency.ranked(projectStore.projects, openProjectIDs: open).map {
            ProjectListEntry(
                id: $0.id, name: $0.name, rootPath: $0.rootPath,
                paneCount: $0.layout.paneCount, isOpen: open.contains($0.id))
        })
    }

    /// The `projectOpen` verb: opens or focuses the Project called `name`
    /// through `requestOpenProject`, so the startup-command trust sheet
    /// applies exactly as it does for the GUI. `completion` runs once, when
    /// the Session exists or the open failed, and after the user's answer when
    /// the sheet is shown. Returns the matched Project's stored name and, while
    /// the sheet is pending, the trust request's id so the caller can withdraw
    /// it; nil when the name matched nothing.
    @discardableResult
    public func openProjectForXPC(
        name: String,
        openNew: Bool,
        completion: @escaping (ProjectOpenXPCOutcome) -> Void
    ) -> (projectName: String, trustRequestID: UUID?)? {
        let projectStore = self.projectStore
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let project = projectStore.project(named: trimmed) else {
            completion(.failed(Self.unknownProjectMessage(trimmed, names: projectStore.projects.map(\.name))))
            return nil
        }
        let trustRequestID = requestOpenProject(
            id: project.id,
            mode: openNew ? .openNew : .focusExistingOrOpen,
            fromCli: true,
            completion: { result in
                switch result {
                case .success(let opened):
                    completion(.opened(ProjectOpenReply(
                        status: .opened,
                        name: project.name,
                        sessionID: opened.session.id,
                        paneID: opened.session.tree.focusedPaneID,
                        created: opened.wasCreated)))
                case .failure(ProjectOpenError.cancelled):
                    completion(.failed("the startup-commands prompt for \"\(project.name)\" was dismissed in Batty; nothing was opened"))
                case .failure(let error):
                    completion(.failed(error.localizedDescription))
                }
            })
        return (project.name, trustRequestID)
    }

    static func unknownProjectMessage(_ name: String, names: [String]) -> String {
        guard !names.isEmpty else {
            return "no Project named \"\(name)\" (there are no saved Projects)"
        }
        let close = ProjectNameMatching.closeMatches(to: name, in: names)
        if close.isEmpty {
            return "no Project named \"\(name)\"; run `batty project list` to see the saved Projects"
        }
        return "no Project named \"\(name)\"; close matches: " + close.map { "\"\($0)\"" }.joined(separator: ", ")
    }
}
