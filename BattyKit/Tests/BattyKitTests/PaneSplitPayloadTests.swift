// PaneSplitPayloadTests.swift

import Foundation
import Testing
@testable import BattyKit

// MARK: - Off-actor compile-time isolation guards
//
// Mirrors the guard pattern in `XPCContractTests.swift`/`TopologyPayloadTests
// .swift` (#0269/#0274): nesting does not propagate the guard, so
// `PaneSplitRequest`/`PaneSplitReply` each need their own direct round trip
// here even though `PaneSplitRequest` nests the already-guarded
// `TopologySplitDirection`.

private nonisolated func roundTripOffActor(_ request: PaneSplitRequest) throws -> PaneSplitRequest {
    let data = try JSONEncoder().encode(request)
    return try JSONDecoder().decode(PaneSplitRequest.self, from: data)
}

private nonisolated func roundTripOffActor(_ reply: PaneSplitReply) throws -> PaneSplitReply {
    let data = try JSONEncoder().encode(reply)
    return try JSONDecoder().decode(PaneSplitReply.self, from: data)
}

/// Covers `PaneSplitRequest`/`PaneSplitReply` (#0282) — the request/reply
/// shapes for the first mutating XPC verb.
struct PaneSplitPayloadTests {

    // MARK: - PaneSplitRequest

