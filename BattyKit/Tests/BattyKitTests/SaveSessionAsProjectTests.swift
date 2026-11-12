// SaveSessionAsProjectTests.swift

import BattyXPCCore
import Foundation
import SwiftUI
import Testing
@testable import BattyKit

private let noContent: @MainActor (PaneContentKind) -> (any PaneContentLifecycle)? = { _ in nil }

@MainActor
private func shape(_ node: SplitTreeNode) -> String {
    switch node {
    case .leaf:
        return "L"
    case .split(_, let direction, let ratio, let left, let right):
        return "(\(direction == .horizontal ? "h" : "v") \(String(format: "%.4f", ratio)) \(shape(left)) \(shape(right)))"
    }
}

@MainActor
private final class Fixture {
    let base: URL
    let root: URL
    let projectsFile: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-save-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        projectsFile = base.appendingPathComponent("projects.json")
        for sub in ["", "src", "docs"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func store() -> AppStateStore {
        AppStateStore(
            nameCache: SessionNameCache(fileURL: base.appendingPathComponent("cache.json")),
            projectsFileURL: projectsFile
        )
    }

    func tab(_ sub: String? = nil, title: String? = nil) -> TabRuntime {
        TabRuntime(titleOverride: title, workingDirectory: sub.map { root.appendingPathComponent($0).path } ?? root.path)
    }

    func pane(_ tabs: [TabRuntime]) -> PaneRuntime {
        PaneRuntime(tabs: tabs, contentFactory: noContent)
    }

    func session(title: String = "Website", _ node: SplitTreeNode) -> SessionRuntime {
        SessionRuntime(title: title, tree: SplitTree(root: node), colorIndex: SessionColor.pink.rawValue)
    }

    /// Non-default throughout: a command, a title, a subfolder, color, toggle, approval.
    func storedProject(name: String = "Stored") -> Project {
        let layout = ProjectLayout(root: .split(direction: .vertical, children: [
            .pane(.terminal(tabs: [ProjectTab(title: "old", workingDirectory: "docs", startupCommand: "make")])),
            .pane(ProjectPane(kind: .gitStatus, repositoryPath: "src")),
        ]))
        return Project(
            name: name, rootPath: root.path, color: .teal, layout: layout,
            runStartupCommandsOnOpen: true, approvedCommandsHash: "approved", lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}

private func split(_ direction: SplitDirection, _ ratio: Double, _ left: SplitTreeNode, _ right: SplitTreeNode) -> SplitTreeNode {
    .split(id: UUID(), direction: direction, ratio: ratio, left: left, right: right)
}

@MainActor
private final class Opened {
    private(set) var drafts: [ProjectDraft] = []
    func record(_ draft: ProjectDraft) { drafts.append(draft) }
}

@MainActor
struct SessionProjectRoundTripTests {
    @Test func aHandResizedSessionOpensAtItsSizes() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let resized = fixture.session(split(
            .horizontal, 0.2,
            split(.vertical, 0.7, .leaf(fixture.pane([fixture.tab()])), .leaf(fixture.pane([fixture.tab("src", title: "src shell")]))),
            .leaf(fixture.pane([fixture.tab("docs")]))
        ))

        let draft = SaveSessionAsProject.draft(for: resized, destination: .newProject, store: store)
        let saved = draft.makeProject()
        try store.projectStore.upsert(saved)
        let result = try store.openProject(id: saved.id, mode: .openNew, contentFactory: noContent)

        #expect(shape(result.session.tree.root) == "(h 0.2000 (v 0.7000 L L) L)")
        let panes = result.session.tree.allPanes
        #expect(panes.count == 3)
        #expect(panes[1].tabs[0].titleOverride == "src shell")
        #expect(panes[1].tabs[0].terminal.configuration.workingDirectory == fixture.root.appendingPathComponent("src").path)
        #expect(panes[2].tabs[0].terminal.configuration.workingDirectory == fixture.root.appendingPathComponent("docs").path)
        #expect(result.session.title == "Website")
        #expect(result.session.sessionColor == .pink)
    }

    private static func comparable(_ project: Project) -> Project {
        var project = project
        project.modifiedAt = nil
        project.lastOpenedAt = nil
        return project
    }

    /// Every field a Project can hold, set to something other than its default.
    private func fullProject(_ fixture: ProjectBackgroundFixture) async throws -> Project {
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("src"), withIntermediateDirectories: true)
        let sessionImage = try await fixture.copy()
        let paneImage = try await fixture.copy(width: 128)
        let tabImage = try await fixture.copy(width: 64)
        let identity = fixture.appStore().tabImageIdentity
        let left = ProjectPane(
            kind: .terminal,
            tabs: [
                ProjectTab(title: "build", workingDirectory: "src", startupCommand: "make"),
                ProjectTab(workingDirectory: ".", startupCommand: "tail -f log", background: secondBackgroundValue(path: tabImage), image: identity.identity(forPath: tabImage, keeping: nil)),
            ],
            background: projectBackgroundValue(path: paneImage),
            image: identity.identity(forPath: paneImage, keeping: nil),
            activeTab: 1
        )
        let hidden = ProjectPane(kind: .terminal, tabs: [ProjectTab(title: "logs")], isHidden: true)
        let root = ProjectLayoutNode.split(direction: .horizontal, children: [
            .pane(left),
            .split(direction: .vertical, children: [.pane(ProjectPane(kind: .gitStatus, repositoryPath: "src")), .pane(hidden), .pane(.terminal())]),
        ])
        let layout = ProjectLayout(
            root: root,
            preset: SessionProjectCapture.matchingPreset(for: root),
            focusedSlot: 3,
            splitFractions: [[0.35, 0.65], [0.2, 0.3, 0.5]]
        )
        return Project(
            name: "Everything", rootPath: fixture.root.path, color: .orange, layout: layout,
            runStartupCommandsOnOpen: true,
            background: appWideBackgroundValue(path: sessionImage),
            theme: ThemePair(dark: "Nord", light: "Solarized Light"),
            notificationsMuted: true, paneListExpanded: true
        )
    }

    private func git(_ fixture: ProjectBackgroundFixture) -> @MainActor (PaneRuntime) -> String? {
        let path = fixture.root.appendingPathComponent("src").path
        return { $0.kind == .gitStatus ? path : nil }
    }

    @Test func openingThenUpdatingReproducesTheProjectExactly() async throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let project = try await fullProject(fixture)
        try store.projectStore.upsert(project)
        let stored = try #require(store.projectStore.project(id: project.id))
        let session = try store.openProject(id: project.id, mode: .openNew, contentFactory: noContent).session

        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store, gitDirectory: git(fixture))
        #expect(Self.comparable(draft.makeProject()) == Self.comparable(stored))
    }

    @Test func editsInTheSessionSurviveUpdateAndReopen() async throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let project = try await fullProject(fixture)
        try store.projectStore.upsert(project)
        let session = try store.openProject(id: project.id, mode: .openNew, contentFactory: noContent).session
        let window = try #require(store.windows.first { $0.sessions.contains { $0 === session } })
        let panes = session.tree.allPanes

        window.showPane(id: panes[2].id)
        window.hidePane(id: panes[3].id)
        panes[0].activeTabID = panes[0].tabs[0].id
        panes[0].tabs[0].setBackgroundOverride(projectBackgroundValue(path: nil))
        panes[0].tabs[1].setBackgroundOverride(nil)
        session.setBackgroundOverride(nil)
        session.themeOverride = .both("Nord")
        session.notificationsMuted = false
        session.isPaneListExpanded = false
        session.tree.focusedPaneID = panes[2].id
        if case .split(let id, _, _, _, _) = session.tree.root { session.tree.updateRatio(forSplitID: id, to: 0.6) }

        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store, gitDirectory: git(fixture))
        try store.projectStore.upsert(draft.makeProject())
        let reopened = try store.openProject(id: project.id, mode: .openNew, contentFactory: noContent).session
        let again = reopened.tree.allPanes

        #expect(again.map(\.isHidden) == [false, false, false, true])
        #expect(again[0].activeTabID == again[0].tabs[0].id)
        #expect(again[0].tabs.map(\.backgroundOverride) == [projectBackgroundValue(path: nil), nil])
        #expect(again[0].backgroundOverride?.imagePath?.hasPrefix(fixture.projectFolder.path) == true)
        #expect(again[0].tabs.map(\.projectStartupCommand) == ["make", "tail -f log"])
        #expect(reopened.backgroundOverride == nil)
        #expect(reopened.themeOverride == .both("Nord"))
        #expect(!reopened.notificationsMuted)
        #expect(!reopened.isPaneListExpanded)
        #expect(reopened.tree.focusedPaneID == again[2].id)
        guard case .split(_, _, let ratio, _, _) = reopened.tree.root else {
            Issue.record("the root is not a split")
            return
        }
        #expect(abs(ratio - 0.6) < 0.0001)
    }
}

