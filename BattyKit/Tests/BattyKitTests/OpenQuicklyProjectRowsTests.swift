// OpenQuicklyProjectRowsTests.swift

import Foundation
import Testing
@testable import BattyKit

private func project(
    _ name: String,
    root: String = "/tmp",
    color: SessionColor = .blue,
    lastOpenedAt: TimeInterval? = nil
) -> Project {
    Project(name: name, rootPath: root, color: color, layout: .preset(.singlePane), lastOpenedAt: lastOpenedAt.map(Date.init(timeIntervalSince1970:)))
}

private func row(_ name: String, root: String = "/tmp/work", home: String = "/Users/test", isOpen: Bool = false) -> OpenQuicklyProjectRow {
    OpenQuicklyProjectRow(
        id: UUID(), name: name, rootPath: root,
        displayPath: ProjectPickerModel.abbreviate(path: root, homeDirectory: home),
        color: .blue, symbol: .folder, isOpen: isOpen)
}

private func tab(_ session: String, _ tab: String = "~") -> QuickOpenResult {
    QuickOpenResult(sessionID: UUID(), sessionTitle: session, tabID: UUID(), tabTitle: tab)
}

private func names(_ entries: [OpenQuicklyEntry]) -> [String] {
    entries.map {
        switch $0 {
        case .tab(let result): "tab:\(result.sessionTitle)"
        case .project(let row): "project:\(row.name)"
        }
    }
}

@MainActor
private final class Fixture {
    let directory: URL
    let projectsFile: URL

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("batty-openquickly-\(UUID().uuidString)")
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
struct OpenQuicklyProjectMatchingTests {
    @Test func prefixInteriorAndScatteredNamesRankInThatOrder() {
        let scattered = row("bxexta"), interior = row("xbeta"), prefix = row("beta")
        let given = [scattered, interior, prefix]
        #expect(names(OpenQuicklyFilter.apply(query: "beta", tabs: [], projects: given)) == ["project:beta", "project:xbeta", "project:bxexta"])
        #expect(names(OpenQuicklyFilter.apply(query: "bta", tabs: [], projects: given)) == ["project:bxexta", "project:xbeta", "project:beta"])
    }

    @Test func aPathOnlyMatchScoresOneAndRanksBelowAnyNameMatch() {
        let byPath = row("Quebec", root: "/Users/test/Developer/bta")
        let scatteredName = row("Bxexta", root: "/tmp/other")
        let interiorName = row("Xbta", root: "/tmp/other")
        let both = OpenQuicklyFilter.apply(query: "bta", tabs: [], projects: [byPath, scatteredName, interiorName])
        #expect(names(both) == ["project:Xbta", "project:Bxexta", "project:Quebec"])
        let onlyPath = OpenQuicklyFilter.apply(query: "beta", tabs: [], projects: [row("Quebec", root: "/Users/test/Developer/beta")])
        #expect(names(onlyPath) == ["project:Quebec"])
    }

    @Test func aPathMatchReachesTheFullPathAndItsHomeAbbreviation() {
        let p = row("Quebec", root: "/Users/test/Developer/x", home: "/Users/test")
        #expect(p.displayPath == "~/Developer/x")
        #expect(names(OpenQuicklyFilter.apply(query: "~/Developer", tabs: [], projects: [p])) == ["project:Quebec"])
        #expect(names(OpenQuicklyFilter.apply(query: "/Users/test/dev", tabs: [], projects: [p])) == ["project:Quebec"])
    }

    @Test func aNameAndPathThatBothMissAreAbsent() {
        #expect(OpenQuicklyFilter.apply(query: "nomatch", tabs: [], projects: [row("Alpha")]).isEmpty)
    }

    @Test func upperCaseQueryMatchesLowerCaseNameAndPath() {
        #expect(names(OpenQuicklyFilter.apply(query: "ALPHA", tabs: [], projects: [row("alpha")])) == ["project:alpha"])
        #expect(names(OpenQuicklyFilter.apply(query: "WORK", tabs: [], projects: [row("Quebec", root: "/tmp/work")])) == ["project:Quebec"])
    }

    @Test func projectsNeverMatchTabTitles() {
        let entries = OpenQuicklyFilter.apply(query: "logs", tabs: [tab("Other", "tail-logs")], projects: [row("Alpha")])
        #expect(names(entries) == ["tab:Other"])
    }

    @Test func aNamePrefixOutranksALongerRecencyOfAPathOnlyMatch() {
        let recentPathOnly = row("Quebec", root: "/tmp/beta-stuff")
        let olderPrefix = row("Beta Duo")
        let entries = OpenQuicklyFilter.apply(query: "beta", tabs: [], projects: [recentPathOnly, olderPrefix])
        #expect(names(entries) == ["project:Beta Duo", "project:Quebec"])
    }

