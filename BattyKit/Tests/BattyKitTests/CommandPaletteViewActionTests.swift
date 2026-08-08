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
}
