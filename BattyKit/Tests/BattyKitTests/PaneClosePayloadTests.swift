// PaneClosePayloadTests.swift

import Foundation
import Testing
@testable import BattyKit

// MARK: - Off-actor compile-time isolation guards
//
// Mirrors the guard pattern in `PaneSplitPayloadTests.swift`: nesting does
// not propagate the guard, so `PaneCloseRequest`/`PaneCloseReply` each need
// their own direct round trip here even though `PaneSplitRequest` already
// has one.

private nonisolated func roundTripOffActor(_ request: PaneCloseRequest) throws -> PaneCloseRequest {
    let data = try JSONEncoder().encode(request)
    return try JSONDecoder().decode(PaneCloseRequest.self, from: data)
}

private nonisolated func roundTripOffActor(_ reply: PaneCloseReply) throws -> PaneCloseReply {
    let data = try JSONEncoder().encode(reply)
    return try JSONDecoder().decode(PaneCloseReply.self, from: data)
}

/// Covers `PaneCloseRequest`/`PaneCloseReply` (#0283) — the request/reply
/// shapes for the second mutating XPC verb.
struct PaneClosePayloadTests {

    // MARK: - PaneCloseRequest

    @Test func requestRoundTripsWithExplicitPaneID() throws {
        let paneID = UUID()
        let request = PaneCloseRequest(paneID: paneID)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PaneCloseRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.paneID == paneID)
    }

    @Test func requestRoundTripsWithNilPaneID() throws {
        let request = PaneCloseRequest(paneID: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PaneCloseRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.paneID == nil)
    }

    @Test func requestRoundTripsOffActor() throws {
        let decoded = try roundTripOffActor(PaneCloseRequest(paneID: UUID()))
        #expect(decoded.paneID != nil)
    }

    @Test func requestRoundTripsInsideXPCRequestPayload() throws {
        let request = PaneCloseRequest(paneID: UUID())
        let requestData = try JSONEncoder().encode(request)
        let envelope = XPCRequest(verb: XPCVerb.paneClose, payload: requestData)
        let envelopeData = try JSONEncoder().encode(envelope)
        let decodedEnvelope = try JSONDecoder().decode(XPCRequest.self, from: envelopeData)
        let decodedRequest = try JSONDecoder().decode(PaneCloseRequest.self, from: decodedEnvelope.payload!)
        #expect(decodedRequest == request)
    }

    // MARK: - PaneCloseReply

    @Test func replyRoundTrips() throws {
        let reply = PaneCloseReply()
        let data = try JSONEncoder().encode(reply)
        let decoded = try JSONDecoder().decode(PaneCloseReply.self, from: data)
        #expect(decoded == reply)
    }

    @Test func replyRoundTripsOffActor() throws {
        _ = try roundTripOffActor(PaneCloseReply())
    }

    @Test func replyRoundTripsInsideXPCResponsePayload() throws {
        let reply = PaneCloseReply()
        let payloadData = try JSONEncoder().encode(reply)
        let response = XPCResponse(ok: true, payload: payloadData)
        let responseData = try JSONEncoder().encode(response)
        let decodedResponse = try JSONDecoder().decode(XPCResponse.self, from: responseData)
        let decodedReply = try JSONDecoder().decode(PaneCloseReply.self, from: decodedResponse.payload!)
        #expect(decodedReply == reply)
    }

    // MARK: - Wire-shape stability (round trips are shape-blind — the
    // encoder and decoder change together — only a raw-JSON-key assertion
    // catches a rename that both sides agree on)

    @Test func requestJSONTopLevelKeysAreStable() throws {
        let request = PaneCloseRequest(paneID: UUID())
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["paneID"])
    }

    @Test func replyJSONTopLevelKeysAreStable() throws {
        let reply = PaneCloseReply()
        let data = try JSONEncoder().encode(reply)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(raw.keys.isEmpty)
    }

    // MARK: - XPCVerb

    @Test func xpcVerbPaneCloseMatchesLiteral() {
        #expect(XPCVerb.paneClose == "paneClose")
    }

    @Test func xpcVerbPaneCloseIsDistinctFromOtherVerbs() {
        let verbs: Set<String> = [XPCVerb.status, XPCVerb.list, XPCVerb.sessionInfo, XPCVerb.paneSplit, XPCVerb.paneClose]
        #expect(verbs.count == 5)
    }
}