@MainActor
struct SaveSessionAsProjectEntryTests {
    @Test func theMenuModelDependsOnTheSessionAndTheBackingProject() {
        let backing = Project(name: "Backing", rootPath: "/Users/test/a")
        let plain = SaveSessionAsProjectMenuModel.make(hasSession: true, backingProject: nil)
        #expect(plain == SaveSessionAsProjectMenuModel(isEnabled: true, updateTarget: nil))
        #expect(SaveSessionAsProjectMenuModel.make(hasSession: false, backingProject: nil).isEnabled == false)

        let updating = SaveSessionAsProjectMenuModel.make(hasSession: true, backingProject: backing)
        #expect(updating.updateTarget == .init(id: backing.id, name: "Backing"))
    }

    @Test func theMenuModelFindsTheBackingProject() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.storedProject()
        try store.projectStore.upsert(project)
        let session = fixture.session(.leaf(fixture.pane([fixture.tab()])))

        #expect(SaveSessionAsProject.menuModel(store: store, session: session).updateTarget == nil)
        #expect(SaveSessionAsProject.menuModel(store: store, session: nil).isEnabled == false)

        store.windows[0].selectedSession?.projectID = project.id
        let backed = store.windows[0].selectedSession
        #expect(SaveSessionAsProject.menuModel(store: store, session: backed).updateTarget?.name == "Stored")

