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
            var draft = capture(root: project.rootPath).updateDraft(of: project)
            captureBackground(of: session, into: &draft, replacingStored: session.backgroundOverride != session.projectBackgroundSeed, store: store)
            return draft
        }
        let captured = capture(root: nil)
        let name = SessionProjectCapture.suggestedName(session: session, capture: captured, nameForRoot: nameForRoot)
        var draft = captured.newDraft(name: name, existingNames: projectStore.projects.map(\.name))
        captureBackground(of: session, into: &draft, replacingStored: true, store: store)
        return draft
    }

    /// Here and not in `SessionProjectCapture`, which writes nothing and also
    /// serves Copy from Current Session: an image has to be copied into the
    /// Project folder, because the Session's copy can be removed.
    private static func captureBackground(
        of session: SessionRuntime,
        into draft: inout ProjectDraft,
        replacingStored: Bool,
        store: AppStateStore
    ) {
        guard store.featureFlags.terminalBackgrounds else { return }
        var notes: [String] = []
        if replacingStored {
            var background = session.backgroundOverride
            if let path = background?.imagePath {
                let adopted = store.projectBackgrounds.adopt(path: path)
                background = background?.withImagePath(adopted)
                if adopted == nil {
                    notes.append(String(localized: "The Session's image could not be copied, so this Project has no image. Choose it again.", comment: "Project Editor: Save as Project could not copy the Session's background image"))
                }
            }
            draft.background = background
        }
        if session.tree.allPanes.contains(where: { $0.kind == .terminal && $0.backgroundOverride != nil }) {
            notes.append(String(localized: "A Pane's own background isn't saved. A Project has one background for the whole Session.", comment: "Project Editor: Save as Project from a Session with a per-Pane background"))
        }
        if !notes.isEmpty { draft.captureNotes[.background] = notes.joined(separator: " ") }
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
