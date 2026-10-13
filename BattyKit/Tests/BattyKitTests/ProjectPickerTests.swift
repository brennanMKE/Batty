// ProjectPickerTests.swift

import AppKit
import BattyXPCCore
import Foundation
import SwiftUI
import Testing
@testable import BattyKit

private func project(
    _ name: String,
    root: String = "/Users/test/Developer/work",
    layout: ProjectLayout = .preset(.singlePane),
    color: SessionColor = .blue
) -> Project {
    Project(name: name, rootPath: root, color: color, layout: layout)
}

@MainActor
struct ProjectPickerSummaryTests {
    @Test func singularAndPluralForms() {
        #expect(ProjectPickerModel.summary(panes: 1, tabs: 1, startupCommands: 1) == "1 pane \u{00B7} 1 tab \u{00B7} 1 startup command")
        #expect(ProjectPickerModel.summary(panes: 3, tabs: 3, startupCommands: 2) == "3 panes \u{00B7} 3 tabs \u{00B7} 2 startup commands")
        #expect(ProjectPickerModel.summary(panes: 4, tabs: 2, startupCommands: 0) == "4 panes \u{00B7} 2 tabs \u{00B7} no startup commands")
    }

    @Test func abbreviatesOnlyOnAComponentBoundary() {
        let home = "/Users/bob"
        #expect(ProjectPickerModel.abbreviate(path: "/Users/bob", homeDirectory: home) == "~")
        #expect(ProjectPickerModel.abbreviate(path: "/Users/bob/Developer/x", homeDirectory: home) == "~/Developer/x")
        #expect(ProjectPickerModel.abbreviate(path: "/Users/bob2/x", homeDirectory: home) == "/Users/bob2/x")
        #expect(ProjectPickerModel.abbreviate(path: "/opt/x", homeDirectory: home) == "/opt/x")
        #expect(ProjectPickerModel.abbreviate(path: "/Users/bob/x", homeDirectory: "/Users/bob/") == "~/x")
        #expect(ProjectPickerModel.abbreviate(path: "/x", homeDirectory: "/") == "/x")
    }
}

@MainActor
struct ProjectPickerModelTests {
    private let home = "/Users/test"

    private func model(_ projects: [Project], open: Set<UUID> = []) -> ProjectPickerModel {
        ProjectPickerModel(projects: projects, openProjectIDs: open, homeDirectory: home)
    }

    @Test func cardsKeepStoreOrderAndDescribeEachProject() {
        let layout = ProjectLayout.preset(.mainLeftTwoRight, kinds: [.terminal, .gitStatus, .terminal])
        let a = project("Alpha", layout: layout, color: .teal)
        let b = project("Beta")
        let m = model([a, b], open: [b.id])

        #expect(m.cards.map(\.name) == ["Alpha", "Beta"])
        let alpha = m.cards[0]
        #expect(alpha.displayPath == "~/Developer/work")
        #expect(alpha.color == .teal)
        #expect(alpha.summary == "3 panes \u{00B7} 2 tabs \u{00B7} no startup commands")
        #expect(alpha.slots.map(\.kind) == [.terminal, .gitStatus, .terminal])
        #expect(alpha.slots.count == layout.slotFrames.count)
        #expect(alpha.slots.map(\.frame) == layout.slotFrames)
        #expect(!alpha.isOpen)
        #expect(m.cards[1].isOpen)
    }

    @Test func emptyStateDistinguishesNoProjectsFromNoMatches() {
        #expect(model([]).emptyState == .noProjects)
        #expect(model([]).selectedID == nil)
        #expect(model([]).openAction(optionHeld: false) == nil)

        var m = model([project("Alpha")])
        #expect(m.emptyState == nil)
        m.setQuery("zzz")
        #expect(m.emptyState == .noMatches)
        #expect(m.selectedID == nil)
        #expect(m.cards.isEmpty)
    }

    @Test func filterMatchesByNameFuzzily() {
        var m = model([project("Alpha"), project("Beta"), project("Homelab")])
        m.setQuery("hml")
        #expect(m.cards.map(\.name) == ["Homelab"])
        m.setQuery("ALP")
        #expect(m.cards.map(\.name) == ["Alpha"])
    }

    @Test func filterMatchesByPath() {
        var m = model([
            project("Alpha", root: "/Users/test/Developer/web"),
            project("Beta", root: "/Users/test/Projects/qr"),
        ])
        m.setQuery("projects/qr")
        #expect(m.cards.map(\.name) == ["Beta"])
        m.setQuery("~/Developer")
        #expect(m.cards.map(\.name) == ["Alpha"])
    }

