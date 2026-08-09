// ExitDispatcherTests.swift

import Foundation
import Testing
@testable import BattyKit

/// #0309: `ExitDispatcher` resolves its target the same way `PasteDispatcher`
/// does (`store.keyWindowOrFirstRegistered()?.selectedSession?.focusedPane
/// .activeTab`), so it inherits the same no-window edge case exercised by
/// `PasteConfirmationTests` — must no-op cleanly rather than trap when
/// `windows` is empty, the state the app deliberately lives in for one
/// run-loop turn after the last content window closes.
///
/// `terminal.send(_:)` returns `false` and logs when no live libghostty
/// surface is attached (the case here, with no running app), so these tests
/// verify target *resolution* — which tab would receive the text — rather
/// than PTY bytes, which need a live surface to observe.
@MainActor
struct ExitDispatcherTests {

    private func makeStoreWithNoWindows() -> AppStateStore {
        let store = AppStateStore()
        // #0311 gotcha: removing the last window schedules a deferred
        // NSApp.terminate(nil); stub it out so this test never invokes
        // AppKit's real termination path.
        store.terminateHandler = {}
        let onlyWindowID = store.windows[0].id
        store.removeWindow(id: onlyWindowID)
        #expect(store.windows.isEmpty, "test setup: windows must be empty")
        return store
    }

    @Test func focusedTerminalTabResolvesToFocusedPaneActiveTabWhenTerminalIsFocused() {
        let store = AppStateStore()
        let expectedTabID = store.windows[0].selectedSession?.focusedPane.activeTab?.id
        #expect(expectedTabID != nil, "test setup: a fresh store must have a focused tab")

        let resolved = ExitDispatcher.focusedTerminalTab(in: store)

        #expect(resolved?.id == expectedTabID)
    }

    @Test func focusedTerminalTabIsNilWhenNoWindowsRemain() {
        let store = makeStoreWithNoWindows()

        #expect(ExitDispatcher.focusedTerminalTab(in: store) == nil)
    }

    /// #0315 review round 2, finding 2: `focusedTerminalTab` resolved
    /// through `focusedPane` directly, with no kind check — routing
    /// through `SessionRuntime.focusedTerminalPane` makes "nothing to
    /// target" explicit for a non-terminal focused pane rather than
    /// coincidentally harmless (the phantom tab's `TerminalViewState.send`
    /// already no-ops on a nil surface, but resolution should say so, not
    /// rely on that downstream safety net).
    @Test func focusedTerminalTabIsNilWhenANonTerminalPaneIsFocused() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let terminalPane = session.focusedPane
        _ = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .gitStatus)
        #expect(session.focusedPane.kind == .gitStatus, "test setup: the split must move focus to the non-terminal pane")

        #expect(ExitDispatcher.focusedTerminalTab(in: store) == nil)
    }

    @Test func sendExitDoesNotTrapWhenNoWindowsRemain() {
        let store = makeStoreWithNoWindows()

        // Must return cleanly rather than trapping on an empty windows array,
        // and must not create a phantom window/session as a side effect.
        ExitDispatcher.sendExit(store: store)

        #expect(store.windows.isEmpty, "sendExit must not create a phantom window")
    }

    @Test func sendExitDoesNotTrapWhenStoreIsNil() {
        // No Terminal pane can be focused without a store at all (e.g. a
        // dispatch site that failed to resolve one); must no-op rather than
        // force-unwrap or crash.
        ExitDispatcher.sendExit(store: nil)
    }

    @Test func sendExitDoesNotTrapWhenTerminalIsFocused() {
        let store = AppStateStore()

        // No live libghostty surface is attached in a unit test, so
        // `terminal.send` returns `false` internally and logs — this test
        // confirms the dispatch path itself (resolve target, call send)
        // completes without trapping when a Terminal pane *is* focused.
        ExitDispatcher.sendExit(store: store)

        #expect(store.windows.count == 1, "sendExit must not mutate window count")
    }
}