        try store.projectStore.delete(id: project.id)
        #expect(SaveSessionAsProject.menuModel(store: store, session: backed).updateTarget == nil, "a deleted Project is no longer offered")
    }

    @Test func savingAsNewOpensTheEditorOnADraftAndStoresNothing() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let other = fixture.storedProject(name: "Website")
        try store.projectStore.upsert(other)
        let before = try Data(contentsOf: fixture.projectsFile)
        let session = fixture.session(.leaf(fixture.pane([fixture.tab(), fixture.tab("src")])))
        let opened = Opened()

        let began = SaveSessionAsProject.begin(session: session, destination: .newProject, store: store, open: { opened.record($1) })
        #expect(began)

        let draft = try #require(opened.drafts.first)
        #expect(opened.drafts.count == 1)
        #expect(draft.name == "Website 2", "the Session title is taken, so the name is numbered")
        #expect(draft.color == .pink)
        #expect(draft.rootPath == fixture.root.path)
        #expect(draft.runStartupCommandsOnOpen)
        #expect(draft.layout.panes[0].tabs.map(\.workingDirectory) == [".", "src"])
        #expect(try Data(contentsOf: fixture.projectsFile) == before)
        #expect(store.projectStore.projects.map(\.name) == ["Website"])
    }

    @Test func aSessionAtHomeCapturesHomeRootWithANoteAndNoSuggestedName() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let home = NSHomeDirectory()
        let session = fixture.session(title: "Session 1", .leaf(fixture.pane([TabRuntime(workingDirectory: home)])))

        let draft = SaveSessionAsProject.draft(for: session, destination: .newProject, store: store)

        #expect(draft.rootPath == home)
        #expect(draft.name == ProjectEditorViewModel.untitledName)
        #expect(draft.captureNotes[.root] != nil)
        let model = ProjectEditorViewModel(store: store.projectStore)
        _ = model.requestNavigation(.newDraft(draft))
        let validation = model.validate()
        #expect(validation.warnings[.root] != nil)
        #expect(validation.errors[.root] == nil)
    }

    @Test func updateReplacesLayoutAndTabsButKeepsCommandsAndApprovalOnlyAfterSave() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let seed = fixture.storedProject()
        let projectStore = store.projectStore
        try projectStore.upsert(seed)
        let stored = try #require(projectStore.project(id: seed.id))
        let openedTab = fixture.tab("src")
        openedTab.projectStartupCommand = "make"
        let session = fixture.session(title: "Stored", .leaf(fixture.pane([openedTab])))
        session.colorIndex = SessionColor.teal.rawValue
        session.projectID = stored.id
        let opened = Opened()

        SaveSessionAsProject.begin(session: session, destination: .update(stored.id), store: store, open: { opened.record($1) })
        let draft = try #require(opened.drafts.first)
        #expect(projectStore.project(id: stored.id) == stored, "nothing is stored before Save")

        let model = ProjectEditorViewModel(store: projectStore)
        model.requestNavigation(.newDraft(draft))
        model.cancel()
        #expect(projectStore.project(id: stored.id) == stored, "Cancel leaves the Project as it was")

        model.requestNavigation(.newDraft(draft))
        let saved = try #require(model.save())
        #expect(saved.id == stored.id)
        #expect(saved.layout.paneCount == 1)
        #expect(saved.layout.panes[0].tabs.map(\.workingDirectory) == ["src"])
        #expect(saved.layout.panes[0].tabs.map(\.startupCommand) == ["make"])
        #expect(saved.approvedCommandsHash == "approved")
        #expect(saved.name == "Stored" && saved.color == .teal && saved.runStartupCommandsOnOpen)
        #expect(projectStore.projects.count == 1)
    }

    @Test func anUpdateIsHonoredOnlyForASessionOpenedFromThatProject() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let seed = fixture.storedProject()
        let projectStore = store.projectStore
        try projectStore.upsert(seed)
        let stored = try #require(projectStore.project(id: seed.id))
        let before = try Data(contentsOf: fixture.projectsFile)

        let unbacked = fixture.session(.leaf(fixture.pane([fixture.tab("src")])))
        let other = fixture.session(.leaf(fixture.pane([fixture.tab("src")])))
        other.projectID = UUID()
        let backedTab = fixture.tab("src")
        backedTab.projectStartupCommand = "make"
        let backed = fixture.session(.leaf(fixture.pane([backedTab])))
        backed.projectID = stored.id

        for stale in [unbacked, other] {
            let draft = SaveSessionAsProject.draft(for: stale, destination: .update(stored.id), store: store)
            #expect(draft.id != stored.id, "a stale update becomes a new Project")
            #expect(draft.name == "Website")
            #expect(draft.runStartupCommandsOnOpen)
            #expect(draft.makeProject().startupCommands.isEmpty)
        }
        let update = SaveSessionAsProject.draft(for: backed, destination: .update(stored.id), store: store)
        #expect(update.id == stored.id)
        #expect(update.makeProject().startupCommands.map(\.command) == ["make"])
        #expect(projectStore.project(id: stored.id) == stored)
        #expect(try Data(contentsOf: fixture.projectsFile) == before)
    }

    @Test func anUpdateOfADeletedProjectBecomesANewProject() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        _ = store.projectStore
        let session = fixture.session(.leaf(fixture.pane([fixture.tab()])))

        let draft = SaveSessionAsProject.draft(for: session, destination: .update(UUID()), store: store)
        #expect(draft.name == "Website")
        #expect(draft.runStartupCommandsOnOpen)
    }
}

