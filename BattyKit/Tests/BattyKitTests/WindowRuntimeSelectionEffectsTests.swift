// WindowRuntimeSelectionEffectsTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

/// The selection effects `WindowRuntime.selectedSessionID`'s `didSet` runs
/// for every path that changes the selection: focus the selected Session's
/// focused Tab, mark it seen, apply its Session Theme, and deny the previous
/// Session's pending clipboard request. Also the close- and hide-driven
/// passive mark-seen (`notePassiveFocusMove`).
@MainActor
struct WindowRuntimeSelectionEffectsTests {

    nonisolated enum SelectionPath: CaseIterable, Sendable {
        case sidebar, sidebarPaneRow, cmdNumber, openQuickly, bellJump, reminderJump
        case cliFocusSession, cliFocusPane, cliFocusTab, openProjectExisting, removeSelected, directWrite
    }

    nonisolated enum NewSessionPath: CaseIterable, Sendable {
        case newSession, duplicate, openProjectNew
    }

    /// Every path but `removeSelected`: there the previous Session is gone
    /// before the selection moves, so there is nothing left to deny.
    nonisolated static let pathsWithAPreviousSession = SelectionPath.allCases.filter { $0 != .removeSelected }

    @MainActor
    final class Fixture {
        let files: ProjectBackgroundFixture
        let store: AppStateStore
        let window: WindowRuntime
        let global: GhosttyThemeDefinition
        let sessionTheme: GhosttyThemeDefinition
        var focused: [UUID] = []
        var decisions: [Bool] = []

        init() throws {
            files = try ProjectBackgroundFixture()
            let themes = Array(BattyThemeCatalog.allThemes.prefix(2))
            global = try #require(themes.first)
            sessionTheme = try #require(themes.last)
            let defaults = files.testDefaults.defaults
            defaults.set(true, forKey: ThemePreference.migrationDoneKey)
            defaults.set(global.name, forKey: ThemePreference.darkDefaultsKey)
            defaults.set(global.name, forKey: ThemePreference.lightDefaultsKey)
            store = files.appStore()
            store.isBattyActiveProvider = { false }
            window = store.windows[0]
            recordFocus(on: window)
        }

        var pair: ThemePair { ThemePair(dark: sessionTheme.name, light: sessionTheme.name) }
        var source: SessionRuntime { window.sessions[0] }

        func recordFocus(on window: WindowRuntime) {
            window.focusTerminal = { [weak self] tab in self?.focused.append(tab.id) }
        }

        func addWindow() -> WindowRuntime {
            let added = store.openWindowRuntime(for: WindowID())
            recordFocus(on: added)
            return added
        }

        func uses(_ theme: GhosttyThemeDefinition, _ session: SessionRuntime) -> Bool {
            let tabs = session.tree.allPanes.filter { $0.kind == .terminal }.flatMap(\.tabs)
            let expected = theme.toTerminalTheme()
            return !tabs.isEmpty && tabs.allSatisfy { $0.terminal.controller.theme == expected }
        }

        func requestClipboard(in session: SessionRuntime) {
            session.requestClipboardReadConfirmation(kind: .osc52Read) { [weak self] in self?.decisions.append($0) }
        }

        func entries(for tab: TabRuntime) -> [BellFeedEntry] {
            store.bellFeed.entries.filter { $0.tabID == tab.id }
        }

        /// Gives `pane`'s Tab `tab` unseen bells while it is in front, by
        /// ringing while another Tab is active and then moving the active
        /// Tab back with a plain model write, which runs no selection effects
        /// (in the selected Session it does request focus, through the tree).
        func ringWhileInFront(_ tab: TabRuntime, in pane: PaneRuntime) {
            let other = pane.tabs.first { $0.id != tab.id } ?? pane.addTab()
            pane.activeTabID = other.id
            store.ringBell(in: tab, times: 2)
            pane.activeTabID = tab.id
        }
    }

    struct Target {
        let project: Project
        let session: SessionRuntime
        let pane: PaneRuntime
        let tab: TabRuntime
    }

