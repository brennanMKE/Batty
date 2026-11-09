// SessionRemindPayloadTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

struct SessionRemindPayloadTests {
    @Test(arguments: [
        ("5m", 5), ("90m", 90), ("1h30m", 90), ("2h", 120), ("10080m", 10_080), ("168h", 10_080), ("1h0m", 60),
    ])
    func remindDurationParsingAccepts(text: String, minutes: Int) {
        #expect(SessionRemindRequest.parseDuration(text) == minutes)
    }

    @Test(arguments: ["0m", "0h0m", "10081m", "1h90m", "1x", "5", "5M", "-5m", "", "m", "h", "h5m", "1h5", "99999999999999999999m", "9999999999999999999h"])
    func remindDurationParsingRejects(text: String) {
        #expect(SessionRemindRequest.parseDuration(text) == nil)
    }

    @Test func remindTimeOfDayParsing() {
        #expect(SessionRemindTimeOfDay.parse("09:00") == .init(hour: 9, minute: 0))
        #expect(SessionRemindTimeOfDay.parse("9:00") == .init(hour: 9, minute: 0))
        #expect(SessionRemindTimeOfDay.parse("23:59") == .init(hour: 23, minute: 59))
        #expect(SessionRemindTimeOfDay.parse("0:00") == .init(hour: 0, minute: 0))
        for bad in ["9", "9am", "24:00", "09:60", "9:5", "", ":00", "009:00", "+9:00"] {
            #expect(SessionRemindTimeOfDay.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func sessionRemindBoundsMatchReminderSpec() {
        #expect(SessionRemindRequest.minMinutes == ReminderSpec.minMinutes)
        #expect(SessionRemindRequest.maxMinutes == ReminderSpec.maxMinutes)
    }

    @Test(arguments: [
        SessionRemindAction.after(minutes: 90),
        .tomorrow(time: .init(hour: 8, minute: 30)),
        .tomorrow(time: nil),
        .cancel,
    ])
    func sessionRemindRequestRoundTrips(action: SessionRemindAction) async throws {
        let request = SessionRemindRequest(sessionID: UUID(), action: action, note: "check PRs")
        let decoded = try await Task.detached {
            try JSONDecoder().decode(SessionRemindRequest.self, from: try JSONEncoder().encode(request))
        }.value
        #expect(decoded == request)
    }

    @Test func sessionRemindReplyRoundTrips() async throws {
        let reminder = TopologyReminderPayload(id: UUID(), dueAt: "2026-10-15T15:30:00Z", note: "n", kind: .tomorrow, createdAt: "2026-10-14T22:00:00Z")
        for reply in [SessionRemindReply(sessionID: UUID(), reminder: reminder), SessionRemindReply(sessionID: UUID(), reminder: nil)] {
            let decoded = try await Task.detached {
                try JSONDecoder().decode(SessionRemindReply.self, from: try JSONEncoder().encode(reply))
            }.value
            #expect(decoded == reply)
        }
    }
}
