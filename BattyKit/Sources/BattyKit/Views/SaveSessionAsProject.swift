// SaveSessionAsProject.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SaveSessionAsProject")

/// The shared action behind every "Save as Project" entry point. It captures
/// the Session, builds a draft, and opens the Project Editor on it; the
/// Project is stored only when the user clicks Save there.
@MainActor
enum SaveSessionAsProject {
    enum Destination: Equatable {
        case newProject
        case update(UUID)
    }

    /// Nil with the flag off. `store.projectStore` is read only past the gate.
    static func menuModel(store: AppStateStore, session: SessionRuntime?) -> SaveSessionAsProjectMenuModel? {
        let enabled = ProjectEditorWindowController.isAvailable(featureFlags: store.featureFlags)
        let backing = enabled ? session?.projectID.flatMap { store.projectStore?.project(id: $0) } : nil
        return SaveSessionAsProjectMenuModel.make(featureEnabled: enabled, hasSession: session != nil, backingProject: backing)
    }

    /// The draft for `destination`, or nil with the flag off. An update is
    /// honored only for a Session opened from that Project, which still must
    /// exist; otherwise (a menu item gone stale after the key Window changed,
    /// or a deleted Project) it becomes a new Project.
    static func draft(
        for session: SessionRuntime,
        destination: Destination,
        store: AppStateStore,
        gitDirectory: (@MainActor (PaneRuntime) -> String?)? = nil,
        nameForRoot: @MainActor (String) -> String? = ProjectEditorViewModel.suggestedName(forRoot:)
    ) -> ProjectDraft? {
        guard ProjectEditorWindowController.isAvailable(featureFlags: store.featureFlags),
              let projectStore = store.projectStore else {
            logger.notice("save session as project: ignored; projects feature is off")
            return nil
        }
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
        guard let session, let draft = draft(for: session, destination: destination, store: store) else { return false }
        open(store, draft)
        return true
    }
}