    @Test func existingTabFilterIsUnchanged() {
        let a = tab("Cat"), b = tab("Bird")
        #expect(OpenQuicklyFilter.apply(query: "bird", to: [a, b]) == [b])
    }
}

@MainActor
struct OpenQuicklyRankingTests {
    @Test func tabRowsComeBeforeProjectRowsInTheSameTier() {
        let entries = OpenQuicklyFilter.apply(query: "batty", tabs: [tab("Batty", "zsh")], projects: [row("Batty")])
        #expect(names(entries) == ["tab:Batty", "project:Batty"])
    }

    @Test func aBetterTierWinsWhateverTheKind() {
        let entries = OpenQuicklyFilter.apply(
            query: "bat",
            tabs: [tab("Abate")],
            projects: [row("Batty")])
        #expect(names(entries) == ["project:Batty", "tab:Abate"])
    }

    @Test func emptyQueryListsTabsInOrderThenProjectsInGivenOrder() {
        let entries = OpenQuicklyFilter.apply(
            query: "", tabs: [tab("One"), tab("Two")], projects: [row("Zed"), row("Alpha")])
        #expect(names(entries) == ["tab:One", "tab:Two", "project:Zed", "project:Alpha"])
    }

    @Test func equalScoresKeepGivenOrderWithinAKind() {
        let entries = OpenQuicklyFilter.apply(
            query: "a", tabs: [tab("Aa"), tab("Ab")], projects: [row("Az"), row("Ay")])
        #expect(names(entries) == ["tab:Aa", "tab:Ab", "project:Az", "project:Ay"])
    }
}

@MainActor
struct OpenQuicklyRecencyTests {
    private func rankedNames(_ store: AppStateStore) -> [String] {
        ProjectRecency.ranked(store.projectStore?.projects ?? [], openProjectIDs: store.openProjectIDs).map(\.name)
    }

    @Test func projectRowsFollowTheSharedRankingForEveryOpenFixture() throws {
        let fixture = Fixture()
        let never = project("Beta Never"), older = project("Beta Older", lastOpenedAt: 100), newer = project("Beta Newer", lastOpenedAt: 900)
        let store = try fixture.store(projectsEnabled: true, seeding: [never, newer, older])

        func rows() -> [String] { OpenQuicklyFilter.projectRows(in: store).map(\.name) }
        #expect(rows() == rankedNames(store))
        #expect(rows() == ["Beta Newer", "Beta Older", "Beta Never"])

        try store.openProject(id: older.id, contentFactory: { _ in nil })
        #expect(rows() == rankedNames(store))
        #expect(rows() == ["Beta Newer", "Beta Never", "Beta Older"])

        try store.openProject(id: newer.id, contentFactory: { _ in nil })
        #expect(rows() == rankedNames(store))
        #expect(rows() == ["Beta Never", "Beta Newer", "Beta Older"])
        #expect(OpenQuicklyFilter.projectRows(in: store).filter(\.isOpen).map(\.name).sorted() == ["Beta Newer", "Beta Older"])
    }

    @Test func theFilteredOrderWithinOneTierIsTheSharedOrder() throws {
        let fixture = Fixture()
        let a = project("Beta A"), b = project("Beta B", lastOpenedAt: 100), c = project("Beta C", lastOpenedAt: 500)
        let store = try fixture.store(projectsEnabled: true, seeding: [a, b, c])
        let entries = OpenQuicklyFilter.apply(query: "beta", tabs: [], projects: OpenQuicklyFilter.projectRows(in: store))
        #expect(entries.compactMap { entry -> String? in
            if case .project(let r) = entry { r.name } else { nil }
        } == rankedNames(store))
        #expect(rankedNames(store) == ["Beta C", "Beta B", "Beta A"])
    }

    @Test func aRecentPathOnlyMatchStaysBelowAnOlderNamePrefix() throws {
        let fixture = Fixture()
        let pathOnly = project("Quebec", root: "/tmp/beta-stuff", lastOpenedAt: 900)
        let prefix = project("Beta Duo", lastOpenedAt: 100)
        let store = try fixture.store(projectsEnabled: true, seeding: [pathOnly, prefix])
        let entries = OpenQuicklyFilter.apply(query: "beta", tabs: [], projects: OpenQuicklyFilter.projectRows(in: store))
        #expect(names(entries) == ["project:Beta Duo", "project:Quebec"])
    }
}

