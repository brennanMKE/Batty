// SessionMuteTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
final class SpyBellNotifier: BellNotifying {
    private(set) var postedEntries: [BellFeedEntry] = []

    func post(
        for entry: BellFeedEntry,
        sessionTitle: String,
        paneIndex: Int,
        tabLabel: String
    ) {
        postedEntries.append(entry)
    }
}

@MainActor
struct SessionMuteTests {

    @Test func mutedSessionSuppressesDesktopNotification() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        guard let session = store.sessions.first else {
            Issue.record("Expected a default session")
            return
        }
        session.notificationsMuted = true

        let tabID = session.focusedPane.activeTabID
        session.focusedPane.activeTab.terminal.terminalDidRequestDesktopNotification(
            title: "Build", body: "Succeeded"
        )
        store.recordDesktopNotification(forTabID: tabID)

        #expect(notifier.postedEntries.isEmpty)
    }

    @Test func unmutedSessionPostsDesktopNotification() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        guard let session = store.sessions.first else {
            Issue.record("Expected a default session")
            return
        }
        // Default mute state is false.
        #expect(session.notificationsMuted == false)

        // Select a different session so the bell-bearing tab is not focused.
        store.addSession(title: "Other")
        store.selectedSessionID = store.sessions.last?.id

        let tabID = session.focusedPane.activeTabID
        session.focusedPane.activeTab.terminal.terminalDidRequestDesktopNotification(
            title: "Build", body: "Succeeded"
        )
        store.recordDesktopNotification(forTabID: tabID)

        #expect(notifier.postedEntries.count == 1)
    }

    @Test func mutedSessionSuppressesBellTickNotification() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        guard let session = store.sessions.first else {
            Issue.record("Expected a default session")
            return
        }
        session.notificationsMuted = true

        // Select a different session so the bell-bearing tab is not focused.
        store.addSession(title: "Other")
        store.selectedSessionID = store.sessions.last?.id

        let tabID = session.focusedPane.activeTab.id
        session.focusedPane.activeTab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tabID)

        #expect(notifier.postedEntries.isEmpty)
        // Bell feed still records — mute is about delivery, not capture.
        #expect(store.bellFeed.entries.count == 1)
        #expect(session.unseenBellCount == 1)
    }
}
