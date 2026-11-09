// SessionRemindCommandTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import batty

struct SessionRemindCommandTests {
    @Test(arguments: [
        [String](),
        ["--in", "5m", "--tomorrow"],
        ["--in", "5m", "--cancel"],
        ["--tomorrow", "--cancel"],
        ["--at", "09:00"],
        ["--in", "5m", "--at", "09:00"],
        ["--cancel", "--note", "x"],
        ["--in", "0m"],
        ["--in", "10081m"],
        ["--in", "1x"],
        ["--tomorrow", "--at", "25:00"],
        ["--tomorrow", "--at", "9am"],
    ])
    func remindArgumentValidation(argv: [String]) {
        #expect(throws: (any Error).self) { try SessionRemindCommand.parse(argv) }
    }

    @Test func remindValidArgumentsBuildTheExpectedRequest() throws {
        let id = UUID()
        #expect(try SessionRemindCommand.parse(["--in", "1h30m", "--note", "check PRs"]).makeRequest(sessionID: id)
            == SessionRemindRequest(sessionID: id, action: .after(minutes: 90), note: "check PRs"))
        #expect(try SessionRemindCommand.parse(["--tomorrow"]).makeRequest(sessionID: nil)
            == SessionRemindRequest(sessionID: nil, action: .tomorrow(time: nil), note: nil))
        #expect(try SessionRemindCommand.parse(["--tomorrow", "--at", "8:30"]).makeRequest(sessionID: nil)
            == SessionRemindRequest(sessionID: nil, action: .tomorrow(time: .init(hour: 8, minute: 30)), note: nil))
        #expect(try SessionRemindCommand.parse(["--cancel"]).makeRequest(sessionID: id)
            == SessionRemindRequest(sessionID: id, action: .cancel, note: nil))
    }

    @Test func remindConfirmationTextIsAbsolute() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let locale = Locale(identifier: "en_US")
        func reply(note: String?) -> SessionRemindReply {
            SessionRemindReply(sessionID: UUID(), reminder: TopologyReminderPayload(
                id: UUID(), dueAt: "2026-10-15T16:00:00Z", note: note, kind: .tomorrow, createdAt: "2026-10-14T22:00:00Z"))
        }
        let plain = SessionRemindCommand.confirmationText(for: reply(note: nil), calendar: calendar, locale: locale)
        #expect(plain?.hasPrefix("Reminder set for Thu, Oct 15") == true)
        #expect(plain?.contains("9:00") == true)
        #expect(plain?.hasSuffix("AM") == true)
        let noted = SessionRemindCommand.confirmationText(for: reply(note: "check PRs"), calendar: calendar, locale: locale)
        #expect(noted?.hasSuffix(" — check PRs") == true)
        #expect(SessionRemindCommand.confirmationText(for: SessionRemindReply(sessionID: UUID(), reminder: nil), calendar: calendar, locale: locale) == nil)
    }
}