@MainActor
struct OpenQuicklyPathOnlyRecencyTests {
    @Test func theNewestPathOnlyProjectStaysBelowAScatteredNameMatch() throws {
        let fixture = Fixture()
        let pathOnly = project("Quebec", root: "/tmp/bta-stuff", lastOpenedAt: 900)
        let scattered = project("Bxexta", lastOpenedAt: 100)
        let store = try fixture.store(projectsEnabled: true, seeding: [pathOnly, scattered])
        let rows = OpenQuicklyFilter.projectRows(in: store)
        #expect(rows.map(\.name) == ["Quebec", "Bxexta"])
        #expect(names(OpenQuicklyFilter.apply(query: "bta", tabs: [], projects: rows)) == ["project:Bxexta", "project:Quebec"])
    }
}

@MainActor
struct OpenQuicklyDeduplicationTests {
    @Test func anOpenProjectKeepsItsRowNextToItsSessionsTabRows() throws {
        let fixture = Fixture()
        let batty = project("Batty")
        let store = try fixture.store(projectsEnabled: true, seeding: [batty])
        _ = try store.openProject(id: batty.id, contentFactory: { _ in nil })
        let window = store.windows[0]

        let entries = OpenQuicklyFilter.apply(
            query: "batty",
            tabs: OpenQuicklyFilter.allResults(for: window),
            projects: OpenQuicklyFilter.projectRows(in: store))

        let tabCount = OpenQuicklyFilter.allResults(for: window).filter { $0.sessionTitle == "Batty" }.count
        #expect(tabCount >= 1)
        #expect(names(entries) == Array(repeating: "tab:Batty", count: tabCount) + ["project:Batty"])
        guard case .project(let projectRow) = entries.last else { Issue.record("expected a project row last"); return }
        #expect(projectRow.isOpen)
    }

    @Test func aProjectOpenOnlyInAnotherWindowHasAnOpenRowAndNoTabRow() throws {
        let fixture = Fixture()
        let remote = project("Remote Work")
        let store = try fixture.store(projectsEnabled: true, seeding: [remote])
        let other = store.windowRuntime(for: WindowID())
        let tree = try ProjectTreeBuilder.build(project: remote, contentFactory: { _ in nil }, isSessionSelected: true)
        other.addProjectSession(remote, tree: tree)

        let here = store.windows[0]
        let entries = OpenQuicklyFilter.apply(
            query: "remote",
            tabs: OpenQuicklyFilter.allResults(for: here),
            projects: OpenQuicklyFilter.projectRows(in: store))

        #expect(names(entries) == ["project:Remote Work"])
        guard case .project(let projectRow) = entries.first else { Issue.record("expected a project row"); return }
        #expect(projectRow.isOpen)
    }

    @Test func aSecondCopyDoesNotAddASecondProjectRow() throws {
        let fixture = Fixture()
        let a = project("Alpha"), b = project("Beta")
        let store = try fixture.store(projectsEnabled: true, seeding: [a, b])
        _ = try store.openProject(id: a.id, contentFactory: { _ in nil })
        _ = try store.openProject(id: a.id, mode: .openNew, contentFactory: { _ in nil })
        #expect(store.windows.flatMap(\.sessions).filter { $0.projectID == a.id }.count == 2)

        let rows = OpenQuicklyFilter.projectRows(in: store)
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(rows.first { $0.id == a.id }?.isOpen == true)
        #expect(rows.first { $0.id == b.id }?.isOpen == false)
    }

    @Test func aProjectWithoutASessionIsNotMarkedOpen() throws {
        let fixture = Fixture()
        let store = try fixture.store(projectsEnabled: true, seeding: [project("Alpha")])
        #expect(OpenQuicklyFilter.projectRows(in: store).map(\.isOpen) == [false])
    }
}

@MainActor
struct OpenQuicklyActionTests {
    @Test func returnOnAProjectFocusesOrOpensAndOptionReturnOpensAnother() {
        let target = row("Alpha")
        let window = WindowRuntime(bellFeed: BellFeedStore(), nameCache: SessionNameCache())
        #expect(OpenQuicklyFilter.choose(.project(target), optionHeld: false, in: window) == .openProject(target.id, .focusExistingOrOpen))
        #expect(OpenQuicklyFilter.choose(.project(target), optionHeld: true, in: window) == .openProject(target.id, .openNew))
    }