    /// The selected Session is plain and has a pending clipboard request.
    /// The target is a Project Session with a Session Theme, its surfaces
    /// reset to the global Theme, and 2 unseen bells on its focused Tab.
    /// The chrome shows the global Theme.
    private func existingTarget(_ f: Fixture) throws -> Target {
        var project = f.files.project(name: "Target", background: nil)
        project.theme = f.pair
        try f.store.projectStore.upsert(project)
        let session = try f.store.openProject(id: project.id, mode: .openNew).session
        f.window.setSelectedSession(id: f.source.id)
        f.store.applyTerminalTheme(f.global, to: session)
        let pane = session.focusedPaneAnyKind
        let tab = try #require(pane.activeTab)
        f.store.ringBell(in: tab, times: 2)
        f.requestClipboard(in: f.source)
        f.focused.removeAll()

        #expect(f.window.selectedSessionID == f.source.id)
        #expect(tab.unseenBellCount == 2 && pane.unseenBellCount == 2 && session.unseenBellCount == 2)
        #expect(f.source.pendingClipboardConfirmation != nil)
        #expect(f.store.themeChrome.palette == ChromePalette(theme: f.global))
        #expect(!f.uses(f.sessionTheme, session))
        return Target(project: project, session: session, pane: pane, tab: tab)
    }

