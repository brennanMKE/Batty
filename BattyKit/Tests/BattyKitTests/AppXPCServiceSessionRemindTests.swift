// AppXPCServiceSessionRemindTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

/// The `sessionRemind` dispatch and its error strings, through the real
/// `AppXPCService.perform` against `AppStateStore.shared`. Reminders use the
/// 7-day maximum so nothing can fire during the run, and are cancelled after.
@MainActor
struct AppXPCServiceSessionRemindTests {
    private func perform(_ payload: Data) async throws -> XPCResponse {
        let service = AppXPCService()
        let requestData = try JSONEncoder().encode(XPCRequest(verb: XPCVerb.sessionRemind, payload: payload))
        let responseData: Data = await withCheckedContinuation { continuation in
            service.perform(requestData) { data in
                continuation.resume(returning: data)
            }
        }
        return try JSONDecoder().decode(XPCResponse.self, from: responseData)
    }

    private func perform(_ request: SessionRemindRequest) async throws -> XPCResponse {
        try await perform(try JSONEncoder().encode(request))
    }

    @Test func performSessionRemindSetsAndReturnsTheReminder() async throws {
        let session = AppStateStore.shared.addSession(title: "AppXPCServiceSessionRemindTests-set")!
        defer { AppStateStore.shared.cancelReminder(forSessionID: session.id) }
        let response = try await perform(SessionRemindRequest(sessionID: session.id, action: .after(minutes: 10_080), note: "n"))
        #expect(response.ok)
        let reply = try JSONDecoder().decode(SessionRemindReply.self, from: try #require(response.payload))
        #expect(reply.sessionID == session.id)
        let reminder = try #require(reply.reminder)
        #expect(reminder.kind == .instant)
        #expect(reminder.dueAt != nil)
        #expect(reminder.note == "n")
        #expect(session.reminder?.id == reminder.id)
    }

    @Test func performSessionRemindWithStaleSessionIDReturnsUnknownSessionIDFailure() async throws {
        let response = try await perform(SessionRemindRequest(sessionID: UUID(), action: .after(minutes: 10_080), note: nil))
        #expect(!response.ok)
        #expect(response.error == "unknown session id")
    }

    @Test func performSessionRemindOutOfRangeFails() async throws {
        let session = AppStateStore.shared.addSession(title: "AppXPCServiceSessionRemindTests-range")!
        let response = try await perform(SessionRemindRequest(sessionID: session.id, action: .after(minutes: 0), note: nil))
        #expect(!response.ok)
        #expect(response.error == "reminder time out of range")
    }

    @Test func performSessionRemindWithMalformedPayloadFails() async throws {
        let response = try await perform(Data("{}".utf8))
        #expect(!response.ok)
        #expect(response.error == "malformed session remind request")
    }

    @Test func performSessionRemindCancelOnASessionWithNoReminderReturnsOK() async throws {
        let session = AppStateStore.shared.addSession(title: "AppXPCServiceSessionRemindTests-cancel")!
        let response = try await perform(SessionRemindRequest(sessionID: session.id, action: .cancel, note: nil))
        #expect(response.ok)
        let reply = try JSONDecoder().decode(SessionRemindReply.self, from: try #require(response.payload))
        #expect(reply.reminder == nil)
        #expect(session.reminder == nil)
    }
}
