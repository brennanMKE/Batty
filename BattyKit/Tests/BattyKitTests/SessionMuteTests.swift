// SessionMuteTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
final class SpyBellNotifier: BellNotifying {
    private(set) var postedEntries: [BellFeedEntry] = []
    private(set) var postedPlaySoundFlags: [Bool] = []

    func post(
        for entry: BellFeedEntry,
        sessionTitle: String,
        paneIndex: Int,
        tabLabel: String,
        playSound: Bool
    ) {
        postedEntries.append(entry)
        postedPlaySoundFlags.append(playSound)
    }
}

@MainActor
struct SessionMuteTests {

    @Test func mutedSessionDesktopNotificationAddsNoEntryAndNoBanner() async {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        store.isBattyActiveProvider = { false }
        guard let session = store.sessions.first else {
            Issue.record("Expected a default session")
            return
        }
        session.notificationsMuted = true

        let tab = session.focusedPaneAnyKind.activeTab!
        store.requestDesktopNotification(in: tab, title: "Build", body: "Succeeded")

        #expect(store.bellFeed.entries.isEmpty)
        #expect(notifier.postedEntries.isEmpty)
    }

    @Test func unmutedSessionPostsDesktopNotification() async {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        store.isBattyActiveProvider = { false }
        guard let session = store.sessions.first else {
            Issue.record("Expected a default session")
            return
        }
        // Default mute state is false.
        #expect(session.notificationsMuted == false)

        // Select a different session so the bell-bearing tab is not focused.
        store.addSession(title: "Other")
        store.selectedSessionID = store.sessions.last?.id

        let tab = session.focusedPaneAnyKind.activeTab!
        store.requestDesktopNotification(in: tab, title: "Build", body: "Succeeded")

        #expect(notifier.postedEntries.count == 1)
    }

    @Test func mutedSessionBellTickAddsNoEntryAndNoUnseenCount() async {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        store.isBattyActiveProvider = { false }
        guard let session = store.sessions.first else {
            Issue.record("Expected a default session")
            return
        }
        session.notificationsMuted = true

        // Select a different session so the bell-bearing tab is not focused.
        store.addSession(title: "Other")
        store.selectedSessionID = store.sessions.last?.id

        guard let tab = session.focusedPaneAnyKind.activeTab else {
            Issue.record("Expected an active tab")
            return
        }
        store.ringBell(in: tab)

        #expect(store.bellFeed.entries.isEmpty)
        #expect(notifier.postedEntries.isEmpty)
        #expect(session.unseenBellCount == 0)
        #expect(session.focusedPaneAnyKind.unseenBellCount == 0)
        #expect(tab.unseenBellCount == 0)
        #expect(tab.bellCount == 1)
    }
}
