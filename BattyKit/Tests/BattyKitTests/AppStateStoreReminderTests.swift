// AppStateStoreReminderTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
final class SpyReminderNotifier: BellNotifying {
    struct Posted: Equatable {
        let entry: BellFeedEntry
        let sessionTitle: String
    }

    private(set) var reminders: [Posted] = []
    private(set) var bells: [BellFeedEntry] = []

    func post(for entry: BellFeedEntry, sessionTitle: String, paneIndex: Int, tabLabel: String, playSound: Bool) {
        bells.append(entry)
    }

    func postReminder(entry: BellFeedEntry, sessionTitle: String) {
        reminders.append(Posted(entry: entry, sessionTitle: sessionTitle))
    }
}

/// Fire path, jump, seen-ness and close behavior of Session Reminders against
/// a real `AppStateStore`, with a `TestClock` standing in for time. The store's
/// own `onFire` is wrapped so each firing is an event the test awaits.
@MainActor
final class AppStateStoreReminderTests {
    private let testDefaults = TestDefaults()
    private let clock = TestClock(now: ReminderFixture.anchor)
    private let notifier = SpyReminderNotifier()
    private let recorder = FiringRecorder()
    private let store: AppStateStore

    init() {
        store = AppStateStore(
            notifier: notifier,
            preferences: testDefaults.defaults,
            reminderClock: clock,
            reminderCalendar: { ReminderFixture.calendar() }
        )
        store.isBattyActiveProvider = { false }
        let original = store.reminderScheduler.onFire
        store.reminderScheduler.onFire = { [recorder] firing in
            original(firing)
            recorder.record(firing)
        }
    }

    @MainActor deinit { testDefaults.tearDown() }

