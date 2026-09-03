// FocusPayloadTests.swift

import Foundation
import Testing
@testable import BattyKit

// MARK: - Off-actor compile-time isolation guards
//
// Mirrors the guard pattern in `PaneSplitPayloadTests.swift`/
// `PaneClosePayloadTests.swift`: nesting does not propagate the guard, so
// each of `SessionFocusRequest`/`PaneFocusRequest`/`TabFocusRequest` needs
// its own direct round trip here even though `PaneCloseRequest` already
// has one of the same shape.

private nonisolated func roundTripOffActor(_ request: SessionFocusRequest) throws -> SessionFocusRequest {
    let data = try JSONEncoder().encode(request)
    return try JSONDecoder().decode(SessionFocusRequest.self, from: data)
}

private nonisolated func roundTripOffActor(_ request: PaneFocusRequest) throws -> PaneFocusRequest {
    let data = try JSONEncoder().encode(request)
    return try JSONDecoder().decode(PaneFocusRequest.self, from: data)
}

private nonisolated func roundTripOffActor(_ request: TabFocusRequest) throws -> TabFocusRequest {
    let data = try JSONEncoder().encode(request)
    return try JSONDecoder().decode(TabFocusRequest.self, from: data)
}

/// Covers `SessionFocusRequest`/`PaneFocusRequest`/`TabFocusRequest` and
/// their (empty) replies (#0381) — the request/reply shapes for the fourth,
/// fifth, and sixth mutating XPC verbs, plus the three new `XPCVerb`
/// literals.
struct FocusPayloadTests {

    // MARK: - SessionFocusRequest / SessionFocusReply

    @Test func sessionFocusRequestRoundTripsWithExplicitID() throws {
        let sessionID = UUID()
        let request = SessionFocusRequest(sessionID: sessionID)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(SessionFocusRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.sessionID == sessionID)
    }

    @Test func sessionFocusRequestRoundTripsWithNilID() throws {
        let request = SessionFocusRequest(sessionID: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(SessionFocusRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.sessionID == nil)
    }

    @Test func sessionFocusRequestRoundTripsOffActor() throws {
        let decoded = try roundTripOffActor(SessionFocusRequest(sessionID: UUID()))
        #expect(decoded.sessionID != nil)
    }

    @Test func sessionFocusRequestRoundTripsInsideXPCRequestPayload() throws {
        let request = SessionFocusRequest(sessionID: UUID())
        let requestData = try JSONEncoder().encode(request)
        let envelope = XPCRequest(verb: XPCVerb.sessionFocus, payload: requestData)
        let envelopeData = try JSONEncoder().encode(envelope)
        let decodedEnvelope = try JSONDecoder().decode(XPCRequest.self, from: envelopeData)
        let decodedRequest = try JSONDecoder().decode(SessionFocusRequest.self, from: decodedEnvelope.payload!)
        #expect(decodedRequest == request)
    }

    @Test func sessionFocusReplyRoundTrips() throws {
        let reply = SessionFocusReply()
        let data = try JSONEncoder().encode(reply)
        let decoded = try JSONDecoder().decode(SessionFocusReply.self, from: data)
        #expect(decoded == reply)
    }

    @Test func sessionFocusRequestJSONTopLevelKeysAreStable() throws {
        let request = SessionFocusRequest(sessionID: UUID())
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["sessionID"])
    }

    // MARK: - PaneFocusRequest / PaneFocusReply

