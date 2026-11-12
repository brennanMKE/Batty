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
            let captured = capture(root: project.rootPath)
            var draft = captured.updateDraft(of: project)
            captureBackground(of: session, into: &draft, replacingStored: session.backgroundOverride != session.projectBackgroundSeed, store: store)
            captureTabBackgrounds(of: session, capture: captured, into: &draft, isUpdate: true, store: store)
            if session.themeOverride != session.projectThemeSeed {
                draft.theme = session.themeOverride
            }
            return draft
        }
        let captured = capture(root: nil)
        let name = SessionProjectCapture.suggestedName(session: session, capture: captured, nameForRoot: nameForRoot)
        var draft = captured.newDraft(name: name, existingNames: projectStore.projects.map(\.name))
        captureBackground(of: session, into: &draft, replacingStored: true, store: store)
        captureTabBackgrounds(of: session, capture: captured, into: &draft, isUpdate: false, store: store)
        draft.theme = session.themeOverride
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
        if !notes.isEmpty { draft.captureNotes[.background] = notes.joined(separator: " ") }
    }

    /// Each Tab takes its own value, else its Pane's, so a Pane's value becomes
    /// every Tab's in that Pane. An Update writes a Tab only when its value or
    /// its Pane's changed since the open; otherwise the stored value stays.
    private static func captureTabBackgrounds(
        of session: SessionRuntime,
        capture: SessionProjectCapture,
        into draft: inout ProjectDraft,
        isUpdate: Bool,
        store: AppStateStore
    ) {
        var runtime: [UUID: (tab: TabRuntime, pane: PaneRuntime)] = [:]
        for pane in session.tree.allPanes where pane.kind == .terminal {
            for tab in pane.tabs { runtime[tab.id] = (tab, pane) }
        }
        var adopted: [String: String?] = [:]
        var failed: [ProjectEditorField] = []
        let identity = store.tabImageIdentity
        let root = draft.layout.root.mappingPanes { slot, pane in
            guard pane.kind == .terminal, let ids = capture.tabIDs[slot] else { return pane }
            var edited = pane
            for index in edited.tabs.indices where ids.indices.contains(index) {
                guard let (tab, owner) = runtime[ids[index]] else { continue }
                if isUpdate, tab.backgroundOverride == tab.projectBackgroundSeed, owner.backgroundOverride == nil { continue }
                var value = tab.backgroundOverride ?? owner.backgroundOverride
                if let path = value?.imagePath {
                    let copy = adopted[path] ?? store.projectBackgrounds.adopt(path: path)
                    adopted[path] = copy
                    value = value?.withImagePath(copy)
                    if copy == nil { failed.append(.tabBackground(slot: slot, tab: index)) }
                }
                let stored = edited.tabs[index]
                edited.tabs[index].background = value
                edited.tabs[index].image = if value == nil {
                    nil
                } else if isUpdate, value?.imagePath == stored.background?.imagePath {
                    stored.image
                } else {
                    identity.identity(forPath: value?.imagePath, keeping: isUpdate ? stored.image : nil, previousPath: isUpdate ? stored.background?.imagePath : nil)
                }
            }
            return edited
        }
        draft.layout.root = root
        for field in failed {
            draft.captureNotes[field] = String(localized: "This Tab's image could not be copied, so it has no image. Choose it again.", comment: "Project Editor: Save as Project could not copy a Tab's background image")
        }
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
