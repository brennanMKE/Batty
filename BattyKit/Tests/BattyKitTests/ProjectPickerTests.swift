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
    color: SessionColor = .blue,
    lastOpenedAt: TimeInterval? = nil
) -> Project {
    Project(name: name, rootPath: root, color: color, layout: layout, lastOpenedAt: lastOpenedAt.map(Date.init(timeIntervalSince1970:)))
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

    @Test func cardsDescribeEachProject() {
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

    @Test func cardsAreRankedByRecencyWithOpenProjectsLastAndStillMarkedOpen() {
        let a = project("Alpha", lastOpenedAt: 100), b = project("Beta"), c = project("Gamma", lastOpenedAt: 300)
        let d = project("Delta", lastOpenedAt: 200)
        let m = model([a, b, c, d], open: [c.id])

        #expect(m.cards.map(\.name) == ["Delta", "Alpha", "Beta", "Gamma"])
        #expect(m.cards.map(\.isOpen) == [false, false, false, true])
        #expect(m.selectedID == d.id)
    }

    @Test func refreshingReRanksWhenASessionOpens() {
        let a = project("Alpha", lastOpenedAt: 100), b = project("Beta", lastOpenedAt: 200)
        let m = model([a, b])
        #expect(m.cards.map(\.name) == ["Beta", "Alpha"])

        let refreshed = m.refreshed(projects: [a, b], openProjectIDs: [b.id])

        #expect(refreshed.cards.map(\.name) == ["Alpha", "Beta"])
        #expect(refreshed.selectedID == b.id, "the selection stays on its Project by id")
    }

    @Test func arrowKeysFollowTheRankedOrder() {
        let a = project("Alpha"), b = project("Beta", lastOpenedAt: 200), c = project("Gamma", lastOpenedAt: 300)
        var m = model([a, b, c])
        #expect(m.cards.map(\.name) == ["Gamma", "Beta", "Alpha"])
        m.move(.right)
        #expect(m.selectedID == b.id)
        m.move(.right)
        #expect(m.selectedID == a.id)
        m.move(.left)
        #expect(m.selectedID == b.id)
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

    @Test func filterRanksNameMatchesAheadOfPathMatchesAndKeepsRankedOrderOnTies() {
        var m = model([
            project("Zeta", root: "/Users/test/code/site"),
            project("Site", root: "/Users/test/other"),
            project("Gamma", root: "/Users/test/code/site2", lastOpenedAt: 100),
        ])
        m.setQuery("site")
        #expect(m.cards.map(\.name) == ["Site", "Gamma", "Zeta"])
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

    @Test func selectionMovesOverTheTiersWithoutWrapping() {
        let ps = (0..<8).map { project("P\($0)") }
        var m = model(ps)
        m.move(.left)
        #expect(m.selectedID == ps[0].id)
        m.move(.up)
        #expect(m.selectedID == ps[0].id)
        m.move(.right)
        #expect(m.selectedID == ps[1].id)
        m.move(.down)
        #expect(m.selectedID == ps[5].id, "featured column 1 maps to compact column 2, the third of four")
        m.move(.down)
        #expect(m.selectedID == ps[7].id, "second compact row has one card, short of column 2; lands on the last card")
        m.move(.down)
        #expect(m.selectedID == ps[7].id, "last row of the last tier: stays")
        m.move(.up)
        #expect(m.selectedID == ps[3].id, "up within the compact tier keeps the column of the card it came from")
        m.move(.up)
        #expect(m.selectedID == ps[0].id)
        m.move(.end)
        #expect(m.selectedID == ps[7].id)
        m.move(.right)
        #expect(m.selectedID == ps[7].id, "right stops at the last card")
        m.move(.home)
        #expect(m.selectedID == ps[0].id)
    }

    @Test func rightFromTheLastFeaturedCardEntersTheCompactTier() {
        let ps = (0..<5).map { project("P\($0)") }
        var m = model(ps)
        m.select(ps[2].id)
        m.move(.right)
        #expect(m.selectedID == ps[3].id)
        m.move(.left)
        #expect(m.selectedID == ps[2].id)
    }

    @Test func downFromTheLastFeaturedColumnIntoAShortCompactRowStaysInRange() {
        let ps = (0..<5).map { project("P\($0)") }
        var m = model(ps)
        m.select(ps[2].id)
        m.move(.down)
        #expect(m.selectedID == ps[4].id, "column 2 maps to compact column 3, which a two-card row lacks")
    }

    @Test func downFromAColumnThePartialLastRowLacksLandsOnTheLastCard() {
        let ps = (0..<8).map { project("P\($0)") }
        var m = model(ps)
        m.select(ps[6].id)
        m.move(.down)
        #expect(m.selectedID == ps[7].id)
    }

    @Test func featuredAndRestSplitTheRankedListAtThree() {
        let a = project("Alpha", lastOpenedAt: 100), b = project("Beta"), c = project("Gamma", lastOpenedAt: 300)
        let d = project("Delta", lastOpenedAt: 200), e = project("Eps", lastOpenedAt: 50)
        let m = model([a, b, c, d, e], open: [c.id])
        #expect(m.featured.map(\.name) == ["Delta", "Alpha", "Eps"])
        #expect(m.rest.map(\.name) == ["Beta", "Gamma"])
        #expect(m.rest.last?.isOpen == true)
        #expect(!m.showsNewProjectCard)
        #expect(m.showsTierHeadings)
        #expect(m.featured.first?.lastOpenedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func fewerThanThreeProjectsAreAllFeaturedWithANewProjectCard() {
        let a = project("Alpha", lastOpenedAt: 100), b = project("Beta", lastOpenedAt: 200)
        var m = model([a, b])
        #expect(m.featured.map(\.name) == ["Beta", "Alpha"])
        #expect(m.rest.isEmpty)
        #expect(m.showsNewProjectCard)
        #expect(!m.showsTierHeadings)
        m.setQuery("alp")
        #expect(!m.showsNewProjectCard)
        m.setQuery("zzz")
        #expect(!m.showsNewProjectCard)
        #expect(!model([]).showsNewProjectCard)
        #expect(!model([a, b, project("Gamma")]).showsNewProjectCard)
    }

    @Test func aQueryCollapsesToOneCompactTierInFilterOrder() {
        var m = model([
            project("Zeta", root: "/Users/test/code/site"),
            project("Site", root: "/Users/test/other"),
            project("Gamma", root: "/Users/test/code/site2", lastOpenedAt: 100),
            project("Delta"),
        ])
        m.setQuery("site")
        #expect(m.isFiltering)
        #expect(m.featured.isEmpty)
        #expect(m.rest.map(\.name) == ["Site", "Gamma", "Zeta"])
        #expect(!m.showsTierHeadings)
        #expect(m.selectedPosition == ProjectPickerPosition(id: m.rest[0].id, tier: .rest, index: 0))
        m.move(.down)
        #expect(m.selectedID == m.rest[0].id, "one row of matches: down stays")
        m.move(.right)
        #expect(m.selectedID == m.rest[1].id)
    }

    @Test func escapeClearsAQueryBeforeItDismisses() {
        let ps = [project("Alpha"), project("Beta"), project("Gamma"), project("Delta")]
        var m = model(ps)
        m.setQuery("gam")
        #expect(m.escape() == .cleared)
        #expect(m.query.isEmpty)
        #expect(m.selectedID == ps[0].id)
        #expect(m.featured.count == 3)
        #expect(m.escape() == .dismiss)
        m.setQuery("   ")
        #expect(m.escape() == .dismiss, "a blank query is no filter")
    }

    @Test func matchCountTextPluralizes() {
        #expect(ProjectPickerModel.matchCountText(1) == "1 match")
        #expect(ProjectPickerModel.matchCountText(2) == "2 matches")
        var m = model([project("Alpha"), project("Beta"), project("Alps")])
        m.setQuery("al")
        #expect(m.matchCountText == "2 matches")
    }

    @Test func selectedPositionFollowsAReRankThatKeepsTheSameCard() {
        let a = project("Alpha", lastOpenedAt: 400), b = project("Beta", lastOpenedAt: 300)
        let c = project("Gamma", lastOpenedAt: 200), d = project("Delta", lastOpenedAt: 100)
        var m = model([a, b, c, d])
        m.select(a.id)
        #expect(m.selectedPosition == ProjectPickerPosition(id: a.id, tier: .featured, index: 0))
        let after = m.refreshed(projects: [a, b, c, d], openProjectIDs: [a.id])
        #expect(after.selectedID == a.id)
        #expect(after.selectedPosition == ProjectPickerPosition(id: a.id, tier: .rest, index: 0))
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

    @Test func listsProjectsInRankedOrderThenDividerChooseAndNew() {
        let a = project("Zulu"), b = project("Alpha", lastOpenedAt: 50), c = project("Mike", lastOpenedAt: 90)
        let model = ProjectFileMenuModel.make(featureEnabled: true, projects: [a, b, c], openProjectIDs: [c.id])
        #expect(model?.items == [
            .project(id: b.id, name: "Alpha", symbol: .folder, isOpen: false),
            .project(id: a.id, name: "Zulu", symbol: .folder, isOpen: false),
            .project(id: c.id, name: "Mike", symbol: .folder, isOpen: true),
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

    @Test func emptyQueryRowsAreRankedByRecencyWithOpenProjectsLast() throws {
        let fixture = StoreFixture()
        let a = project("Alpha", root: "/tmp"), b = project("Beta", root: "/tmp", lastOpenedAt: 100), c = project("Gamma", root: "/tmp", lastOpenedAt: 300)
        let d = project("Delta", root: "/tmp", lastOpenedAt: 200)
        let store = try fixture.store(projectsEnabled: true, seeding: [a, b, c, d])
        _ = try store.openProject(id: c.id, contentFactory: { _ in nil })
        let view = CommandPaletteView(isPresented: .constant(true), store: store)

        #expect(projectCommands(view).map(\.title) == [
            "Open Project: Delta", "Open Project: Beta", "Open Project: Alpha", "Open Project: Gamma",
        ])
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

    @Test func thePickerEntryHandsTheHostADirectPresentAfterDismissInsteadOfBroadcasting() throws {
        let fixture = StoreFixture()
        let store = try fixture.store(projectsEnabled: true)
        var deferred: [@MainActor () -> Void] = []
        var presented = 0
        let view = CommandPaletteView(
            isPresented: .constant(true), store: store,
            afterDismiss: { deferred.append($0) },
            presentProjectPicker: { presented += 1 })
        var posted = 0
        let token = NotificationCenter.default.addObserver(
            forName: .battyToggleProjectPicker, object: nil, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        view.allCommands.first { $0.id == "extra:openProjectPicker" }?.action()
        #expect(presented == 0)
        #expect(deferred.count == 1)

        deferred.forEach { $0() }
        #expect(presented == 1)
        #expect(posted == 0)
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
        let four = [project("Alpha"), project("Beta"), project("Gamma"), project("Delta")]
        for projects in [four, [project("Alpha"), project("Beta")], []] {
            let view = ProjectPickerView(
                projects: { projects }, openProjectIDs: { [] }, homeDirectory: "/Users/test",
                onAction: { _ in }, onCancel: {})
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 860, height: 600)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width > 0)
        }
    }
}

struct ProjectRecencyRelativeTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func describesDatesRelativeToTheGivenNow() {
        for offset in [12 * 60, 2 * 3600, 86_400] as [TimeInterval] {
            let text = ProjectRecency.relativeOpenedText(now.addingTimeInterval(-offset), now: now)
            #expect(text?.isEmpty == false)
        }
        let minutes = ProjectRecency.relativeOpenedText(now.addingTimeInterval(-12 * 60), now: now)
        let hours = ProjectRecency.relativeOpenedText(now.addingTimeInterval(-2 * 3600), now: now)
        let day = ProjectRecency.relativeOpenedText(now.addingTimeInterval(-86_400), now: now)
        #expect(minutes != hours)
        #expect(day != hours)
    }

    @Test func aNeverOpenedProjectHasNoText() {
        #expect(ProjectRecency.relativeOpenedText(nil, now: now) == nil)
    }
}