    @Test func paneFocusRequestRoundTripsWithExplicitID() throws {
        let paneID = UUID()
        let request = PaneFocusRequest(paneID: paneID)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PaneFocusRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.paneID == paneID)
    }

    @Test func paneFocusRequestRoundTripsWithNilID() throws {
        let request = PaneFocusRequest(paneID: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PaneFocusRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.paneID == nil)
    }

    @Test func paneFocusRequestRoundTripsOffActor() throws {
        let decoded = try roundTripOffActor(PaneFocusRequest(paneID: UUID()))
        #expect(decoded.paneID != nil)
    }

    @Test func paneFocusRequestRoundTripsInsideXPCRequestPayload() throws {
        let request = PaneFocusRequest(paneID: UUID())
        let requestData = try JSONEncoder().encode(request)
        let envelope = XPCRequest(verb: XPCVerb.paneFocus, payload: requestData)
        let envelopeData = try JSONEncoder().encode(envelope)
        let decodedEnvelope = try JSONDecoder().decode(XPCRequest.self, from: envelopeData)
        let decodedRequest = try JSONDecoder().decode(PaneFocusRequest.self, from: decodedEnvelope.payload!)
        #expect(decodedRequest == request)
    }

    @Test func paneFocusReplyRoundTrips() throws {
        let reply = PaneFocusReply()
        let data = try JSONEncoder().encode(reply)
        let decoded = try JSONDecoder().decode(PaneFocusReply.self, from: data)
        #expect(decoded == reply)
    }

    @Test func paneFocusRequestJSONTopLevelKeysAreStable() throws {
        let request = PaneFocusRequest(paneID: UUID())
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["paneID"])
    }

    // MARK: - TabFocusRequest / TabFocusReply

    @Test func tabFocusRequestRoundTripsWithExplicitID() throws {
        let tabID = UUID()
        let request = TabFocusRequest(tabID: tabID)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(TabFocusRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.tabID == tabID)
    }

    @Test func tabFocusRequestRoundTripsWithNilID() throws {
        let request = TabFocusRequest(tabID: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(TabFocusRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.tabID == nil)
    }

    @Test func tabFocusRequestRoundTripsOffActor() throws {
        let decoded = try roundTripOffActor(TabFocusRequest(tabID: UUID()))
        #expect(decoded.tabID != nil)
    }

    @Test func tabFocusRequestRoundTripsInsideXPCRequestPayload() throws {
        let request = TabFocusRequest(tabID: UUID())
        let requestData = try JSONEncoder().encode(request)
        let envelope = XPCRequest(verb: XPCVerb.tabFocus, payload: requestData)
        let envelopeData = try JSONEncoder().encode(envelope)
        let decodedEnvelope = try JSONDecoder().decode(XPCRequest.self, from: envelopeData)
        let decodedRequest = try JSONDecoder().decode(TabFocusRequest.self, from: decodedEnvelope.payload!)
        #expect(decodedRequest == request)
    }

    @Test func tabFocusReplyRoundTrips() throws {
        let reply = TabFocusReply()
        let data = try JSONEncoder().encode(reply)
        let decoded = try JSONDecoder().decode(TabFocusReply.self, from: data)
        #expect(decoded == reply)
    }

    @Test func tabFocusRequestJSONTopLevelKeysAreStable() throws {
        let request = TabFocusRequest(tabID: UUID())
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["tabID"])
    }

    // MARK: - XPCVerb

    @Test func xpcVerbFocusLiteralsMatchExpectedStrings() {
        #expect(XPCVerb.sessionFocus == "sessionFocus")
        #expect(XPCVerb.paneFocus == "paneFocus")
        #expect(XPCVerb.tabFocus == "tabFocus")
    }

    @Test func xpcVerbFocusLiteralsAreDistinctFromEveryOtherVerb() {
        let verbs: Set<String> = [
            XPCVerb.status, XPCVerb.list, XPCVerb.sessionInfo,
            XPCVerb.paneSplit, XPCVerb.paneClose, XPCVerb.notify,
            XPCVerb.sessionFocus, XPCVerb.paneFocus, XPCVerb.tabFocus,
        ]
        #expect(verbs.count == 9)
    }

    // MARK: - WatchEventType (#0381's watch-event coverage note)

    @Test func watchEventTypeAllNamesIncludesTheThreeFocusEvents() {
        #expect(WatchEventType.allNames.contains("session_focused"))
        #expect(WatchEventType.allNames.contains("pane_focused"))
        #expect(WatchEventType.allNames.contains("tab_focused"))
    }

    /// `contains` checks catch an addition but not a deletion — a reviewer
    /// mutation that removed `"tab_created"` and `"active_tab_changed"` from
    /// a hand-listed `allNames` (silently unsubscribing every default
    /// `batty watch` from those events) passed the whole suite under the
    /// weaker check above. Pin the exact 8-element set.
    @Test func watchEventTypeAllNamesIsExactlyTheEightExpectedEvents() {
        #expect(Set(WatchEventType.allNames) == Set([
            "session_created", "session_destroyed", "pane_split", "tab_created",
            "active_tab_changed", "session_focused", "pane_focused", "tab_focused",
        ]))
        #expect(WatchEventType.allNames.count == 8)
    }
}