@MainActor
struct SaveSessionAsProjectPaletteTests {
    private func palette(_ store: AppStateStore, record: @escaping @MainActor (SessionRuntime?, SaveSessionAsProject.Destination) -> Void = { _, _ in }, afterDismiss: ((@escaping @MainActor () -> Void) -> Void)? = nil) -> CommandPaletteView {
        CommandPaletteView(isPresented: .constant(true), store: store, afterDismiss: afterDismiss, saveSession: record)
    }

    @Test func theEntryExists() throws {
        let fixture = try Fixture()
        let on = palette(fixture.store()).allCommands
        #expect(on.contains { $0.id == "extra:saveSessionAsProject" && $0.title == "Save Session as Project\u{2026}" })
        #expect(!on.contains { $0.id == "extra:updateSessionProject" })
        #expect(Set(on.map(\.id)).count == on.count)
    }

    @Test func withNoSelectedSessionNeitherEntryIsOffered() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        store.windows[0].selectedSessionID = nil
        #expect(store.windows[0].selectedSession == nil)

        let ids = palette(store).allCommands.map(\.id)
        #expect(!ids.contains("extra:saveSessionAsProject"))
        #expect(!ids.contains("extra:updateSessionProject"))
        #expect(ids.contains("extra:openProjectPicker"))
    }

    @Test func invokingItCapturesTheKeyWindowsSelectedSessionAfterTheSheetDismisses() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        var calls: [(UUID?, SaveSessionAsProject.Destination)] = []
        var deferred: [@MainActor () -> Void] = []
        let view = palette(store, record: { calls.append(($0?.id, $1)) }, afterDismiss: { deferred.append($0) })

        view.allCommands.first { $0.id == "extra:saveSessionAsProject" }?.action()
        #expect(calls.isEmpty)
        deferred.forEach { $0() }

        #expect(calls.count == 1)
        #expect(calls.first?.0 == store.windows[0].selectedSession?.id)
        #expect(calls.first?.1 == .newProject)
    }

    @Test func aProjectBackedSessionAlsoOffersTheUpdateEntry() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.storedProject()
        try store.projectStore.upsert(project)
        store.windows[0].selectedSession?.projectID = project.id
        var calls: [SaveSessionAsProject.Destination] = []
        let view = palette(store, record: { calls.append($1) })

        let update = try #require(view.allCommands.first { $0.id == "extra:updateSessionProject" })
        #expect(update.title == "Update Project: Stored")
        #expect(view.allCommands.first { $0.id == "extra:saveSessionAsProject" }?.title == "Save Session as New Project\u{2026}")
        update.action()
        #expect(calls == [.update(project.id)])
    }
}

@MainActor
struct CopyFromCurrentSessionTests {
    private func model(
        _ fixture: Fixture,
        _ projectStore: ProjectStore,
        capture: @escaping @MainActor (String?) -> SessionProjectCapture?
    ) -> ProjectEditorViewModel {
        ProjectEditorViewModel(store: projectStore, directoryExists: { _ in true }, captureSession: capture)
    }

    private func capture(_ fixture: Fixture, root requested: String?) -> SessionProjectCapture {
        let session = fixture.session(split(.horizontal, 0.3, .leaf(fixture.pane([fixture.tab("src", title: "api"), fixture.tab()])), .leaf(fixture.pane([fixture.tab()]))))
        return SessionProjectCapture.capture(session: session, root: requested)
    }

    @Test func aConfiguredDraftIsOnlyReplacedAfterConfirmation() throws {
        let fixture = try Fixture()
        let projectStore = ProjectStore(fileURL: fixture.projectsFile)
        let stored = fixture.storedProject()
        try projectStore.upsert(stored)
        var requestedRoots: [String?] = []
        let model = model(fixture, projectStore) { root in
            requestedRoots.append(root)
            return capture(fixture, root: root)
        }
        let before = model.draft

        #expect(model.copyFromCurrentSession() == .needsConfirmation)
        #expect(model.draft == before, "asking changes nothing")
        #expect(requestedRoots == [fixture.root.path])

        #expect(model.copyFromCurrentSession(confirmDiscard: true) == .applied)
        let draft = try #require(model.draft)
        #expect(draft.name == "Stored" && draft.color == .teal && draft.rootPath == fixture.root.path)
        #expect(draft.runStartupCommandsOnOpen)
        #expect(draft.approvedCommandsHash == "approved")
        #expect(draft.layout.preset == .horizontalSplit)
        #expect(draft.layout.panes.map(\.kind) == [.terminal, .terminal])
        #expect(draft.layout.panes[0].tabs.map(\.workingDirectory) == ["src", "."])
        #expect(draft.layout.panes[0].tabs.map(\.title) == ["api", nil])
        #expect(draft.makeProject().startupCommands.isEmpty, "the stored command was part of what was replaced")
        #expect(model.isDirty)
    }

    @Test func anUnconfiguredDraftIsReplacedWithoutAsking() throws {
        let fixture = try Fixture()
        let projectStore = ProjectStore(fileURL: fixture.projectsFile)
        let model = model(fixture, projectStore) { capture(fixture, root: $0) }
        model.requestNewProject()
        model.setRootPath(fixture.root.path)
        model.setName("Mine")

        #expect(model.copyFromCurrentSession() == .applied)
        #expect(model.draft?.layout.paneCount == 2)
        #expect(model.draft?.name == "Mine")
    }

