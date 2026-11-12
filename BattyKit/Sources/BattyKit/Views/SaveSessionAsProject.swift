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
            captureState(of: session, capture: captured, into: &draft, stored: project, store: store)
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, title != project.name { draft.name = title }
            if session.sessionColor != project.color {
                draft.color = session.sessionColor
                draft.customColorHex = nil
            }
            return draft
        }
        let captured = capture(root: nil)
        let name = SessionProjectCapture.suggestedName(session: session, capture: captured, nameForRoot: nameForRoot)
        var draft = captured.newDraft(name: name, existingNames: projectStore.projects.map(\.name))
        captureState(of: session, capture: captured, into: &draft, stored: nil, store: store)
        return draft
    }

    /// Everything the Session shows that the layout capture doesn't: the
    /// backgrounds at every level, the Theme, mute and the Pane list. Here and
    /// not in `SessionProjectCapture`, which writes nothing and also serves
    /// Copy from Current Session: an image has to be copied into the Project
    /// folder, because the Session's copy can be removed.
    private static func captureState(
        of session: SessionRuntime,
        capture: SessionProjectCapture,
        into draft: inout ProjectDraft,
        stored: Project?,
        store: AppStateStore
    ) {
        captureBackground(of: session, into: &draft, stored: stored, store: store)
        captureLevelBackgrounds(of: session, capture: capture, into: &draft, stored: stored, store: store)
        draft.theme = session.themeOverride
        draft.notificationsMuted = session.notificationsMuted
        draft.paneListExpanded = session.isPaneListExpanded
    }

    /// An image the Session opened without (missing, rejected or still on
    /// its way) is kept as stored, so Update doesn't erase it from the Project.
    private static func captureBackground(
        of session: SessionRuntime,
        into draft: inout ProjectDraft,
        stored: Project?,
        store: AppStateStore
    ) {
        if stored != nil, session.pendingProjectImage { return }
        var background = session.backgroundOverride
        if let path = background?.imagePath {
            let adopted = store.projectBackgrounds.adopt(path: path)
            background = background?.withImagePath(adopted)
            if adopted == nil {
                draft.captureNotes[.background] = String(localized: "The Session's image could not be copied, so this Project has no image. Choose it again.", comment: "Project Editor: Save as Project could not copy the Session's background image")
            }
        }
        draft.background = background
        if background?.imagePath == nil { draft.sharedImage = nil }
    }

    /// Each Pane and Tab takes its own value only: a Tab following its Pane
    /// stores nothing, and the Pane stores its own. A level still waiting
    /// for its image keeps the identity it opened with, with no path.
    private static func captureLevelBackgrounds(
        of session: SessionRuntime,
        capture: SessionProjectCapture,
        into draft: inout ProjectDraft,
        stored: Project?,
        store: AppStateStore
    ) {
        var panes: [UUID: PaneRuntime] = [:]
        var tabs: [UUID: TabRuntime] = [:]
        for pane in session.tree.allPanes where pane.kind == .terminal {
            panes[pane.id] = pane
            for tab in pane.tabs { tabs[tab.id] = tab }
        }
        var storedIdentities: [String: (image: ProjectTabImage, path: String)] = [:]
        for entry in stored?.layout.backgroundEntries ?? [] {
            guard let image = entry.image, let path = entry.background?.imagePath,
                  let digest = TerminalBackgroundImageImporter.digest(ofPath: path) else { continue }
            storedIdentities[digest] = storedIdentities[digest] ?? (image, path)
        }
        var adopted: [String: String?] = [:]
        var failed: [ProjectEditorField] = []
        let identity = store.tabImageIdentity

        func entry(_ own: TerminalBackgroundSettings?, pending: ProjectTabImage?, field: ProjectEditorField) -> ProjectBackgroundEntry {
            guard var value = own else { return ProjectBackgroundEntry() }
            if value.imagePath == nil, let pending { return ProjectBackgroundEntry(background: value, image: pending) }
            guard let path = value.imagePath else { return ProjectBackgroundEntry(background: value) }
            let copy = adopted[path] ?? store.projectBackgrounds.adopt(path: path)
            adopted[path] = copy
            value = value.withImagePath(copy)
            if copy == nil { failed.append(field) }
            let kept = copy.flatMap(TerminalBackgroundImageImporter.digest(ofPath:)).flatMap { storedIdentities[$0] }
            return ProjectBackgroundEntry(
                background: value,
                image: identity.identity(forPath: copy, keeping: kept?.image, previousPath: kept?.path)
            )
        }

        draft.layout.root = draft.layout.root.mappingPanes { slot, pane in
            guard pane.kind == .terminal else { return pane }
            var edited = pane
            if let id = capture.paneIDs[slot], let runtime = panes[id] {
                let captured = entry(runtime.backgroundOverride, pending: runtime.pendingImage, field: .paneBackground(slot: slot))
                edited.background = captured.background
                edited.image = captured.image
            }
            guard let ids = capture.tabIDs[slot] else { return edited }
            for index in edited.tabs.indices where ids.indices.contains(index) {
                guard let tab = tabs[ids[index]] else { continue }
                let captured = entry(tab.backgroundOverride, pending: tab.pendingTabImage, field: .tabBackground(slot: slot, tab: index))
                edited.tabs[index].background = captured.background
                edited.tabs[index].image = captured.image
            }
            return edited
        }
        for field in failed {
            draft.captureNotes[field] = if case .paneBackground = field {
                String(localized: "This Pane's image could not be copied, so it has no image. Choose it again.", comment: "Project Editor: Save as Project could not copy a Pane's background image")
            } else {
                String(localized: "This Tab's image could not be copied, so it has no image. Choose it again.", comment: "Project Editor: Save as Project could not copy a Tab's background image")
            }
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
