// CommandPaletteViewActionTests.swift

import Foundation
import SwiftUI
import Testing
@testable import BattyKit

/// #0316: `CommandPaletteView`'s "Duplicate Session" action and `dispatch(_:)`
/// both read `store.keyWindowRuntime() ?? store.windows[0]` before this
/// issue's fix — an unguarded array subscript that traps when `windows` is
/// empty, the state the app deliberately lives in for one run-loop turn
/// after the last content window closes (see `AppStateStore
/// .terminateIfLastContentWindowGone()`'s doc comment). These tests call the
/// production `allCommands`/`dispatch(_:)` members directly (loosened from
/// `private` to `internal` for exactly this purpose) rather than
/// re-implementing their bodies, so a regression in the shipped code is what
/// they'd actually catch.
@MainActor
struct CommandPaletteViewActionTests {

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

    @Test func duplicateSessionActionNoOpsWhenNoWindowsRemain() {
        let store = makeStoreWithNoWindows()
        let view = CommandPaletteView(isPresented: .constant(true), store: store)

        let duplicateCommand = view.allCommands.first { $0.id == "extra:duplicateSession" }
        #expect(duplicateCommand != nil, "test setup: Duplicate Session command must exist")

        duplicateCommand?.action()

        #expect(store.windows.isEmpty,
                "Duplicate Session must not create a phantom window/session when none remain")
    }

    @Test func dispatchNoOpsWhenNoWindowsRemain() {
        let store = makeStoreWithNoWindows()
        let view = CommandPaletteView(isPresented: .constant(true), store: store)

        // .newSession routes to `window.addSession()` when a window exists;
        // must not create one from nothing.
        view.dispatch(.newSession)

        #expect(store.windows.isEmpty,
                "dispatch(_:) must not create a phantom window when none remain")
    }

    @Test func dispatchExitShellNoOpsWhenNoWindowsRemain() {
        let store = makeStoreWithNoWindows()
        let view = CommandPaletteView(isPresented: .constant(true), store: store)

        // .exitShell routes through ExitDispatcher, which resolves
        // store.keyWindowOrFirstRegistered(); must not trap or create a
        // phantom window when none remain (#0309).
        view.dispatch(.exitShell)

        #expect(store.windows.isEmpty,
                "dispatch(.exitShell) must not create a phantom window when none remain")
    }

    @Test func dispatchExitShellDoesNotTrapWhenTerminalIsFocused() {
        let store = AppStateStore()
        let view = CommandPaletteView(isPresented: .constant(true), store: store)

        view.dispatch(.exitShell)

        #expect(store.windows.count == 1, "dispatch(.exitShell) must not mutate window count")
    }

    // MARK: - #0315 review round 2, finding 2: dispatch(_:) was a third,
    // completely ungated copy of the Tab-scoped-command switch — Cmd-T from
    // the Command Palette silently added a second invisible tab to a
    // focused non-terminal pane, verbatim the defect round 1 fixed in the
    // menu bar and the `BattyShortcuts` NSEvent monitor but missed here.
    // `SplitTree.splitPane` moves focus to a freshly-split pane when the
    // split target was already focused, so splitting the (already-focused)
    // default pane with a non-terminal kind reproduces exactly the state
    // `batty pane split --view git-status` leaves behind.

    @Test func dispatchNewTabDoesNotMutateANonTerminalFocusedPane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let terminalPane = session.focusedPane
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .gitStatus)!
        #expect(session.tree.focusedPaneID == nonTerminalPane.id,
                "test setup: splitting the focused pane must move focus to the new pane")

        let view = CommandPaletteView(isPresented: .constant(true), store: store)
        view.dispatch(.newTab)

        #expect(nonTerminalPane.tabs.count == 1,
                "dispatch(.newTab) must not add a second invisible tab to a non-terminal focused pane")
    }

    @Test func dispatchCloseTabDoesNotRemoveANonTerminalFocusedPane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let terminalPane = session.focusedPane
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .gitStatus)!
        #expect(session.tree.focusedPaneID == nonTerminalPane.id)
        let paneCountBefore = session.tree.allPanes.count

        let view = CommandPaletteView(isPresented: .constant(true), store: store)
        view.dispatch(.closeTab)

        #expect(session.tree.allPanes.count == paneCountBefore,
                "dispatch(.closeTab) must not close a non-terminal pane's structural placeholder tab")
    }

    @Test func dispatchPreviousAndNextTabDoNotMutateANonTerminalFocusedPane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let terminalPane = session.focusedPane
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .processStatus)!
        let activeTabIDBefore = nonTerminalPane.activeTabID

        let view = CommandPaletteView(isPresented: .constant(true), store: store)
        view.dispatch(.previousTab)
        view.dispatch(.nextTab)

        #expect(nonTerminalPane.activeTabID == activeTabIDBefore)
    }
}
