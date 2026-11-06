// BellIntakeTests.swift

import Foundation
import Testing
@testable import BattyKit

/// BEL and OSC 9/777 reach the Bell Feed from the libghostty delegate
/// callback itself, with no view re-render in between (#0561).
@MainActor
final class BellIntakeTests {
    private let testDefaults = TestDefaults()

    @MainActor deinit { testDefaults.tearDown() }

    private func makeStore() -> AppStateStore {
        let store = AppStateStore(preferences: testDefaults.defaults)
        store.isBattyActiveProvider = { true }
        return store
    }

    /// Splits the selected Session; the original Pane is left unfocused.
    private func unfocusedTab(_ store: AppStateStore) -> (SessionRuntime, PaneRuntime, TabRuntime) {
        let session = store.sessions[0]
        store.selectedSessionID = session.id
        let original = session.tree.allPanes[0]
        session.tree.splitFocusedPane(direction: .horizontal)
        #expect(session.tree.focusedPaneID != original.id, "precondition: the bell Pane is unfocused")
        return (session, original, original.tabs[0])
    }

    @Test func belFromAnUnfocusedTabThroughTheDelegateAddsAnUnseenEntry() {
        let store = makeStore()
        let (session, pane, tab) = unfocusedTab(store)
        store.wireBellReporting(for: tab)

        tab.terminalDelegate.terminalDidRingBell()

        #expect(store.bellFeed.entries.count == 1)
        let entry = store.bellFeed.entries.first
        #expect(entry?.seen == false)
        #expect(entry?.tabID == tab.id)
        #expect(entry?.paneID == pane.id)
        #expect(entry?.sessionID == session.id)
        #expect(entry?.timestamp == tab.lastBellAt)
        #expect(tab.bellCount == 1)
        #expect(tab.unseenBellCount == 1)
        #expect(pane.unseenBellCount == 1)
        #expect(session.unseenBellCount == 1)
    }

    @Test func belIsRoutedBeforeTheTerminalStatePublishLands() async {
        let store = makeStore()
        let (_, _, tab) = unfocusedTab(store)
        store.wireBellReporting(for: tab)

        tab.terminalDelegate.terminalDidRingBell()

        #expect(tab.terminal.bellCount == 0, "precondition: libghostty-spm's publish is still pending")
        #expect(store.bellFeed.entries.count == 1)

        await awaitTerminalStatePublish { tab.terminal.bellCount == 1 }
        #expect(store.bellFeed.entries.count == 1)
        #expect(tab.bellCount == 1)
    }

    @Test func oscFromAnUnfocusedTabThroughTheDelegateAddsAnEntryWithItsMessage() {
        let store = makeStore()
        let (session, pane, tab) = unfocusedTab(store)
        store.wireBellReporting(for: tab)

        tab.terminalDelegate.terminalDidRequestDesktopNotification(title: "Build", body: "Succeeded")

        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.message == "Build: Succeeded")
        #expect(store.bellFeed.entries.first?.seen == false)
        #expect(tab.unseenBellCount == 1)
        #expect(pane.unseenBellCount == 1)
        #expect(session.unseenBellCount == 1)
    }

    @Test func twoDifferentOSCNotificationsEachAddAnEntry() {
        let store = makeStore()
        let (_, _, tab) = unfocusedTab(store)
        store.wireBellReporting(for: tab)

        tab.terminalDelegate.terminalDidRequestDesktopNotification(title: "CI", body: "one")
        tab.terminalDelegate.terminalDidRequestDesktopNotification(title: "CI", body: "two")

        #expect(store.bellFeed.entries.count == 2)
        #expect(tab.bellCount == 2)
    }

    @Test func focusedTabBelThroughTheDelegateWhileActiveAddsNoEntryButCounts() {
        let store = makeStore()
        let session = store.sessions[0]
        store.selectedSessionID = session.id
        let tab = session.focusedPaneAnyKind.activeTab!
        store.wireBellReporting(for: tab)

        tab.terminalDelegate.terminalDidRingBell()

        #expect(store.bellFeed.entries.isEmpty)
        #expect(tab.bellCount == 1)
        #expect(store.bellDecisionHistory.records.count == 1)
    }

    @Test func bellsRungBeforeWiringAreRoutedWhenWired() {
        let store = makeStore()
        let (_, _, tab) = unfocusedTab(store)

        for _ in 0..<3 { tab.terminalDelegate.terminalDidRingBell() }
        #expect(tab.bellCount == 3)
        #expect(store.bellFeed.entries.isEmpty)

        store.wireBellReporting(for: tab)

        #expect(store.bellDecisionHistory.records.count == 3)
        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.repeatCount == 3)
    }

    @Test func wiringTwiceDoesNotDoubleCount() {
        let store = makeStore()
        let (_, _, tab) = unfocusedTab(store)
        store.wireBellReporting(for: tab)
        store.wireBellReporting(for: tab)

        tab.terminalDelegate.terminalDidRingBell()

        #expect(store.bellFeed.entries.count == 1)
        #expect(tab.bellCount == 1)
    }

    @Test func bellFromATabNoWindowLocatesCountsButAddsNoEntry() {
        let store = makeStore()
        let stray = TabRuntime()
        store.wireBellReporting(for: stray)

        stray.terminalDelegate.terminalDidRingBell()

        #expect(stray.bellCount == 1)
        #expect(store.bellFeed.entries.isEmpty)
    }
}