    @Test func filterRanksNameMatchesAheadOfPathMatchesAndKeepsStoreOrderOnTies() {
        var m = model([
            project("Zeta", root: "/Users/test/code/site"),
            project("Site", root: "/Users/test/other"),
            project("Gamma", root: "/Users/test/code/site2"),
        ])
        m.setQuery("site")
        #expect(m.cards.map(\.name) == ["Site", "Zeta", "Gamma"])
        #expect(m.selectedID == m.cards.first?.id)
    }

    @Test func blankQueryShowsEverything() {
        var m = model([project("Alpha"), project("Beta")])
        m.setQuery("   ")
        #expect(m.cards.count == 2)
    }

    @Test func selectionStartsOnTheFirstCardAndFollowsAChangedFilter() {
        let a = project("Alpha"), b = project("Beta"), c = project("Gamma")
        var m = model([a, b, c])
        #expect(m.selectedID == a.id)
        m.select(c.id)
        #expect(m.selectedID == c.id)
        m.setQuery("be")
        #expect(m.selectedID == b.id)
        m.select(a.id)
        #expect(m.selectedID == b.id, "a card hidden by the filter cannot be selected")
    }

    @Test func refreshedDataKeepsTheSelectionByIdAndUpdatesBadges() {
        let a = project("Alpha"), b = project("Beta"), c = project("Gamma")
        var m = model([a, b, c])
        m.select(b.id)
        let after = m.refreshed(projects: [c, b], openProjectIDs: [b.id])
        #expect(after.selectedID == b.id)
        #expect(after.cards.map(\.name) == ["Gamma", "Beta"])
        #expect(after.selectedCard?.isOpen == true)
        let gone = m.refreshed(projects: [a, c], openProjectIDs: [])
        #expect(gone.selectedID == a.id)
    }

    @Test func selectionMovesOverTheGridWithoutWrapping() {
        let ps = (0..<5).map { project("P\($0)") }
        var m = model(ps)
        m.move(.left)
        #expect(m.selectedID == ps[0].id)
        m.move(.up)
        #expect(m.selectedID == ps[0].id)
        m.move(.right)
        #expect(m.selectedID == ps[1].id)
        m.move(.down)
        #expect(m.selectedID == ps[4].id, "row below exists: same column")
        m.move(.down)
        #expect(m.selectedID == ps[4].id, "last row: stays")
        m.move(.up)
        #expect(m.selectedID == ps[1].id)
        m.move(.right)
        m.move(.right)
        #expect(m.selectedID == ps[3].id, "row-major reading order")
        m.move(.right)
        m.move(.right)
        #expect(m.selectedID == ps[4].id, "right stops at the last card")
    }

    @Test func downFromAColumnThePartialLastRowLacksLandsOnTheLastCard() {
        let ps = (0..<5).map { project("P\($0)") }
        var m = model(ps)
        m.select(ps[2].id)
        m.move(.down)
        #expect(m.selectedID == ps[4].id)
    }

    @Test func movingDoesNothingWithoutCards() {
        var m = model([])
        m.move(.down)
        #expect(m.selectedID == nil)
    }

    @Test func returnOpensWithFocusAndOptionReturnOpensAnother() {
        let a = project("Alpha")
        let m = model([a])
        #expect(m.openAction(optionHeld: false) == .open(a.id, .focusExistingOrOpen))
        #expect(m.openAction(optionHeld: true) == .open(a.id, .openNew))
    }

    @Test func editActionTargetsTheSelection() {
        let a = project("Alpha"), b = project("Beta")
        var m = model([a, b])
        m.select(b.id)
        #expect(m.editAction() == .edit(b.id))
        #expect(model([]).editAction() == nil)
    }

    @Test func hintNamesWhatReturnWillDo() {
        let a = project("Alpha"), b = project("Beta")
        var m = model([a, b], open: [b.id])
        #expect(m.hint == "\u{21A9} Open Alpha in a new Session")
        m.select(b.id)
        #expect(m.hint == "\u{21A9} Switch to the open Beta Session")
        #expect(model([]).hint == "")
    }
}

@MainActor
struct ProjectFileMenuModelTests {
    @Test func absentWhileTheFlagIsOff() {
        let model = ProjectFileMenuModel.make(
            featureEnabled: false, projects: [project("Alpha")], openProjectIDs: [])
        #expect(model == nil)
    }

    @Test func zeroProjectsLeavesChooseAndNewWithoutALeadingDivider() {
        let model = ProjectFileMenuModel.make(featureEnabled: true, projects: [], openProjectIDs: [])
        #expect(model?.items == [.chooseProject, .newProject])
    }