    @Test func requestRoundTripsWithExplicitPaneID() throws {
        let paneID = UUID()
        let request = PaneSplitRequest(paneID: paneID, direction: .vertical, command: "htop")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PaneSplitRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.paneID == paneID)
        #expect(decoded.direction == .vertical)
        #expect(decoded.command == "htop")
    }

    @Test func requestRoundTripsWithNilPaneIDAndCommand() throws {
        let request = PaneSplitRequest(paneID: nil, direction: .horizontal)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PaneSplitRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.paneID == nil)
        #expect(decoded.command == nil)
        #expect(decoded.kind == nil)
    }

    // MARK: - #0315's `kind` field

    @Test func requestRoundTripsWithExplicitKind() throws {
        let request = PaneSplitRequest(paneID: UUID(), direction: .horizontal, kind: .gitStatus)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PaneSplitRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.kind == .gitStatus)
    }

    /// Omitting `--view` client-side must produce a request that decodes
    /// with `kind == nil` — the wire/model default-to-terminal rule
    /// (`docs/pane-kinds.md` §4, #0315's user directive) starts here.
    @Test func requestDefaultKindIsNil() {
        let request = PaneSplitRequest(paneID: nil, direction: .horizontal)
        #expect(request.kind == nil)
    }

    /// A `nil` kind omits the JSON key entirely (Optional's synthesized
    /// `encodeIfPresent` behavior) rather than encoding an explicit `null`.
    /// Unlike `TopologyPanePayload.activeTabID` (a *read* contract
    /// `docs/pane-kinds.md` §5 says must keep every key always-present),
    /// `PaneSplitRequest` is a request payload only the CLI constructs and
    /// only the app decodes — no external consumer depends on its key set
    /// being stable, so plain `Optional` encoding is fine here.
    @Test func requestJSONOmitsKindKeyWhenNil() throws {
        let request = PaneSplitRequest(paneID: UUID(), direction: .horizontal)
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(!raw.keys.contains("kind"))
    }

    @Test func requestRoundTripsOffActor() throws {
        let decoded = try roundTripOffActor(PaneSplitRequest(paneID: UUID(), direction: .horizontal))
        #expect(decoded.direction == .horizontal)
    }

    @Test func requestRoundTripsInsideXPCRequestPayload() throws {
        let request = PaneSplitRequest(paneID: UUID(), direction: .vertical, command: "top")
        let requestData = try JSONEncoder().encode(request)
        let envelope = XPCRequest(verb: XPCVerb.paneSplit, payload: requestData)
        let envelopeData = try JSONEncoder().encode(envelope)
        let decodedEnvelope = try JSONDecoder().decode(XPCRequest.self, from: envelopeData)
        let decodedRequest = try JSONDecoder().decode(PaneSplitRequest.self, from: decodedEnvelope.payload!)
        #expect(decodedRequest == request)
    }

    // MARK: - PaneSplitReply

    @Test func replyRoundTrips() throws {
        let paneID = UUID()
        let reply = PaneSplitReply(paneID: paneID)
        let data = try JSONEncoder().encode(reply)
        let decoded = try JSONDecoder().decode(PaneSplitReply.self, from: data)
        #expect(decoded == reply)
        #expect(decoded.paneID == paneID)
    }

    @Test func replyRoundTripsOffActor() throws {
        let paneID = UUID()
        let decoded = try roundTripOffActor(PaneSplitReply(paneID: paneID))
        #expect(decoded.paneID == paneID)
    }

    @Test func replyRoundTripsInsideXPCResponsePayload() throws {
        let paneID = UUID()
        let reply = PaneSplitReply(paneID: paneID)
        let payloadData = try JSONEncoder().encode(reply)
        let response = XPCResponse(ok: true, payload: payloadData)
        let responseData = try JSONEncoder().encode(response)
        let decodedResponse = try JSONDecoder().decode(XPCResponse.self, from: responseData)
        let decodedReply = try JSONDecoder().decode(PaneSplitReply.self, from: decodedResponse.payload!)
        #expect(decodedReply == reply)
    }

    // MARK: - Wire-shape stability (round trips are shape-blind — the
    // encoder and decoder change together — only a raw-JSON-key assertion
    // catches a rename that both sides agree on)

    @Test func requestJSONTopLevelKeysAreStable() throws {
        let request = PaneSplitRequest(paneID: UUID(), direction: .horizontal, command: "top")
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["paneID", "direction", "command"])
    }

    /// The `kind` addition (#0315) is deliberate, visible wire-shape growth
    /// — distinct from `command`/`paneID` silently vanishing when nil,
    /// which the test above already covers by omission.
    @Test func requestJSONTopLevelKeysIncludeKindWhenPresent() throws {
        let request = PaneSplitRequest(paneID: UUID(), direction: .horizontal, command: "top", kind: .processStatus)
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["paneID", "direction", "command", "kind"])
    }

    @Test func replyJSONTopLevelKeysAreStable() throws {
        let reply = PaneSplitReply(paneID: UUID())
        let data = try JSONEncoder().encode(reply)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["paneID"])
    }

    // MARK: - XPCVerb

    @Test func xpcVerbPaneSplitMatchesLiteral() {
        #expect(XPCVerb.paneSplit == "paneSplit")
    }

    @Test func xpcVerbPaneSplitIsDistinctFromOtherVerbs() {
        let verbs: Set<String> = [XPCVerb.status, XPCVerb.list, XPCVerb.sessionInfo, XPCVerb.paneSplit]
        #expect(verbs.count == 4)
    }

    // MARK: - AppXPCService's wire-direction → model-direction mapping
    //
    // `AppXPCService.perform` converts `PaneSplitRequest.direction`
    // (`TopologySplitDirection`) to the model's `SplitDirection` via
    // `SplitDirection(rawValue: request.direction.rawValue) ?? .horizontal`
    // — the `?? .horizontal` fallback would silently turn a `.vertical`
    // request into a horizontal split if the two enums' raw values ever
    // diverged. Pinning both directions here catches that regression; the
    // store-level tests (`AppStateStorePaneSplitTests`) pass `SplitDirection`
    // directly and so never exercise this conversion.

    @Test func wireDirectionRawValuesMapOntoTheModelSplitDirection() {
        #expect(SplitDirection(rawValue: TopologySplitDirection.horizontal.rawValue) == .horizontal)
        #expect(SplitDirection(rawValue: TopologySplitDirection.vertical.rawValue) == .vertical)
    }
}
