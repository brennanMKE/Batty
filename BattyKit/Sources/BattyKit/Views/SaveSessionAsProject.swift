// SaveSessionAsProject.swift

import Foundation

/// The shared action behind every "Save as Project" entry point. It captures
/// the Session, builds a draft, and opens the Project Editor on it; the
/// Project is stored only when the user clicks Save there.
@MainActor
enum SaveSessionAsProject {
    enum Destination: Equatable {
        case newProject
        case update(UUID)
    }

    static func menuModel(store: AppStateStore, session: SessionRuntime?) -> SaveSessionAsProjectMenuModel {
        let backing = session?.projectID.flatMap { store.projectStore.project(id: $0) }
        return SaveSessionAsProjectMenuModel.make(hasSession: session != nil, backingProject: backing)
    }

    /// The draft for `destination`. An update is
    /// honored only for a Session opened from that Project, which still must
    /// exist; otherwise (a menu item gone stale after the key Window changed,
    /// or a deleted Project) it becomes a new Project.
    static func draft(
        for session: SessionRuntime,
        destination: Destination,
        store: AppStateStore,
        gitDirectory: (@MainActor (PaneRuntime) -> String?)? = nil,
        nameForRoot: @MainActor (String) -> String? = ProjectEditorViewModel.suggestedName(forRoot:)
    ) -> ProjectDraft {
        let projectStore = store.projectStore
        func capture(root: String?) -> SessionProjectCapture {
            if let gitDirectory {
                return SessionProjectCapture.capture(session: session, root: root, gitDirectory: gitDirectory)
            }
            return SessionProjectCapture.capture(session: session, root: root)
        }
        if case .update(let id) = destination, session.projectID == id, let project = projectStore.project(id: id) {
            return capture(root: project.rootPath).updateDraft(of: project)
        }
        let captured = capture(root: nil)
        let name = SessionProjectCapture.suggestedName(session: session, capture: captured, nameForRoot: nameForRoot)
        return captured.newDraft(name: name, existingNames: projectStore.projects.map(\.name))
    }

    @discardableResult
    static func begin(
        session: SessionRuntime?,
        destination: Destination,
        store: AppStateStore,
        open: @MainActor (AppStateStore, ProjectDraft) -> Void = { store, draft in
            ProjectEditorWindowController.shared.show(store: store, newDraft: draft)
        }
    ) -> Bool {
        guard let session else { return false }
        let draft = draft(for: session, destination: destination, store: store)
        open(store, draft)
        return true
    }
}
