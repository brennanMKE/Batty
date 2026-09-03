// CloseHideShowPayloadTests.swift

import Foundation
import Testing
@testable import BattyKit

// MARK: - Off-actor compile-time isolation guards
//
// Mirrors the guard pattern in `PaneClosePayloadTests.swift`/
// `FocusPayloadTests.swift`: nesting does not propagate the guard, so each
// of these three payload types needs its own direct round trip here even
// though `PaneCloseRequest`/`PaneFocusRequest` already have one.

private nonisolated func roundTripOffActor(_ request: SessionCloseRequest) throws -> SessionCloseRequest {
    let data = try JSONEncoder().encode(request)
    return try JSONDecoder().decode(SessionCloseRequest.self, from: data)
}

private nonisolated func roundTripOffActor(_ request: PaneHideRequest) throws -> PaneHideRequest {
    let data = try JSONEncoder().encode(request)
    return try JSONDecoder().decode(PaneHideRequest.self, from: data)
}

private nonisolated func roundTripOffActor(_ request: PaneShowRequest) throws -> PaneShowRequest {
    let data = try JSONEncoder().encode(request)
    return try JSONDecoder().decode(PaneShowRequest.self, from: data)
}

/// Covers `SessionCloseRequest`/`SessionCloseReply` (#0382) — the
/// request/reply shapes for the `sessionClose` XPC verb.
struct SessionClosePayloadTests {

    @Test func requestRoundTripsWithExplicitSessionID() throws {
        let sessionID = UUID()
        let request = SessionCloseRequest(sessionID: sessionID)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(SessionCloseRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.sessionID == sessionID)
    }

    @Test func requestRoundTripsWithNilSessionID() throws {
        let request = SessionCloseRequest(sessionID: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(SessionCloseRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.sessionID == nil)
    }

    @Test func requestRoundTripsOffActor() throws {
        let decoded = try roundTripOffActor(SessionCloseRequest(sessionID: UUID()))
        #expect(decoded.sessionID != nil)
    }

    @Test func replyRoundTrips() throws {
        let reply = SessionCloseReply()
        let data = try JSONEncoder().encode(reply)
        let decoded = try JSONDecoder().decode(SessionCloseReply.self, from: data)
        #expect(decoded == reply)
    }

    @Test func requestJSONTopLevelKeysAreStable() throws {
        let request = SessionCloseRequest(sessionID: UUID())
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["sessionID"])
    }

    @Test func xpcVerbSessionCloseMatchesLiteral() {
        #expect(XPCVerb.sessionClose == "sessionClose")
    }
}

/// Covers `PaneHideRequest`/`PaneHideReply` (#0382) — the request/reply
/// shapes for the `paneHide` XPC verb.
struct PaneHidePayloadTests {

    @Test func requestRoundTripsWithExplicitPaneID() throws {
        let paneID = UUID()
        let request = PaneHideRequest(paneID: paneID)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PaneHideRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.paneID == paneID)
    }

    @Test func requestRoundTripsWithNilPaneID() throws {
        let request = PaneHideRequest(paneID: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PaneHideRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.paneID == nil)
    }

    @Test func requestRoundTripsOffActor() throws {
        let decoded = try roundTripOffActor(PaneHideRequest(paneID: UUID()))
        #expect(decoded.paneID != nil)
    }

    @Test func replyRoundTrips() throws {
        let reply = PaneHideReply()
        let data = try JSONEncoder().encode(reply)
        let decoded = try JSONDecoder().decode(PaneHideReply.self, from: data)
        #expect(decoded == reply)
    }

    @Test func requestJSONTopLevelKeysAreStable() throws {
        let request = PaneHideRequest(paneID: UUID())
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["paneID"])
    }

    @Test func xpcVerbPaneHideMatchesLiteral() {
        #expect(XPCVerb.paneHide == "paneHide")
    }
}

/// Covers `PaneShowRequest`/`PaneShowReply` (#0382) — the request/reply
/// shapes for the `paneShow` XPC verb. Unlike `PaneHideRequest`, `paneID`
/// is non-optional — #0382's pinned decision: `pane show` has no
/// fallback target.
struct PaneShowPayloadTests {

    @Test func requestRoundTrips() throws {
        let paneID = UUID()
        let request = PaneShowRequest(paneID: paneID)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PaneShowRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.paneID == paneID)
    }

    @Test func requestRoundTripsOffActor() throws {
        let paneID = UUID()
        let decoded = try roundTripOffActor(PaneShowRequest(paneID: paneID))
        #expect(decoded.paneID == paneID)
    }

    @Test func replyRoundTrips() throws {
        let reply = PaneShowReply()
        let data = try JSONEncoder().encode(reply)
        let decoded = try JSONDecoder().decode(PaneShowReply.self, from: data)
        #expect(decoded == reply)
    }

    @Test func requestJSONTopLevelKeysAreStable() throws {
        let request = PaneShowRequest(paneID: UUID())
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["paneID"])
    }

    @Test func requestPaneIDIsNotOptionalInTheWireShape() throws {
        // A malformed/missing `paneID` key must fail to decode outright —
        // there is no fallback semantic for this verb (#0257: a hidden
        // pane has no shell to run `batty` from), unlike
        // `PaneHideRequest`/`PaneCloseRequest`, where an absent key
        // decodes to `nil` and falls through to focused-element
        // resolution.
        let json = "{}".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(PaneShowRequest.self, from: json)
        }
    }

    @Test func xpcVerbPaneShowMatchesLiteral() {
        #expect(XPCVerb.paneShow == "paneShow")
    }
}
