// AppStateStoreNotifyTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `AppStateStore.recordCLINotification(tabID:title:body:playSound:)`
/// / `focusedTabIDFallback()` — #0284's XPC `notify` verb, the terminal step
/// of the agent loop. Distinct from `SessionMuteTests` (which exercises the
/// existing BEL/OSC-9 record sites): this covers the new CLI-originated
/// entry point and the attribution/mute/sound decisions #0284 pins.
@MainActor
struct AppStateStoreNotifyTests {

    // MARK: - Attribution: the headline property. A wrong-tab attribution
    // (e.g. always landing on the pane's active tab) must fail this test —
    // asserting only "some entry exists" or a count would pass identically
    // whether the entry landed on the targeted inactive tab or the active
    // one, so every id on the recorded entry is checked against the
    // *specific* non-active tab that was targeted.

    @Test func notifyingANonActiveTabAttributesTheEntryToThatExactTabNotTheActiveOne() throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        let originalTabID = pane.activeTabID
        // addTab() makes the new tab active, leaving originalTabID inactive
        // — the non-active tab this test deliberately targets.
        let newTab = pane.addTab()
        #expect(pane.activeTabID == newTab.id, "precondition: the new tab is now active")
        #expect(pane.activeTabID != originalTabID)

        let outcome = store.recordCLINotification(tabID: originalTabID, title: "Build finished", body: "0 errors", playSound: false)