    @Test func noSessionLeavesTheDraftAndSaysSo() throws {
        let fixture = try Fixture()
        let projectStore = ProjectStore(fileURL: fixture.projectsFile)
        try projectStore.upsert(fixture.storedProject())
        let model = model(fixture, projectStore) { _ in nil }
        let before = model.draft

        #expect(model.copyFromCurrentSession(confirmDiscard: true) == .noSession)
        #expect(model.draft == before)
        #expect(model.saveError != nil)
    }

    @Test func aCapturedNewDraftIsLocal() throws {
        let fixture = try Fixture()
        let projectStore = ProjectStore(fileURL: fixture.projectsFile)
        let draft = capture(fixture, root: fixture.root.path).newDraft(name: "Fresh", existingNames: [])
        #expect(!draft.isShared)
        let model = model(fixture, projectStore) { capture(fixture, root: $0) }
        model.requestNavigation(.newDraft(draft))
        #expect(model.copyFromCurrentSession(confirmDiscard: true) == .applied)
        #expect(model.draft?.isShared == false, "Copy from current Session never turns sharing on")
    }

    @Test func copyFromCurrentSessionLeavesASharedProjectsFlagAlone() throws {
        let fixture = try Fixture()
        let projectStore = ProjectStore(fileURL: fixture.projectsFile)
        var stored = fixture.storedProject()
        stored.isShared = true
        try projectStore.upsert(stored)
        let model = model(fixture, projectStore) { capture(fixture, root: $0) }

        #expect(model.copyFromCurrentSession(confirmDiscard: true) == .applied)

        #expect(model.draft?.isShared == true)
    }

    @Test func anEmptyRootTakesTheSessionsFolderAndAPlaceholderRootMustBeChosen() throws {
        let fixture = try Fixture()
        let projectStore = ProjectStore(fileURL: fixture.projectsFile)
        let bare = SessionProjectCapture.capture(session: fixture.session(.leaf(fixture.pane([TabRuntime()]))), homeDirectory: fixture.root.path)
        let model = model(fixture, projectStore) { _ in bare }
        model.requestNewProject()
        model.setRootPath("")

        #expect(model.copyFromCurrentSession() == .applied)
        #expect(model.draft?.rootPath == fixture.root.path)
        #expect(model.validate().errors[.root] != nil, "the placeholder root is reported until the user chooses one")
        model.setName("Named")
        #expect(!model.canSave)

        model.setRootPath(fixture.root.path)
        #expect(model.validate().errors[.root] == nil)
        #expect(model.canSave)
    }

    @Test func outsideRootNotesShowAsWarningsUntilTheFieldIsEdited() throws {
        let fixture = try Fixture()
        let projectStore = ProjectStore(fileURL: fixture.projectsFile)
        let outside = SessionProjectCapture.capture(
            session: fixture.session(.leaf(fixture.pane([fixture.tab(), TabRuntime(workingDirectory: "/elsewhere/else")]))))
        let model = model(fixture, projectStore) { _ in outside }
        model.requestNewProject()
        model.setRootPath(fixture.root.path)

        #expect(model.copyFromCurrentSession() == .applied)
        let field = ProjectEditorField.tabDirectory(slot: 0, tab: 1)
        #expect(model.validate().warnings[field] != nil)
        #expect(model.validate().isValid, "a note is a warning, not a blocker")

        model.setTabDirectory(1, "docs")
        #expect(model.validate().warnings[field] == nil)
    }

    @Test func aHandedInDraftWithAPlaceholderRootCannotBeSavedUntilItIsChosen() throws {
        let fixture = try Fixture()
        let projectStore = ProjectStore(fileURL: fixture.projectsFile)
        let bare = SessionProjectCapture.capture(session: fixture.session(.leaf(fixture.pane([TabRuntime()]))), homeDirectory: fixture.root.path)
        let model = ProjectEditorViewModel(store: projectStore, directoryExists: { _ in true })
        model.requestNavigation(.newDraft(bare.newDraft(name: "Placeholder", existingNames: [])))

        #expect(model.save() == nil)
        #expect(projectStore.projects.isEmpty)
        model.applyChosenRoot(fixture.root)
        #expect(model.save()?.name == "Placeholder")
    }
}

@MainActor
struct SaveSessionAsProjectBackgroundTests {
    private func openedSession(_ fixture: ProjectBackgroundFixture, _ store: AppStateStore, _ project: Project) throws -> SessionRuntime {
        try store.projectStore.upsert(project)
        return try store.openProject(id: project.id, mode: .openNew, contentFactory: noContent).session
    }

    @Test func saveAsNewCapturesTheSessionOverrideAndCopiesItsImage() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy(in: fixture.paneFolder)
        let session = fixture.session()
        session.setBackgroundOverride(projectBackgroundValue(path: path))

        let draft = SaveSessionAsProject.draft(for: session, destination: .newProject, store: fixture.appStore(), nameForRoot: { _ in nil })

