// WindowRuntimeFocusIntentTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

/// Model-initiated terminal focus has one writer,
/// `WindowRuntime.requestTerminalFocus`, reached from the model setters
/// (`SplitTree.focusedPaneID`, `PaneRuntime.activeTabID`), the selection
/// write and first registration of a content window. A Session that is not
/// selected in its window issues nothing.
@MainActor
struct WindowRuntimeFocusIntentTests {

    @MainActor
    final class Fixture {
        let files: ProjectBackgroundFixture
        let store: AppStateStore
        let window: WindowRuntime
        let a: SessionRuntime
        let b: SessionRuntime
        var focused: [UUID] = []

        init() throws {
            files = try ProjectBackgroundFixture()
            store = files.appStore()
            window = store.windows[0]
            a = window.sessions[0]
            b = window.addSession()
            window.focusTerminal = { [weak self] tab in self?.focused.append(tab.id) }
            for session in [a, b] {
                session.tree.splitFocusedPane(direction: .horizontal)
            }
            window.setSelectedSession(id: a.id)
            focused.removeAll()
            #expect(window.selectedSessionID == a.id)
            #expect(a.tree.allPanes.count == 2 && b.tree.allPanes.count == 2)
        }

        func unfocusedPane(in session: SessionRuntime) throws -> PaneRuntime {
            try #require(session.tree.allPanes.first { $0.id != session.tree.focusedPaneID })
        }
    }

    // MARK: - Selected Session

    @Test func selectingATabInTheSelectedSessionIssuesOneFocusIntent() throws {
        let f = try Fixture()
        let pane = f.a.tree.focusedPane
        let second = pane.addTab()
        pane.activeTabID = pane.tabs[0].id
        f.focused.removeAll()

        f.window.selectNextTabInFocusedPane()

        #expect(pane.activeTabID == second.id)
        #expect(f.focused == [second.id])
    }

    @Test func addingATabToTheFocusedPaneIssuesOneFocusIntentForTheNewTab() throws {
        let f = try Fixture()
        let pane = f.a.tree.focusedPane

        let added = try #require(f.store.addTab(toPaneID: pane.id))

        #expect(f.focused == [added.id])
    }

    @Test func splittingTheSelectedSessionsFocusedPaneFocusesTheNewPane() throws {
        let f = try Fixture()

        let newPane = f.a.tree.splitFocusedPane(direction: .horizontal)

        #expect(f.a.tree.focusedPaneID == newPane.id)
        #expect(f.focused == [newPane.activeTabID])
    }

    @Test func focusingAnotherPaneInTheSelectedSessionIssuesOneFocusIntent() throws {
        let f = try Fixture()
        let other = try f.unfocusedPane(in: f.a)

        f.store.focusPane(id: other.id)

        #expect(f.focused == [other.activeTabID])
    }

    @Test func chipSelectionInAnUnfocusedPaneIssuesOneFocusIntentForTheChosenTab() throws {
        let f = try Fixture()
        let pane = try f.unfocusedPane(in: f.a)
        let second = pane.addTab()
        pane.activeTabID = pane.tabs[0].id
        f.focused.removeAll()

        pane.activeTabID = second.id
        f.store.focusPane(id: pane.id)

        #expect(f.focused == [second.id])
    }

    @Test func closingTheFocusedPanesActiveTabFocusesItsSuccessor() throws {
        let f = try Fixture()
        let pane = f.a.tree.focusedPane
        let second = pane.addTab()
        f.focused.removeAll()

        f.store.closeTab(id: second.id)

        #expect(pane.activeTabID != second.id)
        #expect(f.focused.last == pane.activeTabID)
    }

    @Test func registeringANewContentWindowRequestsFocusOnce() throws {
        let f = try Fixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer {
            f.store.unregisterNSWindow(window)
            window.close()
        }
        let expected = try #require(f.a.focusedPaneAnyKind.activeTab).id

        f.store.registerNSWindow(window, for: f.window.id)
        f.store.registerNSWindow(window, for: f.window.id)

        #expect(f.focused == [expected])
    }

    // MARK: - Non-selected Session

    @Test func focusMoveInAnUnselectedSessionIssuesNoFocusIntent() throws {
        let f = try Fixture()
        let other = try f.unfocusedPane(in: f.b)

        f.store.focusPane(id: other.id)

        #expect(f.b.tree.focusedPaneID == other.id)
        #expect(f.focused.isEmpty)
    }

    @Test func splittingABackgroundSessionsFocusedPaneIssuesNoFocusIntent() throws {
        let f = try Fixture()
        let target = f.b.tree.focusedPaneID

        let newID = try #require(f.store.splitPane(id: target, direction: .horizontal))

        #expect(f.b.tree.focusedPaneID == newID)
        #expect(f.focused.isEmpty)
    }

    @Test func tabSelectionInAnUnselectedSessionIssuesNoFocusIntent() throws {
        let f = try Fixture()
        let pane = f.b.tree.focusedPane
        let second = pane.addTab()
        pane.activeTabID = pane.tabs[0].id
        f.focused.removeAll()

        pane.selectNextTab()

        #expect(pane.activeTabID == second.id)
        #expect(f.focused.isEmpty)
    }

    @Test func sessionSwitchIssuesExactlyOneFocusIntent() throws {
        let f = try Fixture()
        let expected = try #require(f.b.focusedPaneAnyKind.activeTab).id

        f.window.setSelectedSession(id: f.b.id)

        #expect(f.focused == [expected])
    }

    @Test func jumpToTabInAnUnselectedSessionIssuesOneFocusIntentForTheTarget() throws {
        let f = try Fixture()
        let pane = try f.unfocusedPane(in: f.b)
        let target = pane.addTab()
        pane.activeTabID = pane.tabs[0].id
        f.focused.removeAll()

        f.store.jumpToTab(sessionID: f.b.id, tabID: target.id)

        #expect(f.window.selectedSessionID == f.b.id)
        #expect(f.focused == [target.id])
    }

    @Test func aDeselectedSessionStopsIssuingFocusIntents() throws {
        let f = try Fixture()
        f.window.setSelectedSession(id: f.b.id)
        f.focused.removeAll()
        let other = try f.unfocusedPane(in: f.a)

        f.store.focusPane(id: other.id)

        #expect(f.a.tree.focusedPaneID == other.id)
        #expect(f.focused.isEmpty)
    }
}
