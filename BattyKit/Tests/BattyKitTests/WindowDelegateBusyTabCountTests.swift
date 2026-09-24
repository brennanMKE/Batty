// WindowDelegateBusyTabCountTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `WindowDelegate.busyTabCount(in:)` (#0398) — the count
/// `windowShouldClose` shows the user in the "Close Window?" alert's
/// informative text ("There are N running process(es) in this window").
/// Extracted from `windowShouldClose` itself so it's unit-testable without
/// invoking `NSAlert.runModal()`, which would block indefinitely waiting
/// for a click that never comes in a headless test run — the same reason
/// `QuitConfirmation.openTerminalTabCount` was pulled out of
/// `shouldQuitOrPrompt`.
///
/// Previously unreachable in any environment (the seventh of #0398's seven
/// call sites): the polyfill hard-codes `needsConfirmClose` to `false`.
/// `TabRuntime.needsConfirmCloseOverride` drives it here without a live
/// surface.
@MainActor
struct WindowDelegateBusyTabCountTests {

    @Test func busyTabCountIsZeroForAnEntirelyIdleWindow() {
        let store = AppStateStore()
        let window = store.windows[0]

        #expect(WindowDelegate.busyTabCount(in: window) == 0)
    }

    /// Non-default fixture: tabs start idle (the type's default) and are
    /// flipped busy explicitly, across two different panes/sessions so the
    /// count is a real sum, not a single flag.
    @Test func busyTabCountSumsAcrossPanesAndSessions() {
        let store = AppStateStore()
        let window = store.windows[0]
        let firstSession = window.sessions[0]
        let secondSession = store.addSession(title: "Second")!
        let pane = firstSession.tree.allPanes[0]
        pane.addTab()
        pane.tabs[0].needsConfirmCloseOverride = true
        pane.tabs[1].needsConfirmCloseOverride = true
        secondSession.tree.allPanes[0].tabs[0].needsConfirmCloseOverride = true

        #expect(WindowDelegate.busyTabCount(in: window) == 3)
    }

    /// Mirrors `QuitConfirmation`'s own exclusion: a non-terminal pane's
    /// placeholder `TabRuntime` has no live Terminal Session behind it, but
    /// unlike `QuitConfirmation.windowNeedsConfirmClose` (which gates on
    /// `pane.kind == .terminal`), `busyTabCount` has no such kind check —
    /// pinned here as documentation of the current behavior rather than an
    /// assumed bug: `windowShouldClose` only ever reaches this count after
    /// `windowNeedsConfirmClose` already gated on `.terminal`-kind panes, so
    /// a non-terminal pane's tab can only be counted if a caller bypasses
    /// that gate, which `windowShouldClose` itself never does.
    @Test func busyTabCountIncludesNonTerminalPanesWhenCalledDirectly() {
        let store = AppStateStore()
        let window = store.windows[0]
        let session = window.sessions[0]
        let terminalPane = session.focusedPaneAnyKind
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .systemMetrics, isSessionSelected: true)!
        nonTerminalPane.tabs[0].needsConfirmCloseOverride = true

        #expect(WindowDelegate.busyTabCount(in: window) == 1)
    }
}