        #expect(outcome == .posted)
        #expect(store.bellFeed.entries.count == 1)
        let entry = try #require(store.bellFeed.entries.first)
        #expect(entry.tabID == originalTabID, "must attribute to the targeted tab")
        #expect(entry.tabID != pane.activeTabID, "must not default to the pane's active tab")
        #expect(entry.paneID == pane.id)
        #expect(entry.sessionID == session.id)
        #expect(entry.windowID == store.windows[0].id.value)
        #expect(entry.surfaceID == originalTabID, "surfaceID should carry the real tab id, not a throwaway random UUID")
        #expect(entry.message == "Build finished\n0 errors")
    }

    @Test func notifyingAnUnknownTabIDReportsUnknownTabAndRecordsNoEntry() {
        let store = AppStateStore()
        let outcome = store.recordCLINotification(tabID: UUID(), title: "Done", body: nil, playSound: false)
        #expect(outcome == .unknownTab)
        #expect(store.bellFeed.entries.isEmpty)
    }

    // MARK: - Message formatting

    @Test func messageIsTitleAloneWhenNoBody() {
        let store = AppStateStore()
        let tabID = store.sessions[0].focusedPane.activeTabID
        store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: false)
        #expect(store.bellFeed.entries.first?.message == "Done")
    }

    @Test func messageIsTitleAndBodyWhenBodyGiven() {
        let store = AppStateStore()
        let tabID = store.sessions[0].focusedPane.activeTabID
        store.recordCLINotification(tabID: tabID, title: "Done", body: "All tests passed", playSound: false)
        #expect(store.bellFeed.entries.first?.message == "Done\nAll tests passed")
    }

    // MARK: - Seen-ness follows the same focus gate as bells/OSC 9

    @Test func notifyingTheFocusedTabRecordsAsSeenAndDoesNotBumpUnseenCounters() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let tabID = session.focusedPane.activeTabID

        store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: false)

        #expect(store.bellFeed.entries.first?.seen == true)
        #expect(session.unseenBellCount == 0)
    }

    @Test func notifyingANonFocusedSessionsTabRecordsAsUnseenAndBumpsCounters() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let tabID = session.focusedPane.activeTabID
        store.addSession(title: "Other")
        store.selectedSessionID = store.sessions.last?.id

        store.recordCLINotification(tabID: tabID, title: "Need input", body: nil, playSound: false)

        #expect(store.bellFeed.entries.first?.seen == false)
        #expect(session.unseenBellCount == 1)
    }

    // MARK: - focusedTabIDFallback (no --tab flag, no BATTY_TAB_ID env)

    @Test func focusedTabIDFallbackResolvesTheFocusedPanesActiveTab() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let expected = session.focusedPane.activeTabID
        #expect(store.focusedTabIDFallback() == expected)
    }

    @Test func focusedTabIDFallbackTracksAPaneSwitchToANewlyAddedTab() {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPane
        let newTab = pane.addTab()
        pane.activeTabID = newTab.id
        #expect(store.focusedTabIDFallback() == newTab.id)
    }

    // MARK: - Mute suppresses the banner, not the feed entry (per
    // docs/notifications.md's existing mute contract — notify inherits it)

    @Test func mutedSessionSuppressesTheNotifierPostButStillRecordsTheFeedEntry() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        let session = store.sessions[0]
        session.notificationsMuted = true
        let tabID = session.focusedPane.activeTabID

        let outcome = store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: true)

        #expect(outcome == .posted)
        #expect(store.bellFeed.entries.count == 1)
        #expect(notifier.postedEntries.isEmpty, "mute suppresses only the desktop-notification banner")
    }

    @Test func unmutedSessionPostsThroughTheNotifier() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        let session = store.sessions[0]
        #expect(session.notificationsMuted == false)
        let tabID = session.focusedPane.activeTabID

        store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: true)

        #expect(notifier.postedEntries.count == 1)
    }

    // MARK: - --sound is a per-call gate forwarded to the notifier, never
    // forced past the app-wide toggle (`BellNotifier.post` itself is what
    // consults the toggle; this only checks the flag is plumbed through)

    @Test func soundFlagTrueIsForwardedToTheNotifier() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        let tabID = store.sessions[0].focusedPane.activeTabID

        store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: true)

        #expect(notifier.postedPlaySoundFlags == [true])
    }

    @Test func soundFlagFalseIsForwardedToTheNotifier() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        let tabID = store.sessions[0].focusedPane.activeTabID

        store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: false)

        #expect(notifier.postedPlaySoundFlags == [false])
    }

    // MARK: - Background-session notify must not steal focus or switch the
    // active session (#0257's rule for every mutating verb, same discipline
    // as #0282/#0283)

    @Test func notifyingATabInABackgroundSessionDoesNotChangeSelectionOrForegroundFocus() {
        let store = AppStateStore()
        let selected = store.sessions[0]
        let background = store.addSession(title: "Background")!
        store.windows[0].selectedSessionID = selected.id
        let selectedFocusedPaneBefore = selected.tree.focusedPaneID
        let selectedSessionIDBefore = store.windows[0].selectedSessionID
        let backgroundTabID = background.focusedPane.activeTabID

        let outcome = store.recordCLINotification(tabID: backgroundTabID, title: "Done", body: nil, playSound: false)

        #expect(outcome == .posted)
        #expect(store.windows[0].selectedSessionID == selectedSessionIDBefore)
        #expect(selected.tree.focusedPaneID == selectedFocusedPaneBefore)
        #expect(store.bellFeed.entries.first?.sessionID == background.id)
    }

    // MARK: - Cross-window resolution (same discipline as
    // `AppStateStoreClosePaneTests.closePaneResolvesAPaneInANonKeyWindow`)

    @Test func notifyResolvesATabInANonKeyWindow() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())
        let target = w2.sessions[0].focusedPane.activeTabID

        let outcome = store.recordCLINotification(tabID: target, title: "Done", body: nil, playSound: false)

        #expect(outcome == .posted)
        #expect(store.bellFeed.entries.first?.windowID == w2.id.value)
    }

    // MARK: - Flood guard: relies on BellFeedStore's existing 200-entry cap
    // (per #0284's resolution — no coalescing added). A tight notify loop
    // still evicts oldest-first rather than growing unbounded.

    @Test func repeatedNotifyCallsRespectTheExistingFeedCap() {
        let store = AppStateStore()
        let tabID = store.sessions[0].focusedPane.activeTabID
        for i in 0..<(BellFeedStore.cap + 5) {
            store.recordCLINotification(tabID: tabID, title: "Tick \(i)", body: nil, playSound: false)
        }
        #expect(store.bellFeed.entries.count == BellFeedStore.cap)
    }
}