        let stored = try #require(draft.background)
        let copied = try #require(stored.imagePath)
        #expect(copied.hasPrefix(fixture.projectFolder.path))
        #expect(FileManager.default.fileExists(atPath: copied))
        #expect(stored == projectBackgroundValue(path: copied))
        #expect(session.backgroundOverride?.imagePath == path, "capture leaves the Session alone")
    }

    @Test func copiedImageSurvivesRemovingTheSourceFolder() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy(in: fixture.paneFolder)
        let session = fixture.session()
        session.setBackgroundOverride(projectBackgroundValue(path: path))
        let draft = SaveSessionAsProject.draft(for: session, destination: .newProject, store: fixture.appStore(), nameForRoot: { _ in nil })
        try FileManager.default.removeItem(at: fixture.paneFolder)
        #expect(fixture.library.checked(try #require(draft.background)).problem == nil)
    }

    @Test func saveAsNewFromAnAppWideSeededPathCopies() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy(in: fixture.appWideFolder)
        let session = fixture.session()
        session.setBackgroundOverride(appWideBackgroundValue(path: path))
        let draft = SaveSessionAsProject.draft(for: session, destination: .newProject, store: fixture.appStore(), nameForRoot: { _ in nil })
        #expect(draft.background?.imagePath?.hasPrefix(fixture.projectFolder.path) == true)
    }

    @Test func saveAsNewWithNoOverrideFollows() throws {
        let fixture = try ProjectBackgroundFixture()
        let draft = SaveSessionAsProject.draft(for: fixture.session(), destination: .newProject, store: fixture.appStore(), nameForRoot: { _ in nil })
        #expect(draft.background == nil)
        #expect(draft.captureNotes[.background] == nil)
    }

    @Test func aPaneOverrideIsCapturedAtThePaneLevel() throws {
        let fixture = try ProjectBackgroundFixture()
        let session = fixture.session(2)
        let pane = session.tree.allPanes[1]
        pane.addTab()
        pane.setBackgroundOverride(secondBackgroundValue(path: nil))
        let draft = SaveSessionAsProject.draft(for: session, destination: .newProject, store: fixture.appStore(), nameForRoot: { _ in nil })
        #expect(draft.background == nil)
        #expect(draft.layout.panes[1].background == secondBackgroundValue(path: nil))
        #expect(draft.layout.panes[0].background == nil)
        #expect(draft.layout.panes[1].tabs.map(\.background) == [nil, nil])
        #expect(draft.layout.panes[0].tabs.map(\.background) == [nil])
        #expect(draft.captureNotes[.background] == nil)
    }

    @Test func aTabOverrideIsCapturedForThatTab() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy(in: fixture.paneFolder)
        let session = fixture.session()
        let pane = session.tree.allPanes[0]
        pane.addTab()
        pane.tabs[1].setBackgroundOverride(projectBackgroundValue(path: path))
        let draft = SaveSessionAsProject.draft(for: session, destination: .newProject, store: fixture.appStore(), nameForRoot: { _ in nil })
        let tabs = draft.layout.panes[0].tabs
        #expect(tabs[0].background == nil)
        let copied = try #require(tabs[1].background?.imagePath)
        #expect(copied.hasPrefix(fixture.projectFolder.path))
        #expect(tabs[1].background == projectBackgroundValue(path: copied))
    }

    private static let twoTabs = ProjectLayout(root: .pane(.terminal(tabs: [
        ProjectTab(background: projectBackgroundValue(path: nil)), ProjectTab(),
    ])))

    @Test func updateTakesAChangedTabValue() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let project = fixture.project(background: nil, layout: Self.twoTabs)
        let session = try openedSession(fixture, store, project)
        session.tree.allPanes[0].tabs[1].setBackgroundOverride(secondBackgroundValue(path: nil))
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store)
        #expect(draft.layout.panes[0].tabs.map(\.background) == [projectBackgroundValue(path: nil), secondBackgroundValue(path: nil)])
    }

    @Test func updateWritesWhatTheSessionShowsAtEveryLevel() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let project = fixture.project(background: projectBackgroundValue(path: nil), layout: Self.twoTabs)
        let session = try openedSession(fixture, store, project)
        let pane = session.tree.allPanes[0]
        pane.setBackgroundOverride(secondBackgroundValue(path: nil))
        pane.tabs[1].setBackgroundOverride(projectBackgroundValue(path: nil).withTerminalOpacity(0.3))
        session.setBackgroundOverride(secondBackgroundValue(path: nil).withTerminalOpacity(0.9))
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store)
        #expect(draft.background == secondBackgroundValue(path: nil).withTerminalOpacity(0.9))
        #expect(draft.layout.panes[0].background == secondBackgroundValue(path: nil))
        #expect(draft.layout.panes[0].tabs.map(\.background) == [nil, projectBackgroundValue(path: nil).withTerminalOpacity(0.3)])
    }

    @Test func updateAfterClearingASessionBackgroundFollowsSettings() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let project = fixture.project(background: projectBackgroundValue(path: nil), layout: Self.twoTabs)
        let session = try openedSession(fixture, store, project)
        session.setBackgroundOverride(nil)
        session.tree.allPanes[0].tabs[0].setBackgroundOverride(nil)
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store)
        #expect(draft.background == nil)
        #expect(draft.sharedImage == nil)
        #expect(draft.layout.panes[0].tabs.map(\.background) == [nil, nil])
    }

    @Test func aTabImageThatCannotBeCopiedKeepsOpacityAndAddsANote() throws {
        let fixture = try ProjectBackgroundFixture()
        let session = fixture.session()
        session.tree.allPanes[0].tabs[0].setBackgroundOverride(projectBackgroundValue(path: "/tmp/not-a-batty-copy.png"))
        let draft = SaveSessionAsProject.draft(for: session, destination: .newProject, store: fixture.appStore(), nameForRoot: { _ in nil })
        #expect(draft.layout.panes[0].tabs[0].background == projectBackgroundValue(path: nil))
        #expect(draft.captureNotes[.tabBackground(slot: 0, tab: 0)]?.contains("could not be copied") == true)
    }

    @Test func copyFromCurrentSessionDropsTabBackgroundsWithTheTabs() throws {
        let fixture = try ProjectBackgroundFixture()
        let projectStore = ProjectStore(fileURL: fixture.projectsFile)
        let stored = fixture.project(background: projectBackgroundValue(path: nil), layout: Self.twoTabs)
        try projectStore.upsert(stored)
        let session = fixture.session()
        session.tree.allPanes[0].tabs[0].setBackgroundOverride(secondBackgroundValue(path: nil))
        let model = ProjectEditorViewModel(
            store: projectStore,
            directoryExists: { _ in true },
            captureSession: { SessionProjectCapture.capture(session: session, root: $0, gitDirectory: { _ in nil }) }
        )
        #expect(model.copyFromCurrentSession(confirmDiscard: true) == .applied)
        #expect(model.draft?.layout.panes.flatMap(\.tabs).allSatisfy { $0.background == nil } == true)
        #expect(model.draft?.background == projectBackgroundValue(path: nil))
    }

    @Test func anUnreadableSessionImageKeepsOpacityAndAddsANote() throws {
        let fixture = try ProjectBackgroundFixture()
        let session = fixture.session()
        session.setBackgroundOverride(projectBackgroundValue(path: "/tmp/not-a-batty-copy.png"))
        let draft = SaveSessionAsProject.draft(for: session, destination: .newProject, store: fixture.appStore(), nameForRoot: { _ in nil })
        #expect(draft.background == projectBackgroundValue(path: nil))
        #expect(draft.captureNotes[.background]?.contains("could not be copied") == true)
    }

    @Test func updateKeepsAnImageWithheldAtOpen() async throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let path = try await fixture.copy()
        let project = fixture.project(background: projectBackgroundValue(path: path))
        try fixture.removeFolder(of: path)
        let session = try openedSession(fixture, store, project)
        #expect(session.backgroundOverride?.imagePath == nil, "test setup: the open dropped the image")
        #expect(session.pendingProjectImage)
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store)
        #expect(draft.background?.imagePath == path)
    }

    @Test func updateAfterChangingAWithheldBackgroundWritesTheNewValue() async throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let path = try await fixture.copy()
        let project = fixture.project(background: projectBackgroundValue(path: path))
        try fixture.removeFolder(of: path)
        let session = try openedSession(fixture, store, project)
        session.setBackgroundOverride(secondBackgroundValue(path: nil))
        #expect(!session.pendingProjectImage)
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store)
        #expect(draft.background == secondBackgroundValue(path: nil))
    }

    private func withheldSharedSession(_ fixture: ProjectBackgroundFixture, _ store: AppStateStore) async throws -> (Project, SessionRuntime, String) {
        let path = try await fixture.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        var project = fixture.project(background: projectBackgroundValue(path: path))
        project.isShared = true
        project.sharedImage = .named(digest: digest, name: "Harbor")
        try fixture.removeFolder(of: path)
        let session = try openedSession(fixture, store, project)
        #expect(session.pendingProjectImage, "test setup: the open withheld the image")
        return (project, session, path)
    }

    private func editThenCancel(_ session: SessionRuntime) {
        let editor = BackgroundOverrideEditor(target: session, appWide: secondBackgroundValue(path: nil), originalOverride: session.backgroundOverride, pending: session.pendingSnapshot())
        editor.update { $0.withTerminalOpacity(0.4) }
        #expect(!session.pendingProjectImage, "test setup: the edit ended the wait")
        editor.cancel()
    }

    @Test func updateKeepsAWithheldSessionImageAfterSheetEditThenCancel() async throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let (project, session, path) = try await withheldSharedSession(fixture, store)
        let problem = session.projectBackgroundImageProblem
        editThenCancel(session)
        #expect(session.pendingProjectImage)
        #expect(session.projectBackgroundImageProblem == problem)
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store)
        #expect(draft.background?.imagePath == path)
        #expect(draft.sharedImage == project.sharedImage)
    }

    @Test func aSessionSheetCancelKeepsWaitingForTheSharedImage() async throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let (project, session, _) = try await withheldSharedSession(fixture, store)
        editThenCancel(session)
        let arrived = try await fixture.copy(in: fixture.paneFolder)
        store.sharedImageArrived(project: project, path: arrived)
        #expect(session.backgroundOverride?.imagePath == arrived)
        #expect(!session.pendingProjectImage)
    }

    @Test func updateTakesAChangedSessionBackground() async throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let project = fixture.project(background: projectBackgroundValue(path: try await fixture.copy()))
        let session = try openedSession(fixture, store, project)
        let changed = try await fixture.copy(in: fixture.paneFolder, width: 128)
        session.setBackgroundOverride(secondBackgroundValue(path: changed))
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store)
        let stored = try #require(draft.background)
        #expect(stored.imagePath?.hasPrefix(fixture.projectFolder.path) == true)
        #expect(stored == secondBackgroundValue(path: stored.imagePath))
    }

    @Test func updateAfterClearingTheSessionFollows() async throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let project = fixture.project(background: projectBackgroundValue(path: try await fixture.copy()))
        let session = try openedSession(fixture, store, project)
        session.setBackgroundOverride(nil)
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store)
        #expect(draft.background == nil)
    }

    @Test func copyFromCurrentSessionLeavesTheBackgroundAlone() throws {
        let fixture = try ProjectBackgroundFixture()
        let projectStore = ProjectStore(fileURL: fixture.projectsFile)
        let stored = fixture.project(background: projectBackgroundValue(path: nil))
        try projectStore.upsert(stored)
        let session = fixture.session()
        session.setBackgroundOverride(secondBackgroundValue(path: nil))
        let model = ProjectEditorViewModel(
            store: projectStore,
            directoryExists: { _ in true },
            captureSession: { SessionProjectCapture.capture(session: session, root: $0, gitDirectory: { _ in nil }) }
        )
        #expect(model.copyFromCurrentSession(confirmDiscard: true) == .applied)
        #expect(model.draft?.background == projectBackgroundValue(path: nil))
    }
}