    @Test func activatingAProjectRowReportsTheActionAndOpensNothing() throws {
        let fixture = Fixture()
        let alpha = project("Alpha")
        let store = try fixture.store(projectsEnabled: true, seeding: [alpha])
        let window = store.windows[0]
        let sessionCount = window.sessions.count
        var reported: [OpenQuicklyAction] = []
        let target = try #require(OpenQuicklyFilter.projectRows(in: store).first)

        OpenQuicklyFilter.activate(.project(target), optionHeld: true, in: window) { reported.append($0) }

        #expect(reported == [.openProject(alpha.id, .openNew)])
        #expect(window.sessions.count == sessionCount)
        #expect(store.openProjectIDs.isEmpty)
    }

    @Test func aTabRowJumpsWithOrWithoutOptionAndReportsNoAction() {
        let window = WindowRuntime(bellFeed: BellFeedStore(), nameCache: SessionNameCache())
        _ = window.addSession()
        let first = window.sessions[0], second = window.sessions[1]
        for optionHeld in [false, true] {
            window.setSelectedSession(id: first.id)
            let pane = second.focusedPaneAnyKind
            let result = QuickOpenResult(
                sessionID: second.id, sessionTitle: second.title,
                tabID: pane.activeTabID, tabTitle: "t")
            let action = OpenQuicklyFilter.choose(.tab(result), optionHeld: optionHeld, in: window)
            #expect(action == nil)
            #expect(window.selectedSessionID == second.id)
        }
    }
}

@MainActor
struct OpenQuicklyRoutingTests {
    @Test func theChosenProjectOpensOnlyWhenTheHostPerformsTheValue() throws {
        let fixture = Fixture()
        let alpha = project("Alpha")
        let store = try fixture.store(projectsEnabled: true, seeding: [alpha])
        _ = try store.openProject(id: alpha.id, contentFactory: { _ in nil })
        let original = try #require(store.windows[0].sessions.first { $0.projectID == alpha.id })
        store.windows[0].setSelectedSession(id: store.windows[0].sessions[0].id)
        var activated: [WindowRuntime] = []
        store.windowActivationObserver = { activated.append($0) }

        let rowForAlpha = try #require(OpenQuicklyFilter.projectRows(in: store).first)
        let action = OpenQuicklyFilter.choose(.project(rowForAlpha), optionHeld: false, in: store.windows[0])
        #expect(action == .openProject(alpha.id, .focusExistingOrOpen))
        #expect(activated.isEmpty)

        let sessionCount = store.windows[0].sessions.count
        action?.perform(in: store)

        #expect(activated.map(\.id) == [store.windows[0].id])
        #expect(store.windows[0].selectedSessionID == original.id)
        #expect(store.windows[0].sessions.count == sessionCount)
    }

    @Test func aMissingProjectIsShownToThePersonWhoAskedForIt() throws {
        let fixture = Fixture()
        let store = try fixture.store(projectsEnabled: true)
        let missing = UUID()
        var shown: [Error] = []
        OpenQuicklyAction.openProject(missing, .focusExistingOrOpen).perform(in: store) { shown.append($0) }
        #expect((shown.first as? ProjectOpenError) == .unknownProject(missing))
    }

    @Test func aProjectWithAnUnapprovedCommandSetPresentsTheTrustSheetOnThisWindow() throws {
        let fixture = Fixture()
        var guarded = project("Guarded")
        guarded.layout.root = guarded.layout.root.withPanes([
            .terminal(tabs: [ProjectTab(title: "t", workingDirectory: ".", startupCommand: "echo hi")]),
        ])
        guarded.runStartupCommandsOnOpen = true
        let store = try fixture.store(projectsEnabled: true, seeding: [guarded])
        OpenQuicklyAction.openProject(guarded.id, .focusExistingOrOpen).perform(in: store)
        #expect(store.windows[0].pendingStartupTrusts.first?.projectID == guarded.id)
    }
}

@MainActor
struct OpenQuicklyFlagOffTests {
    @Test func flagOffYieldsNoProjectRowsAndNeverBuildsTheStore() throws {
        let fixture = Fixture()
        let store = try fixture.store(projectsEnabled: false)

        #expect(OpenQuicklyFilter.projectRows(in: store).isEmpty)
        #expect(!store.projectStoreIsConstructed)
        #expect(!FileManager.default.fileExists(atPath: fixture.projectsFile.path))
    }

    @Test func aFlagOffOpenActionStillFailsWithoutBuildingTheStore() throws {
        let fixture = Fixture()
        let store = try fixture.store(projectsEnabled: false)
        var shown: [Error] = []
        OpenQuicklyAction.openProject(UUID(), .openNew).perform(in: store) { shown.append($0) }
        #expect((shown.first as? ProjectOpenError) == .featureDisabled)
        #expect(!store.projectStoreIsConstructed)
    }
}
