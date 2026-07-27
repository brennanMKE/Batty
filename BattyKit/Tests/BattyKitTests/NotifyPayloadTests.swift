// NotifyPayloadTests.swift

import Foundation
import Testing
@testable import BattyKit

// MARK: - Off-actor compile-time isolation guards
//
// Mirrors the guard pattern in `PaneClosePayloadTests.swift`: nesting does
// not propagate the guard, so `NotifyRequest`/`NotifyReply` each need their
// own direct round trip here even though `PaneCloseRequest` already has one.

private nonisolated func roundTripOffActor(_ request: NotifyRequest) throws -> NotifyRequest {
    let data = try JSONEncoder().encode(request)
    return try JSONDecoder().decode(NotifyRequest.self, from: data)
}

private nonisolated func roundTripOffActor(_ reply: NotifyReply) throws -> NotifyReply {
    let data = try JSONEncoder().encode(reply)
    return try JSONDecoder().decode(NotifyReply.self, from: data)
}

/// Covers `NotifyRequest`/`NotifyReply` (#0284) — the request/reply shapes
/// for the third mutating XPC verb.
struct NotifyPayloadTests {

    // MARK: - NotifyRequest

    @Test func requestRoundTripsWithExplicitTabIDAndBody() throws {
        let tabID = UUID()
        let request = NotifyRequest(tabID: tabID, title: "Build finished", body: "0 errors, 2 warnings", sound: true)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(NotifyRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.tabID == tabID)
        #expect(decoded.title == "Build finished")
        #expect(decoded.body == "0 errors, 2 warnings")
        #expect(decoded.sound == true)
    }

    @Test func requestRoundTripsWithNilTabIDAndBody() throws {
        let request = NotifyRequest(tabID: nil, title: "Done", body: nil, sound: false)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(NotifyRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.tabID == nil)
        #expect(decoded.body == nil)
        #expect(decoded.sound == false)
    }

    @Test func requestRoundTripsOffActor() throws {
        let decoded = try roundTripOffActor(NotifyRequest(tabID: UUID(), title: "t", body: "b", sound: true))
        #expect(decoded.title == "t")
    }

    @Test func requestRoundTripsInsideXPCRequestPayload() throws {
        let request = NotifyRequest(tabID: UUID(), title: "Need input", body: nil, sound: false)
        let requestData = try JSONEncoder().encode(request)
        let envelope = XPCRequest(verb: XPCVerb.notify, payload: requestData)
        let envelopeData = try JSONEncoder().encode(envelope)
        let decodedEnvelope = try JSONDecoder().decode(XPCRequest.self, from: envelopeData)
        let decodedRequest = try JSONDecoder().decode(NotifyRequest.self, from: decodedEnvelope.payload!)
        #expect(decodedRequest == request)
    }

    // MARK: - NotifyReply

    @Test func replyRoundTrips() throws {
        let reply = NotifyReply()
        let data = try JSONEncoder().encode(reply)
        let decoded = try JSONDecoder().decode(NotifyReply.self, from: data)
        #expect(decoded == reply)
    }

    @Test func replyRoundTripsOffActor() throws {
        _ = try roundTripOffActor(NotifyReply())
    }

    @Test func replyRoundTripsInsideXPCResponsePayload() throws {
        let reply = NotifyReply()
        let payloadData = try JSONEncoder().encode(reply)
        let response = XPCResponse(ok: true, payload: payloadData)
        let responseData = try JSONEncoder().encode(response)
        let decodedResponse = try JSONDecoder().decode(XPCResponse.self, from: responseData)
        let decodedReply = try JSONDecoder().decode(NotifyReply.self, from: decodedResponse.payload!)
        #expect(decodedReply == reply)
    }

    // MARK: - Wire-shape stability (round trips are shape-blind — the
    // encoder and decoder change together — only a raw-JSON-key assertion
    // catches a rename that both sides agree on)

    @Test func requestJSONTopLevelKeysAreStable() throws {
        let request = NotifyRequest(tabID: UUID(), title: "t", body: "b", sound: true)
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["tabID", "title", "body", "sound"])
    }

    @Test func requestJSONOmitsBodyKeyWhenNil() throws {
        let request = NotifyRequest(tabID: nil, title: "t", body: nil, sound: false)
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(!raw.keys.contains("body"))
        #expect(!raw.keys.contains("tabID"))
        #expect(Set(raw.keys) == ["title", "sound"])
    }

    @Test func replyJSONTopLevelKeysAreStable() throws {
        let reply = NotifyReply()
        let data = try JSONEncoder().encode(reply)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(raw.keys.isEmpty)
    }

    // MARK: - XPCVerb

    @Test func xpcVerbNotifyMatchesLiteral() {
        #expect(XPCVerb.notify == "notify")
    }

    @Test func xpcVerbNotifyIsDistinctFromOtherVerbs() {
        let verbs: Set<String> = [XPCVerb.status, XPCVerb.list, XPCVerb.sessionInfo, XPCVerb.paneSplit, XPCVerb.paneClose, XPCVerb.notify]
        #expect(verbs.count == 6)
    }
}
