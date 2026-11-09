// AppStateStoreRemindSessionForXPCTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

/// `remindSessionForXPC` and the topology `reminder` field against a
/// throwaway store, with a `TestClock` and the fixture calendar. The
/// remembered Tomorrow time is seeded to a non-default 8:30.
@MainActor
final class AppStateStoreRemindSessionForXPCTests {
    private let testDefaults = TestDefaults()
    private let clock = TestClock(now: ReminderFixture.anchor)
    private let store: AppStateStore

    private static let remembered = ReminderTime(hour: 8, minute: 30)

    init() {
        SettingsPreference.storeReminderTomorrowTime(Self.remembered, defaults: testDefaults.defaults)
        store = AppStateStore(
            preferences: testDefaults.defaults,
            reminderClock: clock,
            reminderCalendar: { ReminderFixture.calendar() }
        )
    }

    @MainActor deinit { testDefaults.tearDown() }

    private func remind(_ sessionID: UUID?, _ action: SessionRemindAction, note: String? = nil) -> AppStateStore.SessionRemindOutcome {
        store.remindSessionForXPC(SessionRemindRequest(sessionID: sessionID, action: action, note: note))
    }

    @Test func xpcSessionRemindSetsReminderOnTargetSession() throws {
        let selected = store.sessions[0]
        let target = store.addSession(title: "target")!
        store.selectedSessionID = selected.id
        guard case .set(let reminder, let sessionID) = remind(target.id, .after(minutes: 15), note: "  check PRs  ") else {
            Issue.record("expected .set"); return
        }
        #expect(sessionID == target.id)
        #expect(reminder.target == .instant(ReminderFixture.anchor.addingTimeInterval(15 * 60)))
        #expect(reminder.note == "check PRs")
        #expect(target.reminder == reminder)
        #expect(selected.reminder == nil)
        #expect(store.reminderScheduler.pendingCount == 1)
    }

    @Test func xpcSessionRemindFallsBackToFocusedSession() throws {
        let focused = try #require(store.focusedSessionIDFallback())
        guard case .set(_, let sessionID) = remind(nil, .after(minutes: 30)) else {
            Issue.record("expected .set"); return
        }
        #expect(sessionID == focused)
        #expect(store.session(id: focused)?.reminder != nil)
    }

    private var storedTomorrowMinutes: Int? {
        testDefaults.defaults.object(forKey: SettingsPreference.reminderTomorrowTimeKey) as? Int
    }

    @Test func xpcSessionRemindTomorrowWithoutTimeUsesTheRememberedTime() throws {
        #expect(store.tomorrowReminderTime == Self.remembered)
        let session = store.sessions[0]
        guard case .set(let reminder, _) = remind(session.id, .tomorrow(time: nil)) else {
            Issue.record("expected .set"); return
        }
        #expect(reminder.fireDate(calendar: ReminderFixture.calendar()) == ReminderFixture.date(2026, 10, 15, 8, 30))
    }

    @Test func xpcSessionRemindTomorrowAtTimeUsesThatTime() throws {
        let session = store.sessions[0]
        guard case .set(let reminder, _) = remind(session.id, .tomorrow(time: .init(hour: 10, minute: 45))) else {
            Issue.record("expected .set"); return
        }
        #expect(reminder.fireDate(calendar: ReminderFixture.calendar()) == ReminderFixture.date(2026, 10, 15, 10, 45))
    }

    @Test func xpcSessionRemindNeverChangesTheRememberedTime() throws {
        let session = store.sessions[0]
        for action: SessionRemindAction in [.tomorrow(time: .init(hour: 10, minute: 45)), .tomorrow(time: nil), .after(minutes: 5), .cancel] {
            _ = remind(session.id, action)
        }
        #expect(store.tomorrowReminderTime == Self.remembered)
        #expect(storedTomorrowMinutes == 510)
    }

    @Test func xpcSessionRemindReplacesAnExistingReminder() throws {
        let session = store.sessions[0]
        let old = try #require(store.setReminder(.tomorrow(hour: 7, minute: 15), note: "old", forSessionID: session.id))
        guard case .set(let reminder, _) = remind(session.id, .after(minutes: 5)) else {
            Issue.record("expected .set"); return
        }
        #expect(reminder.id != old.id)
        #expect(reminder.note == nil)
        #expect(session.reminder == reminder)
        #expect(store.reminderScheduler.pendingCount == 1)
    }

    @Test func xpcSessionRemindUnknownSessionFails() {
        #expect(remind(UUID(), .after(minutes: 5)) == .unknownSession)
        #expect(remind(UUID(), .cancel) == .unknownSession)
    }

    @Test func xpcSessionRemindCancelIsIdempotent() throws {
        let session = store.sessions[0]
        try #require(store.setReminder(.after(minutes: 45), note: "x", forSessionID: session.id) != nil)
        #expect(remind(session.id, .cancel) == .cancelled(sessionID: session.id))
        #expect(session.reminder == nil)
        #expect(store.reminderScheduler.pendingCount == 0)
        #expect(remind(session.id, .cancel) == .cancelled(sessionID: session.id))
    }

    @Test func xpcSessionRemindOutOfRangeIsInvalidSpec() throws {
        let session = store.sessions[0]
        let existing = try #require(store.setReminder(.tomorrow(hour: 7, minute: 15), note: "keep", forSessionID: session.id))
        #expect(remind(session.id, .after(minutes: 0)) == .invalidSpec)
        #expect(remind(session.id, .after(minutes: 10_081)) == .invalidSpec)
        #expect(remind(session.id, .tomorrow(time: .init(hour: 24, minute: 0))) == .invalidSpec)
        #expect(session.reminder == existing)
    }

    // MARK: - Topology

    @Test func topologyPayloadIncludesPendingReminder() throws {
        let session = store.sessions[0]
        let reminder = try #require(store.setReminder(.tomorrow(hour: 8, minute: 30), note: "check PRs", forSessionID: session.id))
        let fromList = try #require(store.topologyPayload().windows.flatMap(\.sessions).first { $0.id == session.id })
        let fromInfo = try #require(store.sessionInfoPayload(sessionID: session.id))
        for payload in [fromList, fromInfo] {
            let r = try #require(payload.reminder)
            #expect(r.id == reminder.id)
            #expect(r.kind == .tomorrow)
            #expect(r.note == "check PRs")
            #expect(r.dueAt == "2026-10-15T15:30:00Z")
            #expect(r.createdAt == "2026-10-14T22:00:00Z")
        }
    }

    @Test func topologyPayloadOmitsReminderWhenNone() throws {
        let payload = try #require(store.sessionInfoPayload(sessionID: store.sessions[0].id))
        #expect(payload.reminder == nil)
        let raw = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(payload)) as? [String: Any])
        #expect(raw["reminder"] == nil)
    }

    @Test func topologyPayloadDecodesWithoutReminderField() throws {
        let session = store.sessions[0]
        try #require(store.setReminder(.after(minutes: 20), forSessionID: session.id) != nil)
        let payload = try #require(store.sessionInfoPayload(sessionID: session.id))
        var raw = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(payload)) as? [String: Any])
        #expect(raw.removeValue(forKey: "reminder") != nil)
        let decoded = try JSONDecoder().decode(TopologySessionPayload.self, from: try JSONSerialization.data(withJSONObject: raw))
        #expect(decoded.reminder == nil)
        #expect(decoded.id == session.id)
    }
}
