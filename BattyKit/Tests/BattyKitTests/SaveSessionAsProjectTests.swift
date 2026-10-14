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

    func store(projects: Bool = true) -> AppStateStore {
        AppStateStore(
            nameCache: SessionNameCache(fileURL: base.appendingPathComponent("cache.json")),
            featureFlags: FeatureFlags(projects: projects),
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
    @Test func aHandResizedSessionOpensAsTheSameShapeAtEqualSizes() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let resized = fixture.session(split(
            .horizontal, 0.2,
            split(.vertical, 0.7, .leaf(fixture.pane([fixture.tab()])), .leaf(fixture.pane([fixture.tab("src", title: "src shell")]))),
            .leaf(fixture.pane([fixture.tab("docs")]))
        ))
        #expect(shape(resized.tree.root).contains("0.2000"), "test setup: the Session really is resized")

        let draft = try #require(SaveSessionAsProject.draft(for: resized, destination: .newProject, store: store))
        let saved = draft.makeProject()
        try #require(store.projectStore).upsert(saved)
        let result = try store.openProject(id: saved.id, mode: .openNew, contentFactory: noContent)

        #expect(shape(result.session.tree.root) == "(h 0.5000 (v 0.5000 L L) L)")
        let panes = result.session.tree.allPanes
        #expect(panes.count == 3)
        #expect(panes[1].tabs[0].titleOverride == "src shell")
        #expect(panes[1].tabs[0].terminal.configuration.workingDirectory == fixture.root.appendingPathComponent("src").path)
        #expect(panes[2].tabs[0].terminal.configuration.workingDirectory == fixture.root.appendingPathComponent("docs").path)
        #expect(result.session.title == "Website")
        #expect(result.session.sessionColor == .pink)
    }
}

@MainActor
struct SaveSessionAsProjectEntryTests {
    @Test func theMenuModelDependsOnTheFlagTheSessionAndTheBackingProject() {
        let backing = Project(name: "Backing", rootPath: "/Users/test/a")
        #expect(SaveSessionAsProjectMenuModel.make(featureEnabled: false, hasSession: true, backingProject: backing) == nil)
        #expect(SaveSessionAsProjectMenuModel.make(featureEnabled: false, hasSession: false, backingProject: nil) == nil)

        let plain = SaveSessionAsProjectMenuModel.make(featureEnabled: true, hasSession: true, backingProject: nil)
        #expect(plain == SaveSessionAsProjectMenuModel(isEnabled: true, updateTarget: nil))
        #expect(SaveSessionAsProjectMenuModel.make(featureEnabled: true, hasSession: false, backingProject: nil)?.isEnabled == false)

        let updating = SaveSessionAsProjectMenuModel.make(featureEnabled: true, hasSession: true, backingProject: backing)
        #expect(updating?.updateTarget == .init(id: backing.id, name: "Backing"))
    }

    @Test func withTheFlagOffNothingIsOfferedCapturedOrConstructed() throws {
        let fixture = try Fixture()
        let store = fixture.store(projects: false)
        let session = fixture.session(.leaf(fixture.pane([fixture.tab()])))
        let opened = Opened()

        #expect(SaveSessionAsProject.menuModel(store: store, session: session) == nil)
        #expect(SaveSessionAsProject.draft(for: session, destination: .newProject, store: store) == nil)
        let began = SaveSessionAsProject.begin(session: session, destination: .newProject, store: store, open: { opened.record($1) })
        #expect(!began)
        #expect(opened.drafts.isEmpty)
        #expect(!store.projectStoreIsConstructed)
        #expect(!FileManager.default.fileExists(atPath: fixture.projectsFile.path))
    }

    @Test func withTheFlagOnTheMenuModelFindsTheBackingProject() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.storedProject()
        try #require(store.projectStore).upsert(project)
        let session = fixture.session(.leaf(fixture.pane([fixture.tab()])))

        #expect(SaveSessionAsProject.menuModel(store: store, session: session)?.updateTarget == nil)
        #expect(SaveSessionAsProject.menuModel(store: store, session: nil)?.isEnabled == false)

        store.windows[0].selectedSession?.projectID = project.id
        let backed = store.windows[0].selectedSession
        #expect(SaveSessionAsProject.menuModel(store: store, session: backed)?.updateTarget?.name == "Stored")

        try #require(store.projectStore).delete(id: project.id)
        #expect(SaveSessionAsProject.menuModel(store: store, session: backed)?.updateTarget == nil, "a deleted Project is no longer offered")
    }

    @Test func savingAsNewOpensTheEditorOnADraftAndStoresNothing() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let other = fixture.storedProject(name: "Website")
        try #require(store.projectStore).upsert(other)
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
        #expect(store.projectStore?.projects.map(\.name) == ["Website"])
    }

    @Test func updateReplacesLayoutAndTabsButKeepsCommandsAndApprovalOnlyAfterSave() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let seed = fixture.storedProject()
        let projectStore = try #require(store.projectStore)
        try projectStore.upsert(seed)
        let stored = try #require(projectStore.project(id: seed.id))
        let session = fixture.session(.leaf(fixture.pane([fixture.tab("src")])))
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
        let projectStore = try #require(store.projectStore)
        try projectStore.upsert(seed)
        let stored = try #require(projectStore.project(id: seed.id))
        let before = try Data(contentsOf: fixture.projectsFile)

        let unbacked = fixture.session(.leaf(fixture.pane([fixture.tab("src")])))
        let other = fixture.session(.leaf(fixture.pane([fixture.tab("src")])))
        other.projectID = UUID()
        let backed = fixture.session(.leaf(fixture.pane([fixture.tab("src")])))
        backed.projectID = stored.id

        for stale in [unbacked, other] {
            let draft = try #require(SaveSessionAsProject.draft(for: stale, destination: .update(stored.id), store: store))
            #expect(draft.id != stored.id, "a stale update becomes a new Project")
            #expect(draft.name == "Website")
            #expect(draft.runStartupCommandsOnOpen)
            #expect(draft.makeProject().startupCommands.isEmpty)
        }
        let update = try #require(SaveSessionAsProject.draft(for: backed, destination: .update(stored.id), store: store))
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

        let draft = try #require(SaveSessionAsProject.draft(for: session, destination: .update(UUID()), store: store))
        #expect(draft.name == "Website")
        #expect(draft.runStartupCommandsOnOpen)
    }
}

@MainActor
struct SaveSessionAsProjectPaletteTests {
    private func palette(_ store: AppStateStore, record: @escaping @MainActor (SessionRuntime?, SaveSessionAsProject.Destination) -> Void = { _, _ in }, afterDismiss: ((@escaping @MainActor () -> Void) -> Void)? = nil) -> CommandPaletteView {
        CommandPaletteView(isPresented: .constant(true), store: store, afterDismiss: afterDismiss, saveSession: record)
    }

    @Test func theEntryExistsOnlyWithTheFlagOn() throws {
        let fixture = try Fixture()
        let onStore = fixture.store(projects: true)
        let on = palette(onStore).allCommands
        #expect(on.contains { $0.id == "extra:saveSessionAsProject" && $0.title == "Save Session as Project\u{2026}" })
        #expect(!on.contains { $0.id == "extra:updateSessionProject" })
        #expect(Set(on.map(\.id)).count == on.count)

        let offStore = fixture.store(projects: false)
        let off = palette(offStore).allCommands
        #expect(!off.contains { $0.id == "extra:saveSessionAsProject" || $0.id == "extra:updateSessionProject" })
        #expect(!offStore.projectStoreIsConstructed)
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
        try #require(store.projectStore).upsert(project)
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
