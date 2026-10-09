// PasteConfirmationTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

/// #0316: `PasteDispatcher`'s target resolution once read
/// `store.keyWindowRuntime() ?? store.windows[0]` directly before this
/// issue's fix — an unguarded array subscript that traps when `windows` is
/// empty, the state the app deliberately lives in for one run-loop turn
/// after the last content window closes (see `AppStateStore
/// .terminateIfLastContentWindowGone()`'s doc comment). #0332 replaced that
/// local resolution with a call straight through to
/// `AppStateStore.focusedTerminalTab` — this exercises it through the
/// public `PasteDispatcher.confirm(_:in:)` entry point, the closest
/// testable seam to the real code path — a re-typed copy of the expression
/// would not catch a regression in the shipped line the way calling
/// through does.
///
/// `PasteConfirmationNonTerminalPaneTests` below mutates real process-global
/// state (`NSPasteboard.general`) to reproduce #0332's silent-no-op bug end
/// to end and restores it in a `defer`. The paste-strictness setting it
/// needs goes through the test's own store's `preferences` — a private
/// `UserDefaults` suite, not `.standard` (#0426) — so it needs no save/
/// restore of its own.
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

@MainActor
struct PasteConfirmationNonTerminalPaneTests {

    /// #0332: with a non-terminal pane focused, `PasteDispatcher
    /// .focusedTerminalTab(in:)` used to resolve through plain `focusedPane`
    /// and return the structural placeholder tab (non-nil), so
    /// `handlePasteRequest` skipped its `forwardStandardPaste()` fallback at
    /// the top and — when paste strictness triggers, as it deterministically
    /// does here — posted `.battyRequestPaste` for a paste that could never
    /// land (the placeholder tab's `TerminalViewState` has no live surface).
    /// Now that both dispatchers resolve through the shared, kind-gated
    /// `AppStateStore.focusedTerminalTab`, the guard at the top of
    /// `handlePasteRequest` fails fast and no confirmation is ever posted.
    @Test func handlePasteRequestDoesNotPostAConfirmationWhenANonTerminalPaneIsFocused() {
        let testDefaults = TestDefaults()
        defer { testDefaults.tearDown() }

        let store = AppStateStore(preferences: testDefaults.defaults)
        let session = store.sessions[0]
        let terminalPane = session.focusedPaneAnyKind
        // `contentFactory: { _ in nil }` (#0313's seam) avoids starting
        // `.gitStatus`'s real conformer (a real `FSEventStream`) as a test
        // side effect.
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .gitStatus, contentFactory: { _ in nil }, isSessionSelected: true)
        #expect(nonTerminalPane?.content == nil)
        #expect(session.focusedPaneAnyKind.kind == .gitStatus, "test setup: the split must move focus to the non-terminal pane")

        let savedPasteboard = NSPasteboard.general.string(forType: .string)
        let savedForwardStandardPaste = PasteDispatcher.forwardStandardPaste
        defer {
            if let savedPasteboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(savedPasteboard, forType: .string)
            } else {
                NSPasteboard.general.clearContents()
            }
            PasteDispatcher.forwardStandardPaste = savedForwardStandardPaste
        }
        testDefaults.defaults.set(PasteStrictness.alwaysOnMultiline.rawValue, forKey: SettingsPreference.pasteStrictnessKey)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("line one\nline two\n", forType: .string)

        var posted = false
        let observer = NotificationCenter.default.addObserver(
            forName: .battyRequestPaste, object: nil, queue: nil
        ) { _ in posted = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        // #0332 N2: assert the responder-chain fallback actually ran, not
        // merely that no confirmation was posted — the latter would also
        // pass if `handlePasteRequest` had simply suppressed the sheet
        // without restoring standard paste behavior at all.
        var forwardedStandardPaste = false
        PasteDispatcher.forwardStandardPaste = { forwardedStandardPaste = true }

        PasteDispatcher.handlePasteRequest(store: store)

        #expect(!posted, "a non-terminal focused pane must never surface a paste confirmation for a paste that cannot land")
        #expect(forwardedStandardPaste, "must fall back to the standard responder-chain paste, not silently drop it")
    }
}
