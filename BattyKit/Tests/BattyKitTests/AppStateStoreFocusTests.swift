// AppStateStoreFocusTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct AppStateStoreFocusTests {

    @Test func focusPaneMovesFocusedPaneIDWithinOwningSession() {
        let store = AppStateStore()
        let session = store.sessions[0]
        session.tree.splitFocusedPane(direction: .horizontal)
        let panes = session.tree.allPanes
        #expect(panes.count == 2)
        let targetPane = panes.first { $0.id != session.tree.focusedPaneID }!

        store.focusPane(id: targetPane.id)

        #expect(session.tree.focusedPaneID == targetPane.id)
    }

    @Test func focusPaneFindsCorrectSessionAmongMany() {
        let store = AppStateStore()
        let other = store.addSession()!
        other.tree.splitFocusedPane(direction: .horizontal)
        let originalFocus = other.tree.focusedPaneID
        let targetPane = other.tree.allPanes.first { $0.id != originalFocus }!

        store.focusPane(id: targetPane.id)

        #expect(other.tree.focusedPaneID == targetPane.id)
    }

    @Test func focusPaneDoesNotChangeSelectedSession() {
        let store = AppStateStore()
        let firstSession = store.sessions[0]
        let secondSession = store.addSession()!
        store.selectedSessionID = firstSession.id
        let targetPane = secondSession.tree.allPanes[0]

        store.focusPane(id: targetPane.id)

        #expect(store.selectedSessionID == firstSession.id)
        #expect(secondSession.tree.focusedPaneID == targetPane.id)
    }

    @Test func focusPaneIsNoOpForUnknownID() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let before = session.tree.focusedPaneID

        store.focusPane(id: UUID())

        #expect(session.tree.focusedPaneID == before)
    }

    // MARK: - focusedTerminalTab (#0332)
    //
    // `AppStateStore.focusedTerminalTab` is the single canonical resolution
    // both `ExitDispatcher.sendExit` and `PasteDispatcher.handlePasteRequest`/
    // `.confirm` delegate to — see `AppStateStore.swift`'s doc comment. These
    // tests exercise the shared implementation directly rather than through
    // either dispatcher, since a regression here breaks both callers at once.

    @Test func focusedTerminalTabResolvesTheFocusedPanesActiveTabWhenTerminalIsFocused() {
        let store = AppStateStore()
        let expectedTabID = store.sessions[0].focusedPaneAnyKind.activeTab?.id
        #expect(expectedTabID != nil, "test setup: a fresh store must have a focused tab")

        #expect(store.focusedTerminalTab?.id == expectedTabID)
    }

    @Test func focusedTerminalTabIsNilWhenNoWindowsRemain() {
        let store = AppStateStore()
        // #0311 gotcha: removing the last window schedules a deferred
        // NSApp.terminate(nil); stub it out so this test never invokes
        // AppKit's real termination path.
        store.terminateHandler = {}
        store.removeWindow(id: store.windows[0].id)
        #expect(store.windows.isEmpty, "test setup: windows must be empty")

        #expect(store.focusedTerminalTab == nil)
    }

    /// #0332: `PasteDispatcher`'s own copy of this resolution had drifted to
    /// read plain `focusedPane` instead of `focusedTerminalPane`, so a
    /// non-terminal focused pane's structural placeholder tab
    /// (`PaneRuntime.kind`'s doc comment) resolved as a non-nil paste
    /// target. Both dispatchers now delegate here, so this one test
    /// protects both.
    @Test func focusedTerminalTabIsNilWhenANonTerminalPaneIsFocused() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let terminalPane = session.focusedPaneAnyKind
        // `contentFactory: { _ in nil }` (#0313's seam) keeps this split
        // from starting `.gitStatus`'s real conformer (a real
        // `FSEventStream`) as a side effect.
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .gitStatus, contentFactory: { _ in nil }, isSessionSelected: true)
        #expect(nonTerminalPane?.content == nil)
        #expect(session.focusedPaneAnyKind.kind == .gitStatus, "test setup: the split must move focus to the non-terminal pane")

        #expect(store.focusedTerminalTab == nil)
    }
}
