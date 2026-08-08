// PasteConfirmationTests.swift

import Foundation
import Testing
@testable import BattyKit

/// #0316: `PasteDispatcher`'s private `focusedTerminalTab(in:)` read
/// `store.keyWindowRuntime() ?? store.windows[0]` before this issue's fix —
/// an unguarded array subscript that traps when `windows` is empty, the
/// state the app deliberately lives in for one run-loop turn after the last
/// content window closes (see `AppStateStore
/// .terminateIfLastContentWindowGone()`'s doc comment). `focusedTerminalTab`
/// itself is private, so this exercises it through the public
/// `PasteDispatcher.confirm(_:in:)` entry point, the closest testable seam
/// to the real code path — a re-typed copy of the expression would not
/// catch a regression in the shipped line the way calling through does.
@MainActor
struct PasteConfirmationTests {

    @Test func confirmDoesNotTrapWhenNoWindowsRemain() {
        let store = AppStateStore()
        // #0311 gotcha: removing the last window schedules a deferred
        // NSApp.terminate(nil); stub it out so this test never invokes
        // AppKit's real termination path.
        store.terminateHandler = {}
        let onlyWindowID = store.windows[0].id
        store.removeWindow(id: onlyWindowID)
        #expect(store.windows.isEmpty, "test setup: windows must be empty")

        let pending = PendingPaste(text: "echo hi")
        // Must return cleanly rather than trapping on an empty windows array.
        PasteDispatcher.confirm(pending, in: store)

        #expect(store.windows.isEmpty, "confirm must not create a phantom window")
    }
}