    /// Sets a Reminder and drives the clock to its due time.
    @discardableResult
    private func fire(
        _ minutes: Int,
        note: String? = nil,
        on sessionID: UUID
    ) async throws -> ReminderFiring {
        _ = try #require(store.setReminder(.after(minutes: minutes), note: note, forSessionID: sessionID))
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: .seconds(minutes * 60))
        return try #require(await recorder.next())
    }

    /// A Session whose focus is not the default one: a second Pane, focused,
    /// holding a second Tab, active.
    private func sessionWithNonDefaultFocus(title: String) -> (session: SessionRuntime, firstPane: PaneRuntime, secondPane: PaneRuntime, secondTab: TabRuntime) {
        let session = store.addSession(title: title)!
        let firstPane = session.focusedPaneAnyKind
        let secondPane = session.tree.splitFocusedPane(direction: .horizontal, inheritingFrom: firstPane)
        let secondTab = secondPane.addTab()
        session.tree.focusedPaneID = secondPane.id
        return (session, firstPane, secondPane, secondTab)
    }

    // MARK: - Setting

    @Test func settingAReminderRecordsNoEntryAndPostsNothing() throws {
        let session = store.sessions[0]
        let made = try #require(store.setReminder(.after(minutes: 15), note: " call back ", forSessionID: session.id))

        #expect(session.reminder == made)
        #expect(made.note == "call back")
        #expect(store.bellFeed.entries.isEmpty)
        #expect(notifier.reminders.isEmpty)
        #expect(store.pendingReminderCount == 1)
    }

    @Test func anOutOfBoundsRequestSetsNothing() {
        let session = store.sessions[0]
        #expect(store.setReminder(.after(minutes: 0), forSessionID: session.id) == nil)
        #expect(session.reminder == nil)
        #expect(store.reminderScheduler.pendingCount == 0)
    }

    @Test func aSecondReminderReplacesTheFirstOnTheSession() throws {
        let session = store.sessions[0]
        _ = try #require(store.setReminder(.after(minutes: 10), note: "one", forSessionID: session.id))
        let second = try #require(store.setReminder(.after(minutes: 20), note: "two", forSessionID: session.id))
        #expect(session.reminder == second)
        #expect(store.reminderScheduler.pendingCount == 1)
        #expect(store.pendingReminderCount == 1)
    }

    @Test func cancellingClearsTheSessionAndTheScheduler() async throws {
        let session = store.sessions[0]
        _ = try #require(store.setReminder(.after(minutes: 10), forSessionID: session.id))
        #expect(await clock.waitForSleepers(1))
        store.cancelReminder(forSessionID: session.id)
        #expect(session.reminder == nil)
        #expect(clock.pendingCount == 0)
        #expect(store.pendingReminderCount == 0)
    }

    // MARK: - Fire effects

    @Test func firingRecordsOneUnseenReminderEntryAndPostsTheNote() async throws {
        let target = store.addSession(title: "api-server")!
        store.selectedSessionID = store.sessions[0].id
        target.unseenBellCount = 2

        let firing = try await fire(15, note: "check the deploy", on: target.id)

        #expect(target.reminder == nil)
        #expect(store.bellFeed.entries.count == 1)
        let entry = try #require(store.bellFeed.entries.first)
        #expect(entry.kind == .reminder)
        #expect(entry.seen == false)
        #expect(entry.sessionID == target.id)
        #expect(entry.windowID == store.windows[0].id.value)
        #expect(entry.message == "check the deploy")
        #expect(entry.reminderSetAt == ReminderFixture.anchor)
        #expect(entry.reminderDueAt == firing.dueDate)
        #expect(store.bellFeed.unseenCount == 1)
        #expect(target.unseenBellCount == 2, "a Reminder is not a bell and leaves the bell counter alone")
        #expect(notifier.reminders == [.init(entry: entry, sessionTitle: "api-server")])
        #expect(notifier.bells.isEmpty)
    }

    @Test func theEntryNamesTheFocusedPaneAndActiveTabAtFireTime() async throws {
        let fixture = sessionWithNonDefaultFocus(title: "build")
        store.selectedSessionID = store.sessions[0].id
        try await fire(5, on: fixture.session.id)

        let entry = try #require(store.bellFeed.entries.first)
        #expect(entry.paneID == fixture.secondPane.id)
        #expect(entry.tabID == fixture.secondTab.id)
        #expect(entry.paneID != fixture.firstPane.id)
    }

    @Test func aMutedSessionStillPostsItsReminder() async throws {
        let target = store.addSession(title: "quiet")!
        target.notificationsMuted = true
        try await fire(5, on: target.id)
        #expect(notifier.reminders.count == 1)
        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.kind == .reminder)
        #expect(store.bellFeed.entries.first?.seen == false)

        store.recordCLINotification(tabID: target.focusedPaneAnyKind.activeTabID, title: "Done", body: nil, playSound: false)
        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.kind == .reminder)
    }

    @Test func aReminderOnTheFrontmostSessionIsStillUnseenAndPosted() async throws {
        let frontmost = store.sessions[0]
        #expect(store.selectedSessionID == frontmost.id)
        try await fire(5, note: "now", on: frontmost.id)

        #expect(store.bellFeed.entries.first?.seen == false)
        #expect(notifier.reminders.count == 1)
    }

    @Test func reminderFiredOnTheSelectedSessionWhileActiveStillAddsAnEntry() async throws {
        store.isBattyActiveProvider = { true }
        let selected = store.sessions[0]
        #expect(store.selectedSessionID == selected.id)
        try await fire(5, note: "now", on: selected.id)

        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.kind == .reminder)
        #expect(store.bellFeed.entries.first?.seen == false)
    }

    @Test func turningSystemNotificationsOffSuppressesThePostButNotTheEntry() async throws {
        testDefaults.defaults.set(false, forKey: SettingsPreference.systemNotificationsKey)
        let target = store.addSession(title: "silent")!
        try await fire(5, on: target.id)

        #expect(store.bellFeed.entries.count == 1)
        #expect(notifier.reminders.isEmpty)
    }

    @Test func twoReminderFiringsOnOneSessionStaySeparateEntries() async throws {
        let target = store.addSession(title: "twice")!
        try await fire(5, note: "same words", on: target.id)
        try await fire(5, note: "same words", on: target.id)
        #expect(store.bellFeed.entries.count == 2)
        #expect(store.bellFeed.entries.allSatisfy { $0.kind == .reminder && $0.repeatCount == 1 })
    }

    @Test func aFiringForASessionThatIsGoneRecordsNothing() {
        store.fireReminder(ReminderFiring(
            sessionID: UUID(),
            reminder: SessionReminder(createdAt: ReminderFixture.anchor, target: .instant(ReminderFixture.anchor)),
            dueDate: ReminderFixture.anchor))
        #expect(store.bellFeed.entries.isEmpty)
        #expect(notifier.reminders.isEmpty)
    }

    // MARK: - Jump

    @Test func jumpingSelectsTheSessionAndLeavesFocusExactlyWhereItWas() async throws {
        let fixture = sessionWithNonDefaultFocus(title: "build")
        store.selectedSessionID = store.sessions[0].id
        try await fire(5, note: "back to it", on: fixture.session.id)
        let entry = try #require(store.bellFeed.entries.first)

        // The user moves focus after the Reminder fired.
        fixture.session.tree.focusedPaneID = fixture.firstPane.id
        let firstTabID = fixture.firstPane.activeTabID
        #expect(fixture.firstPane.activeTabID != entry.tabID)

        store.jumpToBellEntry(entry)

        #expect(store.selectedSessionID == fixture.session.id)
        #expect(fixture.session.tree.focusedPaneID == fixture.firstPane.id, "the jump must not move to the Pane recorded at fire time")
        #expect(fixture.firstPane.activeTabID == firstTabID)
        #expect(fixture.secondPane.activeTabID == fixture.secondTab.id)
        #expect(store.bellFeed.entries.isEmpty, "the jump is a visit, which removes the Reminder row")
    }

    @Test func jumpingToAReminderOnTheAlreadySelectedSessionRemovesIt() async throws {
        let target = store.addSession(title: "selected")!
        try await fire(5, on: target.id)
        #expect(store.selectedSessionID == target.id, "precondition: no selection change will happen")
        let entry = try #require(store.bellFeed.entries.first)
        #expect(entry.seen == false)

        store.jumpToBellEntry(entry)

        #expect(store.bellFeed.entries.isEmpty)
        #expect(store.bellFeed.unseenReminderEntries(forSessionID: target.id).isEmpty)
    }

    @Test func jumpingToAReminderWhoseWindowIsGoneJustMarksItSeen() async throws {
        let target = store.addSession(title: "orphan")!
        try await fire(5, on: target.id)
        var entry = try #require(store.bellFeed.entries.first)
        entry.windowID = UUID()
        store.bellFeed.entries[0] = entry
        store.jumpToBellEntry(entry)
        #expect(store.bellFeed.entries.first?.seen == true)
    }

    // MARK: - Seen

    @Test func selectingTheSessionMarksItsReminderEntriesSeenWhateverTabTheyNamed() async throws {
        let fixture = sessionWithNonDefaultFocus(title: "later")
        let other = store.addSession(title: "other")!
        store.selectedSessionID = store.sessions[0].id
        try await fire(5, on: fixture.session.id)
        try await fire(5, on: other.id)
        #expect(store.bellFeed.unseenCount == 2)

        // The entry names the second Pane's Tab; focus goes back to the first
        // Pane before the Session is selected, so the tab-keyed mark-seen
        // path cannot be what clears it.
        let entryTabID = try #require(store.bellFeed.entries.first { $0.sessionID == fixture.session.id }).tabID
        fixture.session.tree.focusedPaneID = fixture.firstPane.id
        #expect(fixture.firstPane.activeTabID != entryTabID)

        store.windows[0].selectedSessionID = fixture.session.id
        store.windows[0].markActiveTabSeen()

        let byID = Dictionary(uniqueKeysWithValues: store.bellFeed.entries.map { ($0.sessionID, $0.seen) })
        #expect(byID[fixture.session.id] == true)
        #expect(byID[other.id] == false, "only the selected Session's Reminder is acknowledged")
    }

    @Test func clearAllMarksReminderEntriesSeenWithoutTouchingBellCounters() async throws {
        let target = store.addSession(title: "counted")!
        target.unseenBellCount = 3
        try await fire(5, on: target.id)

        store.markAllBellsSeen()

        #expect(store.bellFeed.unseenCount == 0)
        #expect(target.unseenBellCount == 3)
    }

    // MARK: - Closing the Session

    @Test func closingTheSessionCancelsItsPendingReminderSilently() async throws {
        let doomed = store.addSession(title: "doomed")!
        let survivor = store.addSession(title: "survivor")!
        _ = try #require(store.setReminder(.after(minutes: 10), forSessionID: doomed.id))
        _ = try #require(store.setReminder(.after(minutes: 20), note: "still here", forSessionID: survivor.id))
        #expect(await clock.waitForSleepers(1))

        store.removeSession(id: doomed.id)

        #expect(store.reminderScheduler.pendingCount == 1)
        #expect(store.pendingReminderCount == 1)
        #expect(store.bellFeed.entries.isEmpty)
        #expect(notifier.reminders.isEmpty)

        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: .seconds(20 * 60))
        let firing = try #require(await recorder.next())
        #expect(firing.sessionID == survivor.id)
    }

    @Test func closingTheSessionPurgesItsReminderEntriesBySessionNotOnlyByTab() async throws {
        let doomed = store.addSession(title: "closing")!
        let keeper = store.addSession(title: "keeper")!
        try await fire(5, note: "theirs", on: keeper.id)
        // An entry whose recorded Tab no longer resolves to one of the
        // Session's Tabs: the tab-keyed purge alone would leave it behind.
        store.bellFeed.record(BellFeedEntry(
            timestamp: ReminderFixture.anchor,
            windowID: store.windows[0].id.value,
            sessionID: doomed.id,
            paneID: UUID(),
            tabID: UUID(),
            surfaceID: UUID(),
            message: "mine",
            seen: false,
            kind: .reminder))

        store.removeSession(id: doomed.id)

        #expect(store.bellFeed.entries.map(\.message) == ["theirs"])
    }

    @Test func closingAWindowCancelsPendingRemindersAndPurgesFiredEntriesOfItsSessions() async throws {
        let extra = store.openWindowRuntime(for: WindowID())
        let fired = extra.addSession(title: "fired")
        let pending = extra.addSession(title: "pending")
        try await fire(5, note: "gone with the window", on: fired.id)
        _ = try #require(store.setReminder(.after(minutes: 10), forSessionID: pending.id))
        #expect(await clock.waitForSleepers(1))
        #expect(store.bellFeed.entries.count == 1)

        store.removeWindow(id: extra.id)

        #expect(store.reminderScheduler.pendingCount == 0)
        #expect(clock.pendingCount == 0)
        #expect(store.bellFeed.entries.isEmpty, "a closed Window's fired Reminder entries must not linger")
    }

    @Test func closingTheRecordedTabLeavesAFiredReminderEntryUnseen() async throws {
        let fixture = sessionWithNonDefaultFocus(title: "two tabs")
        store.selectedSessionID = store.sessions[0].id
        try await fire(5, note: "still due", on: fixture.session.id)
        let entry = try #require(store.bellFeed.entries.first)
        #expect(entry.tabID == fixture.secondTab.id)

        store.windows[0].closeTab(id: fixture.secondTab.id)

        #expect(store.bellFeed.entries.map(\.id) == [entry.id])
        #expect(store.bellFeed.entries.first?.seen == false)
        #expect(!store.bellFeed.unseenReminderEntries(forSessionID: fixture.session.id).isEmpty)
    }

    @Test func editingOnlyTheNoteOfATomorrowReminderKeepsItsResolvedDate() async throws {
        let session = store.sessions[0]
        let original = try #require(store.setReminder(ReminderTime.defaultTomorrow.tomorrowSpec, note: "a", forSessionID: session.id))
        #expect(await clock.waitForSleepers(1))
        // 01:00 the next day: "tomorrow" would now mean a day later.
        await clock.advance(by: .seconds(10 * 3600))
        let edited = try #require(store.editReminder(ReminderTime.defaultTomorrow.tomorrowSpec, note: "b", forSessionID: session.id))
        #expect(edited.target == original.target)
        #expect(edited.id == original.id)
        #expect(edited.note == "b")
        #expect(session.reminder == edited)
    }

    @Test func aSessionCloseConfirmationMentionsItsPendingReminder() throws {
        let busy = store.addSession(title: "busy")!
        _ = try #require(store.setReminder(.after(minutes: 10), forSessionID: busy.id))
        busy.focusedPaneAnyKind.activeTab?.needsConfirmCloseOverride = true

        store.windows[0].requestRemoveSession(id: busy.id)

        let message = try #require(store.windows[0].pendingCloseRequest?.message)
        #expect(message.contains("reminder"))
    }
    // MARK: - Remembered Tomorrow time

    private func seededStore(_ time: ReminderTime, defaults: TestDefaults) -> AppStateStore {
        SettingsPreference.storeReminderTomorrowTime(time, defaults: defaults.defaults)
        return AppStateStore(
            preferences: defaults.defaults,
            reminderClock: TestClock(now: ReminderFixture.anchor),
            reminderCalendar: { ReminderFixture.calendar() })
    }

    private func storedMinutes(_ store: AppStateStore) -> Int? {
        store.preferences.object(forKey: SettingsPreference.reminderTomorrowTimeKey) as? Int
    }

    @Test func aFreshStoreOffersTomorrowAtNine() {
        #expect(store.tomorrowReminderTime == .defaultTomorrow)
        #expect(store.tomorrowReminderSpec == .tomorrow(hour: 9, minute: 0))
    }

    @Test func aStoreSeedsTheRememberedTomorrowTimeFromPreferences() {
        let seeded = seededStore(ReminderTime(hour: 7, minute: 15), defaults: TestDefaults())
        #expect(seeded.tomorrowReminderTime == ReminderTime(hour: 7, minute: 15))
        #expect(seeded.tomorrowReminderSpec == .tomorrow(hour: 7, minute: 15))
    }

    @Test func settingATomorrowReminderFromTheSheetRemembersItsTime() throws {
        let session = store.sessions[0]
        try #require(store.commitReminderSheet(.tomorrow(hour: 8, minute: 30), note: nil, forSessionID: session.id))
        #expect(store.tomorrowReminderTime == ReminderTime(hour: 8, minute: 30))
        #expect(storedMinutes(store) == 510)
    }

    @Test func presetAndCustomDurationRemindersDoNotChangeTheRememberedTime() throws {
        let seeded = seededStore(ReminderTime(hour: 7, minute: 15), defaults: TestDefaults())
        let session = seeded.sessions[0]
        try #require(seeded.setReminder(.after(minutes: 15), forSessionID: session.id))
        try #require(seeded.commitReminderSheet(.after(minutes: 95), note: nil, forSessionID: session.id))
        try #require(seeded.setReminder(.tomorrow(hour: 10, minute: 0), forSessionID: session.id))
        #expect(seeded.tomorrowReminderTime == ReminderTime(hour: 7, minute: 15))
        #expect(storedMinutes(seeded) == 435)
    }

    @Test func anOutOfBoundsSheetCommitRemembersNothing() {
        let seeded = seededStore(ReminderTime(hour: 7, minute: 15), defaults: TestDefaults())
        #expect(seeded.commitReminderSheet(.tomorrow(hour: 24, minute: 0), note: nil, forSessionID: seeded.sessions[0].id) == nil)
        #expect(seeded.tomorrowReminderTime == ReminderTime(hour: 7, minute: 15))
        #expect(storedMinutes(seeded) == 435)
    }

    @Test func oneClickTomorrowUsesTheRememberedTime() throws {
        let seeded = seededStore(ReminderTime(hour: 7, minute: 15), defaults: TestDefaults())
        let session = seeded.sessions[0]
        ReminderActions.set(seeded.tomorrowReminderSpec, on: session, store: seeded)
        let reminder = try #require(session.reminder)
        #expect(reminder.target == .wallClock(DateComponents(year: 2026, month: 10, day: 15, hour: 7, minute: 15)))
    }
}
