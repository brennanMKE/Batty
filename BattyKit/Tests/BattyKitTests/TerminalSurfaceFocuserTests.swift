// TerminalSurfaceFocuserTests.swift

import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

/// Smoke tests for ``TerminalSurfaceFocuser/focus(tab:)``. The real focus
/// path requires an attached NSWindow and a working layout pass — neither
/// is available in the test runner — so these tests cover only the early-
/// return predicates: no NSView, no window, hidden view. They guard
/// against regressing the lookup back to a `delegate === terminal`
/// comparison (which broke once `TerminalDelegateProxy` was introduced
/// in `#0125` and silently caused every focus call to no-op until
/// `#0132` re-resolution swapped to a tab-keyed lookup).
@MainActor
struct TerminalSurfaceFocuserTests {

    @Test func focusReturnsFalseWhenTabHasNoTerminalNSView() {
        let tab = TabRuntime()
        #expect(tab.terminalNSView == nil)
        #expect(TerminalSurfaceFocuser.focus(tab: tab) == false)
    }

    @Test func focusReturnsFalseWhenTerminalNSViewHasNoWindow() {
        let tab = TabRuntime()
        let view = AppTerminalView(frame: .zero)
        tab.terminalNSView = view
        #expect(view.window == nil)
        #expect(TerminalSurfaceFocuser.focus(tab: tab) == false)
    }

    @Test func focusReturnsFalseWhenViewIsHidden() {
        let tab = TabRuntime()
        let view = AppTerminalView(frame: .zero)
        view.isHidden = true
        tab.terminalNSView = view
        #expect(TerminalSurfaceFocuser.focus(tab: tab) == false)
    }
}
