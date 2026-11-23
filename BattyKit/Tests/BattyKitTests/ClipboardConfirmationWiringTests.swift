// ClipboardConfirmationWiringTests.swift

import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

/// A clipboard request that reaches a Tab before `PaneView` wires its route
/// is held, then routed through the production closure once
/// `AppStateStore.wireClipboardConfirmation(for:)` runs (#0720).
@MainActor
@Suite(.serialized)
final class ClipboardConfirmationWiringTests {
    private let testDefaults = TestDefaults()

    @MainActor deinit { testDefaults.tearDown() }

    private func makeSessionAndTab() -> (AppStateStore, SessionRuntime, TabRuntime) {
        let store = AppStateStore(preferences: testDefaults.defaults)
        let session = store.addSession(title: "Clipboard")!
        let tab = session.focusedPaneAnyKind.activeTab!
        #expect(tab.sessionID == session.id, "precondition: the Tab knows its Session")
        return (store, session, tab)
    }

    private func isOSC52Read(_ kind: TerminalClipboardRequestKind?) -> Bool {
        if case .osc52Read = kind { return true }
        return false
    }

    @Test func earlyReadWithAskShowsTheDialogOnceWired() {
        testDefaults.defaults.set("ask", forKey: SettingsPreference.clipboardReadKey)
        let (store, session, tab) = makeSessionAndTab()
        var decisions: [Bool] = []

        tab.terminalDelegate.resolveClipboardConfirmationRoute(kind: .osc52Read) { decisions.append($0) }

        #expect(session.pendingClipboardConfirmation == nil)
        #expect(decisions.isEmpty)

        store.wireClipboardConfirmation(for: tab)

        let pending = session.pendingClipboardConfirmation
        #expect(isOSC52Read(pending?.kind))
        #expect(decisions.isEmpty)

        if let pending {
            session.answerPendingClipboardConfirmation(pending, allow: false)
        }
        #expect(decisions == [false])
    }

    @Test func earlyReadWithDefaultNeverDeniesOnceWiredWithoutADialog() {
        let (store, session, tab) = makeSessionAndTab()
        var decisions: [Bool] = []
        tab.terminalDelegate.resolveClipboardConfirmationRoute(kind: .osc52Read) { decisions.append($0) }
        #expect(decisions.isEmpty)

        store.wireClipboardConfirmation(for: tab)

        #expect(decisions == [false])
        #expect(session.pendingClipboardConfirmation == nil)
    }

    @Test func earlyBurstWithAskShowsOneDialogAndCoalescesTheRest() {
        testDefaults.defaults.set("ask", forKey: SettingsPreference.clipboardReadKey)
        let (store, session, tab) = makeSessionAndTab()
        var decisions: [Bool] = []
        for _ in 0..<3 {
            tab.terminalDelegate.resolveClipboardConfirmationRoute(kind: .osc52Read) { decisions.append($0) }
        }

        store.wireClipboardConfirmation(for: tab)

        #expect(session.pendingClipboardConfirmation != nil)
        #expect(decisions == [false, false])
    }

    @Test func releasingTheTerminalViewDeniesHeldRequests() {
        let (store, _, tab) = makeSessionAndTab()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        let windowID = store.windows[0].id
        window.contentView = TerminalHostStore.shared.hostView(forWindowID: windowID)
        TerminalHostStore.shared.terminalView(for: tab, windowID: windowID)

        var decisions: [Bool] = []
        tab.terminalDelegate.resolveClipboardConfirmationRoute(kind: .osc52Read) { decisions.append($0) }
        #expect(decisions.isEmpty)

        TerminalHostStore.shared.releaseTerminalView(forTabID: tab.id)

        #expect(decisions == [false])
        window.contentView = nil
    }
}