    @Test func listsProjectsInStoreOrderThenDividerChooseAndNew() {
        let a = project("Zulu"), b = project("Alpha")
        let model = ProjectFileMenuModel.make(featureEnabled: true, projects: [a, b], openProjectIDs: [])
        #expect(model?.items == [
            .project(id: a.id, name: "Zulu", symbol: .folder, isOpen: false),
            .project(id: b.id, name: "Alpha", symbol: .folder, isOpen: false),
            .divider,
            .chooseProject,
            .newProject,
        ])
    }

    @Test func checksOnlyProjectsWithAnOpenSession() {
        let a = project("Alpha"), b = project("Beta")
        let model = ProjectFileMenuModel.make(featureEnabled: true, projects: [a, b], openProjectIDs: [b.id])
        #expect(model?.items.prefix(2) == [
            .project(id: a.id, name: "Alpha", symbol: .folder, isOpen: false),
            .project(id: b.id, name: "Beta", symbol: .folder, isOpen: true),
        ])
    }

    @Test func itemIdentifiersAreDistinct() {
        let a = project("Alpha")
        let items = ProjectFileMenuModel.make(featureEnabled: true, projects: [a], openProjectIDs: [])?.items ?? []
        #expect(Set(items.map(\.id)).count == items.count)
    }
}

@MainActor
private final class StoreFixture {
    let directory: URL
    let projectsFile: URL

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("batty-picker-\(UUID().uuidString)")
        projectsFile = directory.appendingPathComponent("projects.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func store(projectsEnabled: Bool, seeding projects: [Project] = []) throws -> AppStateStore {
        let store = AppStateStore(
            nameCache: SessionNameCache(fileURL: directory.appendingPathComponent("cache.json")),
            featureFlags: FeatureFlags(projects: projectsEnabled),
            projectsFileURL: projectsFile
        )
        for project in projects { try store.projectStore?.upsert(project) }
        return store
    }
}

@MainActor
private final class OpenRecorder {
    private(set) var calls: [(UUID, AppStateStore.ProjectOpenMode)] = []
    func record(_ id: UUID, _ mode: AppStateStore.ProjectOpenMode) { calls.append((id, mode)) }
}

@MainActor
struct ProjectPaletteEntryTests {
    private func projectCommands(_ view: CommandPaletteView) -> [PaletteCommand] {
        view.allCommands.filter { $0.id.hasPrefix("project:") }
    }

    @Test func flagOnListsOneEntryPerProjectAndThePicker() throws {
        let fixture = StoreFixture()
        let a = project("Alpha"), b = project("Beta")
        let store = try fixture.store(projectsEnabled: true, seeding: [a, b])
        let view = CommandPaletteView(isPresented: .constant(true), store: store)

        let commands = view.allCommands
        #expect(commands.contains { $0.id == "project:\(a.id.uuidString)" && $0.title == "Open Project: Alpha" })
        #expect(commands.contains { $0.id == "project:\(b.id.uuidString)" && $0.title == "Open Project: Beta" })
        #expect(commands.contains { $0.id == "extra:openProjectPicker" && $0.title == "Open Project\u{2026}" })
        #expect(Set(commands.map(\.id)).count == commands.count, "ids stay unique")
    }