@MainActor
struct SaveSessionAsProjectThemeTests {
    private func openedSession(_ fixture: ProjectBackgroundFixture, _ store: AppStateStore, theme: ThemePair?) throws -> (Project, SessionRuntime) {
        var project = fixture.project(background: nil)
        project.theme = theme
        try store.projectStore.upsert(project)
        return (project, try store.openProject(id: project.id, mode: .openNew, contentFactory: noContent).session)
    }

    @Test func saveAsProjectCapturesTheSessionTheme() throws {
        let fixture = try ProjectBackgroundFixture()
        let session = fixture.session()
        session.themeOverride = .both("Nord")
        let draft = SaveSessionAsProject.draft(for: session, destination: .newProject, store: fixture.appStore(), nameForRoot: { _ in nil })
        #expect(draft.theme == .both("Nord"))
    }

    @Test func updateAlwaysWritesTheSessionTheme() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        var (project, session) = try openedSession(fixture, store, theme: .both("Nord"))
        project.theme = ThemePair(dark: "Added Later", light: nil)
        try store.projectStore.upsert(project)
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store)
        #expect(draft.theme == .both("Nord"))
    }

    @Test func updateWritesTheThemeWhenChangedAfterOpen() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let (project, session) = try openedSession(fixture, store, theme: ThemePair(dark: "Nord", light: nil))
        session.themeOverride = .both("Other")
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store)
        #expect(draft.theme == .both("Other"))
    }

    @Test func updateAfterClearClearsTheProjectTheme() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let (project, session) = try openedSession(fixture, store, theme: .both("Nord"))
        session.themeOverride = nil
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store)
        #expect(draft.theme == nil)
    }

    @Test func updateKeepsAnUnknownName() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let pair = ThemePair(dark: "Not In This Batty", light: nil)
        let (project, session) = try openedSession(fixture, store, theme: pair)
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store)
        #expect(draft.theme == pair)
        #expect(draft.makeProject().theme == pair)
    }
}

