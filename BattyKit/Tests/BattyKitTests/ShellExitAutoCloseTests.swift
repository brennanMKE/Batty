// ShellExitAutoCloseTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct ShellExitAutoCloseTests {

    /// Mirrors the wiring `PaneView` installs on each tab's
    /// `TerminalViewState.onClose`: route the close through
    /// `AppStateStore.closeTab(id:)` so the existing pane/session
    /// cascade runs.
    private func wireAutoClose(tab: TabRuntime, store: AppStateStore) {
        tab.terminal.onClose = { [weak store] _ in
            store?.closeTab(id: tab.id)
        }
    }

    @Test func shellExitClosesNonLastTab() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        pane.addTab()
        let firstTab = pane.tabs[0]
        let firstID = firstTab.id
        wireAutoClose(tab: firstTab, store: store)
        wireAutoClose(tab: pane.tabs[1], store: store)

        firstTab.terminal.onClose?(false)

        #expect(pane.tabs.count == 1)
        #expect(!pane.tabs.contains(where: { $0.id == firstID }))
        #expect(store.sessions.count == 1)
    }

    @Test func shellExitClosesLastTabAndEmptiesTheStore() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        wireAutoClose(tab: tab, store: store)

        nonisolated(unsafe) var posted = false
        let observer = NotificationCenter.default.addObserver(
            forName: .battyAllSessionsClosed,
            object: nil,
            queue: nil
        ) { _ in
            posted = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        tab.terminal.onClose?(false)

        #expect(store.sessions.isEmpty)
        #expect(posted)
    }

    @Test func shellExitIgnoresProcessAliveFlag() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        pane.addTab()
        let firstTab = pane.tabs[0]
        let firstID = firstTab.id
        wireAutoClose(tab: firstTab, store: store)

        firstTab.terminal.onClose?(true)

        #expect(!pane.tabs.contains(where: { $0.id == firstID }))
    }

    @Test func shellExitFiredTwiceIsSafeIdempotent() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        pane.addTab()
        let firstTab = pane.tabs[0]
        wireAutoClose(tab: firstTab, store: store)

        let close = firstTab.terminal.onClose
        close?(false)
        close?(false)

        #expect(pane.tabs.count == 1)
        #expect(store.sessions.count == 1)
    }
}