    @Test func invokingAProjectEntryOpensItThroughTheSeamWithFocusMode() throws {
        let fixture = StoreFixture()
        let a = project("Alpha"), b = project("Beta")
        let store = try fixture.store(projectsEnabled: true, seeding: [a, b])
        let recorder = OpenRecorder()
        let view = CommandPaletteView(
            isPresented: .constant(true), store: store,
            openProject: { recorder.record($0, $1) })

        view.allCommands.first { $0.id == "project:\(b.id.uuidString)" }?.action()

        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.0 == b.id)
        #expect(recorder.calls.first?.1 == .focusExistingOrOpen)
    }

    @Test func opensWaitForTheSheetToFinishDismissing() throws {
        let fixture = StoreFixture()
        let a = project("Alpha")
        let store = try fixture.store(projectsEnabled: true, seeding: [a])
        let recorder = OpenRecorder()
        var deferred: [@MainActor () -> Void] = []
        let view = CommandPaletteView(
            isPresented: .constant(true), store: store,
            afterDismiss: { deferred.append($0) },
            openProject: { recorder.record($0, $1) })

        view.allCommands.first { $0.id == "project:\(a.id.uuidString)" }?.action()
        #expect(recorder.calls.isEmpty)
        #expect(deferred.count == 1)

        deferred.forEach { $0() }
        #expect(recorder.calls.map(\.0) == [a.id])
    }

    @Test func thePickerEntryPostsTheToggle() throws {
        let fixture = StoreFixture()
        let store = try fixture.store(projectsEnabled: true)
        let view = CommandPaletteView(isPresented: .constant(true), store: store)
        var posted = 0
        let token = NotificationCenter.default.addObserver(
            forName: .battyToggleProjectPicker, object: nil, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        view.allCommands.first { $0.id == "extra:openProjectPicker" }?.action()

        #expect(posted == 1)
    }

    @Test func flagOffHasNoProjectEntriesAndNeverBuildsTheStore() throws {
        let fixture = StoreFixture()
        let store = try fixture.store(projectsEnabled: false)
        let view = CommandPaletteView(isPresented: .constant(true), store: store)

        let ids = view.allCommands.map(\.id)

        #expect(!ids.contains { $0.hasPrefix("project:") })
        #expect(!ids.contains("extra:openProjectPicker"))
        #expect(!store.projectStoreIsConstructed)
        #expect(!FileManager.default.fileExists(atPath: fixture.projectsFile.path))
    }

    @Test func flagOnWithNoProjectsStillOffersThePicker() throws {
        let fixture = StoreFixture()
        let store = try fixture.store(projectsEnabled: true)
        let view = CommandPaletteView(isPresented: .constant(true), store: store)
        #expect(projectCommands(view).isEmpty)
        #expect(view.allCommands.contains { $0.id == "extra:openProjectPicker" })
    }
}

@MainActor
struct ProjectOpenPresenterTests {
    @Test func cancellingTheTrustSheetShowsNoError() {
        #expect(!ProjectOpenPresenter.shouldAlert(for: ProjectOpenError.cancelled))
        #expect(ProjectOpenPresenter.shouldAlert(for: ProjectOpenError.noWindow))
        #expect(ProjectOpenPresenter.shouldAlert(for: ProjectStoreError.emptyName))
    }

    @Test func aFailedOpenIsShownToThePersonWhoAskedForIt() throws {
        let fixture = StoreFixture()
        let store = try fixture.store(projectsEnabled: true)
        let missing = UUID()
        var shown: [Error] = []

        ProjectOpenPresenter.open(id: missing, mode: .focusExistingOrOpen, in: store) { shown.append($0) }

        #expect(shown.count == 1)
        #expect((shown.first as? ProjectOpenError) == .unknownProject(missing))
    }

    @Test func aFlagOffOpenFailsWithoutBuildingTheStore() throws {
        let fixture = StoreFixture()
        let store = try fixture.store(projectsEnabled: false)
        var shown: [Error] = []

        ProjectOpenPresenter.open(id: UUID(), mode: .openNew, in: store) { shown.append($0) }

        #expect((shown.first as? ProjectOpenError) == .featureDisabled)
        #expect(!store.projectStoreIsConstructed)
    }
}

@MainActor
struct ProjectPickerWindowTests {
    private func window(identifier: String?) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                         styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        if let identifier { w.identifier = NSUserInterfaceItemIdentifier(identifier) }
        return w
    }

    @Test func onlyTheTaggedSheetIsThePicker() {
        #expect(AppStateStore.isProjectPickerWindow(window(identifier: ProjectPickerView.windowIdentifier)))
        #expect(!AppStateStore.isProjectPickerWindow(window(identifier: nil)))
        #expect(!AppStateStore.isProjectPickerWindow(window(identifier: "project-editor")))
        #expect(!AppStateStore.isProjectPickerWindow(nil))
    }

    /// Cmd-E in the picker is also Pane > Open View > System Metrics, whose action resolves its window here.
    @Test func menuActionsResolveNoTargetWhileThePickerIsKey() {
        let store = AppStateStore()
        let content = store.windows[0]
        #expect(store.menuTargetWindow(projectEditorIsKey: false, projectPickerIsKey: false)?.id == content.id)
        #expect(store.menuTargetWindow(projectEditorIsKey: false, projectPickerIsKey: true) == nil)
        #expect(store.menuTargetWindow(projectEditorIsKey: true, projectPickerIsKey: false) == nil)
    }
}

@MainActor
struct ProjectPickerViewTests {
    @Test func theSheetLaysOutWithCardsAndWithTheEmptyState() {
        for projects in [[project("Alpha"), project("Beta")], []] {
            let view = ProjectPickerView(
                projects: { projects }, openProjectIDs: { [] }, homeDirectory: "/Users/test",
                onAction: { _ in }, onCancel: {})
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width > 0)
        }
    }
}