@MainActor
struct SaveSessionAsProjectSessionStateTests {
    private func opened(_ fixture: ProjectBackgroundFixture, _ store: AppStateStore, _ project: Project) throws -> SessionRuntime {
        try store.projectStore.upsert(project)
        return try store.openProject(id: project.id, mode: .openNew, contentFactory: noContent).session
    }

    @Test func updateCapturesMuteExpansionNameAndColor() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        let project = fixture.project(background: nil)
        let session = try opened(fixture, store, project)
        session.notificationsMuted = true
        session.isPaneListExpanded = true
        session.title = "Renamed"
        session.colorIndex = (project.color.rawValue + 1) % SessionColor.allCases.count
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(project.id), store: store)
        #expect(draft.notificationsMuted)
        #expect(draft.paneListExpanded)
        #expect(draft.name == "Renamed")
        #expect(draft.color == session.sessionColor)
        #expect(draft.customColorHex == nil)
    }

    @Test func anUnchangedPaletteColorKeepsTheCustomHex() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = fixture.appStore()
        var project = fixture.project(background: nil)
        project = Project(id: project.id, name: project.name, rootPath: project.rootPath, color: project.color, layout: project.layout, customColorHex: "#123456")
        let stored = try #require({ try store.projectStore.upsert(project); return store.projectStore.project(id: project.id) }())
        let session = try store.openProject(id: stored.id, mode: .openNew, contentFactory: noContent).session
        session.colorIndex = stored.color.rawValue
        let draft = SaveSessionAsProject.draft(for: session, destination: .update(stored.id), store: store)
        #expect(draft.customColorHex == stored.customColorHex)
        #expect(stored.customColorHex != nil)
    }
}
