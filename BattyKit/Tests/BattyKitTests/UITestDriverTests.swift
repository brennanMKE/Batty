// UITestDriverTests.swift

import Foundation
import Testing
@testable import BattyKit

/// #0332 N1: nothing previously pinned the kind gate `UITestDriver.dispatch`
/// applies to `.createTab`/`.renameActiveTab`/`.resetActiveTabTitle` — all
/// existing tests pass identically whether or not those three cases are
/// gated (`UITestDriver` had zero references anywhere in
/// `BattyKit/Tests/`). `dispatch(_:store:)` is not `private` specifically
/// so this file can exercise it directly, the same precedent as
/// `ExitDispatcherTests` against `ExitDispatcher.focusedTerminalTab`.
@MainActor
struct UITestDriverTests {

    @Test func createTabOnANonTerminalFocusedPaneAddsNoTab() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let terminalPane = session.focusedPaneAnyKind
        // `contentFactory: { _ in nil }` (#0313's seam) keeps this split
        // from starting `.gitStatus`'s real conformer (a real
        // `FSEventStream`) as a side effect.
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .gitStatus, contentFactory: { _ in nil })
        #expect(nonTerminalPane?.content == nil)
        #expect(session.focusedPaneAnyKind.kind == .gitStatus, "test setup: the split must move focus to the non-terminal pane")
        let tabCountBefore = nonTerminalPane!.tabs.count

        UITestDriver.dispatch(.createTab, store: store)

        #expect(nonTerminalPane!.tabs.count == tabCountBefore, "must not add a second, unrendered tab to the non-terminal pane's structural placeholder")
    }

    @Test func createTabOnATerminalFocusedPaneAddsATab() {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        let tabCountBefore = pane.tabs.count

        UITestDriver.dispatch(.createTab, store: store)

        #expect(pane.tabs.count == tabCountBefore + 1)
    }
}