    private func select(_ path: SelectionPath, _ t: Target, _ f: Fixture) throws {
        switch path {
        case .sidebar:
            f.window.selectSessionFromSidebar(id: t.session.id)
        case .sidebarPaneRow:
            f.window.activatePaneFromSidebar(sessionID: t.session.id, paneID: t.pane.id)
        case .cmdNumber:
            f.window.selectSession(at: try #require(f.window.sessions.firstIndex { $0 === t.session }))
        case .openQuickly:
            f.window.jumpToTab(sessionID: t.session.id, tabID: t.tab.id)
        case .bellJump:
            f.window.jumpToBellEntry(try #require(f.entries(for: t.tab).first))
        case .reminderJump:
            let entry = f.store.bellFeed.record(BellFeedEntry(
                timestamp: ReminderFixture.anchor,
                windowID: f.window.id.value,
                sessionID: t.session.id,
                paneID: t.pane.id,
                tabID: t.tab.id,
                surfaceID: UUID(),
                message: "reminder",
                seen: false,
                kind: .reminder))
            f.window.jumpToBellEntry(entry)
        case .cliFocusSession:
            _ = f.store.focusSessionForXPC(id: t.session.id)
        case .cliFocusPane:
            f.store.focusPaneForXPC(id: t.pane.id)
        case .cliFocusTab:
            f.store.focusTabForXPC(id: t.tab.id)
        case .openProjectExisting:
            let result = try f.store.openProject(id: t.project.id)
            #expect(!result.wasCreated)
        case .removeSelected:
            f.window.removeSession(id: f.source.id)
        case .directWrite:
            f.store.selectedSessionID = t.session.id
        }
        #expect(f.window.selectedSessionID == t.session.id)
    }

    // MARK: - Every path

    @Test(arguments: SelectionPath.allCases)
    func selectionFocusesTheSelectedSessionsFocusedTab(path: SelectionPath) throws {
        let f = try Fixture()
        let t = try existingTarget(f)
        try select(path, t, f)
        #expect(f.focused == [t.tab.id])
    }

    @Test(arguments: NewSessionPath.allCases)
    func newSessionFocusesItsFocusedTab(path: NewSessionPath) throws {
        let f = try Fixture()
        let session: SessionRuntime
        switch path {
        case .newSession:
            session = f.window.addSession()
        case .duplicate:
            session = try #require(f.window.duplicateSession(id: f.source.id))
        case .openProjectNew:
            let project = f.files.project(name: "New", background: nil)
            try f.store.projectStore.upsert(project)
            session = try f.store.openProject(id: project.id, mode: .openNew).session
        }
        let tab = try #require(session.focusedPaneAnyKind.activeTab)
        #expect(f.window.selectedSessionID == session.id)
        #expect(f.focused == [tab.id])
    }

    @Test(arguments: SelectionPath.allCases)
    func selectionMarksTheSelectedTabSeen(path: SelectionPath) throws {
        let f = try Fixture()
        let t = try existingTarget(f)
        try select(path, t, f)
        #expect(t.tab.unseenBellCount == 0)
        #expect(t.pane.unseenBellCount == 0)
        #expect(t.session.unseenBellCount == 0)
        #expect(f.entries(for: t.tab).allSatisfy { $0.seen })
    }

    @Test(arguments: SelectionPath.allCases)
    func selectionAppliesTheSelectedSessionsThemeToChromeAndSurfaces(path: SelectionPath) throws {
        let f = try Fixture()
        let t = try existingTarget(f)
        try select(path, t, f)
        #expect(f.store.themeChrome.palette == ChromePalette(theme: f.sessionTheme))
        #expect(f.uses(f.sessionTheme, t.session))
    }

    @Test(arguments: pathsWithAPreviousSession)
    func selectionDeniesThePreviousSessionsPendingClipboardRequest(path: SelectionPath) throws {
        let f = try Fixture()
        let t = try existingTarget(f)
        try select(path, t, f)
        #expect(f.decisions == [false])
        #expect(f.source.pendingClipboardConfirmation == nil)
    }

    @Test func newSessionResetsChromeToTheGlobalTheme() throws {
        let f = try Fixture()
        let t = try existingTarget(f)
        f.window.setSelectedSession(id: t.session.id)
        #expect(f.store.themeChrome.palette == ChromePalette(theme: f.sessionTheme))

        f.window.addSession()

        #expect(f.store.themeChrome.palette == ChromePalette(theme: f.global))
    }

    @Test func duplicateCarriesTheSourceSessionThemeToItsSurfaces() throws {
        let f = try Fixture()
        let t = try existingTarget(f)

        let copy = try #require(f.window.duplicateSession(id: t.session.id))

        #expect(copy.themeOverride == f.pair)
        #expect(f.uses(f.sessionTheme, copy))
        #expect(f.store.themeChrome.palette == ChromePalette(theme: f.sessionTheme))
    }

    @Test func reselectingTheSelectedSessionRunsNoEffects() throws {
        let f = try Fixture()
        let pane = f.source.focusedPaneAnyKind
        let tab = try #require(pane.activeTab)
        f.ringWhileInFront(tab, in: pane)
        f.requestClipboard(in: f.source)
        f.focused.removeAll()
        #expect(tab.unseenBellCount == 2)

        f.window.setSelectedSession(id: f.source.id)
        f.window.selectSessionFromSidebar(id: f.source.id)
        f.store.selectedSessionID = f.source.id

        #expect(f.focused.isEmpty)
        #expect(f.decisions.isEmpty)
        #expect(f.source.pendingClipboardConfirmation != nil)
        #expect(tab.unseenBellCount == 2)
    }

    // MARK: - Arrange first, select last

    /// A non-selected target Session with two Panes. The first is focused;
    /// both Panes' active Tabs have 2 unseen bells.
    private struct TwoPaneTarget {
        let session: SessionRuntime
        let first: PaneRuntime
        let second: PaneRuntime
        var firstTab: TabRuntime { first.activeTab! }
        var secondTab: TabRuntime { second.activeTab! }
    }

    private func twoPaneTarget(_ f: Fixture) throws -> TwoPaneTarget {
        let session = f.window.addSession()
        let first = session.focusedPaneAnyKind
        let secondID = try #require(f.store.splitPane(id: first.id, direction: .horizontal))
        let second = try #require(session.tree.allPanes.first { $0.id == secondID })
        session.tree.focusedPaneID = first.id
        f.window.setSelectedSession(id: f.source.id)
        let target = TwoPaneTarget(session: session, first: first, second: second)
        f.store.ringBell(in: target.firstTab, times: 2)
        f.store.ringBell(in: target.secondTab, times: 2)
        f.focused.removeAll()
        #expect(target.firstTab.unseenBellCount == 2 && target.secondTab.unseenBellCount == 2)
        return target
    }

    private func expectOnlySecondPaneHandled(_ t: TwoPaneTarget, _ f: Fixture) {
        #expect(f.window.selectedSessionID == t.session.id)
        #expect(t.session.tree.focusedPaneID == t.second.id)
        #expect(t.secondTab.unseenBellCount == 0)
        #expect(t.firstTab.unseenBellCount == 2, "the previously focused Pane's Tab was marked seen")
        #expect(f.focused == [t.secondTab.id], "focus went somewhere before the target")
    }

    @Test func jumpToTabMarksOnlyTheTargetTabSeen() throws {
        let f = try Fixture()
        let t = try twoPaneTarget(f)
        f.window.jumpToTab(sessionID: t.session.id, tabID: t.secondTab.id)
        expectOnlySecondPaneHandled(t, f)
    }

    @Test func bellJumpMarksOnlyTheTargetTabSeen() throws {
        let f = try Fixture()
        let t = try twoPaneTarget(f)
        f.window.jumpToBellEntry(try #require(f.entries(for: t.secondTab).first))
        expectOnlySecondPaneHandled(t, f)
    }

    @Test func sidebarPaneRowMarksOnlyThatPanesTabSeen() throws {
        let f = try Fixture()
        let t = try twoPaneTarget(f)
        f.window.activatePaneFromSidebar(sessionID: t.session.id, paneID: t.second.id)
        expectOnlySecondPaneHandled(t, f)
    }

    @Test func cliFocusPaneMarksOnlyThatPanesTabSeen() throws {
        let f = try Fixture()
        let t = try twoPaneTarget(f)
        f.store.focusPaneForXPC(id: t.second.id)
        expectOnlySecondPaneHandled(t, f)
    }

    @Test func cliFocusTabMarksOnlyThatTabSeen() throws {
        let f = try Fixture()
        let session = f.window.addSession()
        let pane = session.focusedPaneAnyKind
        let front = try #require(pane.activeTab)
        let back = pane.addTab()
        pane.activeTabID = front.id
        f.window.setSelectedSession(id: f.source.id)
        f.store.ringBell(in: front, times: 2)
        f.store.ringBell(in: back, times: 2)
        f.focused.removeAll()
        #expect(front.unseenBellCount == 2 && back.unseenBellCount == 2)

        f.store.focusTabForXPC(id: back.id)

        #expect(pane.activeTabID == back.id)
        #expect(back.unseenBellCount == 0)
        #expect(front.unseenBellCount == 2, "the previously active Tab was marked seen")
        #expect(f.focused == [back.id])
    }

    @Test func openProjectFocusesTheProjectsFocusedSlot() throws {
        let f = try Fixture()
        var layout = ProjectLayout.preset(.horizontalSplit)
        layout.focusedSlot = 1
        let project = f.files.project(name: "Two Panes", background: nil, layout: layout)
        try f.store.projectStore.upsert(project)
        f.focused.removeAll()

        let session = try f.store.openProject(id: project.id, mode: .openNew).session

        let panes = session.tree.allPanes
        #expect(panes.count == 2)
        let tab = try #require(panes.last?.activeTab)
        #expect(session.tree.focusedPaneID == panes[1].id)
        #expect(f.focused == [tab.id])
    }

    // MARK: - #0556: a passive selection marks seen, never removes rows

    @Test func removingTheSelectedSessionMarksTheNeighbourSeenWithoutRemovingRows() throws {
        let f = try Fixture()
        let t = try existingTarget(f)
        let rows = f.entries(for: t.tab).count
        #expect(rows > 0)

        f.window.removeSession(id: f.source.id)

        #expect(f.window.selectedSessionID == t.session.id)
        #expect(t.tab.unseenBellCount == 0)
        #expect(f.entries(for: t.tab).count == rows, "a passive selection removed rows")
        #expect(f.entries(for: t.tab).allSatisfy { $0.seen })
    }

    // MARK: - Multi-window chrome

    /// A second window whose selected Session has the Session Theme.
    private func themedSecondWindow(_ f: Fixture) -> (WindowRuntime, SessionRuntime) {
        let second = f.addWindow()
        let themed = second.sessions[0]
        themed.themeOverride = f.pair
        second.addSession()
        second.setSelectedSession(id: themed.id)
        return (second, themed)
    }

    @Test func selectionInANonTargetWindowThemesSurfacesButLeavesChromeAlone() throws {
        let f = try Fixture()
        #expect(f.store.themeChrome.palette == ChromePalette(theme: f.global))

        let (second, themed) = themedSecondWindow(f)

        #expect(f.store.defaultTargetWindow() === f.window)
        #expect(second.selectedSessionID == themed.id)
        #expect(f.uses(f.sessionTheme, themed))
        #expect(f.store.themeChrome.palette == ChromePalette(theme: f.global))
    }

    @Test func contentWindowBecameKeyAppliesThatWindowsChrome() throws {
        let f = try Fixture()
        let (second, _) = themedSecondWindow(f)
        let nsWindow = NSWindow()
        f.store.registerNSWindow(nsWindow, for: second.id)
        #expect(f.store.themeChrome.palette == ChromePalette(theme: f.global))

        f.store.contentWindowBecameKey(second.id)

        #expect(f.store.themeChrome.palette == ChromePalette(theme: f.sessionTheme))
        #expect(f.store.defaultTargetWindow() === second)
        f.window.addSession()
        #expect(f.store.themeChrome.palette == ChromePalette(theme: f.sessionTheme), "a selection in the other window moved the chrome")
        withExtendedLifetime(nsWindow) {}
    }

    // MARK: - Passive focus moves

    @Test func closingTheActiveTabMarksTheNewActiveTabSeenWithoutRemovingRows() throws {
        let f = try Fixture()
        let pane = f.source.focusedPaneAnyKind
        let kept = try #require(pane.activeTab)
        let closing = pane.addTab()
        f.store.ringBell(in: kept, times: 2)
        let rows = f.entries(for: kept).count
        #expect(kept.unseenBellCount == 2 && rows > 0)

        f.window.closeTab(id: closing.id)

        #expect(pane.activeTabID == kept.id)
        #expect(kept.unseenBellCount == 0)
        #expect(f.entries(for: kept).count == rows, "a passive move removed rows")
        #expect(f.entries(for: kept).allSatisfy { $0.seen })
    }

    @Test func closeOtherTabsMarksTheKeptTabSeen() throws {
        let f = try Fixture()
        let pane = f.source.focusedPaneAnyKind
        let kept = try #require(pane.activeTab)
        _ = pane.addTab()
        f.store.ringBell(in: kept, times: 2)
        #expect(kept.unseenBellCount == 2)

        f.window.closeOtherTabs(in: pane, keeping: kept.id)

        #expect(pane.activeTabID == kept.id)
        #expect(kept.unseenBellCount == 0)
    }

    /// The selected Session split in two, the new second Pane focused, and
    /// 2 unseen bells on the first Pane's Tab.
    private func splitSelected(_ f: Fixture, in window: WindowRuntime) throws -> (first: PaneRuntime, second: UUID, tab: TabRuntime) {
        let session = try #require(window.selectedSession)
        let first = session.focusedPaneAnyKind
        let second = try #require(f.store.splitPane(id: first.id, direction: .horizontal))
        #expect(session.tree.focusedPaneID == second)
        let tab = try #require(first.activeTab)
        f.store.ringBell(in: tab, times: 2)
        #expect(tab.unseenBellCount == 2)
        return (first, second, tab)
    }

    @Test func closingTheFocusedPaneMarksTheSuccessorSeen() throws {
        let f = try Fixture()
        let split = try splitSelected(f, in: f.window)

        f.window.closePane(id: split.second, refuseIfAppsLastPane: false)

        #expect(f.source.tree.focusedPaneID == split.first.id)
        #expect(split.tab.unseenBellCount == 0)
    }

    @Test func hidingTheFocusedPaneMarksTheFallbackSeen() throws {
        let f = try Fixture()
        let split = try splitSelected(f, in: f.window)

        f.window.hidePane(id: split.second)

        #expect(f.source.tree.focusedPaneID == split.first.id)
        #expect(split.tab.unseenBellCount == 0)
    }

    @Test func passiveFocusMoveInANonTargetWindowMarksNothing() throws {
        let f = try Fixture()
        let second = f.addWindow()
        let split = try splitSelected(f, in: second)
        #expect(f.store.defaultTargetWindow() === f.window)

        second.closePane(id: split.second, refuseIfAppsLastPane: false)

        #expect(second.selectedSession?.tree.focusedPaneID == split.first.id)
        #expect(split.tab.unseenBellCount == 2)
    }

    @Test func closingANonActiveTabMarksNothing() throws {
        let f = try Fixture()
        let pane = f.source.focusedPaneAnyKind
        let front = try #require(pane.activeTab)
        let closing = pane.addTab()
        f.ringWhileInFront(front, in: pane)
        #expect(pane.activeTabID == front.id && front.unseenBellCount == 2)

        f.window.closeTab(id: closing.id)

        #expect(pane.activeTabID == front.id)
        #expect(front.unseenBellCount == 2, "a close that left focus where it was marked seen")
    }

    @Test func passiveFocusMoveInANonSelectedSessionMarksNothing() throws {
        let f = try Fixture()
        let other = f.window.addSession()
        let otherFirst = other.focusedPaneAnyKind
        let otherSecond = try #require(f.store.splitPane(id: otherFirst.id, direction: .horizontal))
        f.window.setSelectedSession(id: f.source.id)
        let pane = f.source.focusedPaneAnyKind
        let front = try #require(pane.activeTab)
        f.ringWhileInFront(front, in: pane)
        #expect(front.unseenBellCount == 2)

        f.window.closePane(id: otherSecond, refuseIfAppsLastPane: false)

        #expect(other.tree.focusedPaneID == otherFirst.id)
        #expect(front.unseenBellCount == 2, "a focus move in another Session marked the selected Session's Tab seen")
    }
}
