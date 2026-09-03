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

    // MARK: - #0304's `viewOptions` field (review round 1: replaces an
    // earlier `path: String?` field this issue shipped first — retargeted
    // to the shared, per-kind-generic shape so #0305/#0313/#0314 don't each
    // need their own wire-shape change).

    @Test func requestRoundTripsWithExplicitViewOptions() throws {
        let request = PaneSplitRequest(paneID: UUID(), direction: .horizontal, kind: .gitStatus, viewOptions: ["path": "/Users/example/project"])
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PaneSplitRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.viewOptions?["path"] == "/Users/example/project")
    }

    @Test func requestDefaultViewOptionsIsNil() {
        let request = PaneSplitRequest(paneID: nil, direction: .horizontal)
        #expect(request.viewOptions == nil)
    }

    @Test func requestJSONOmitsViewOptionsKeyWhenNil() throws {
        let request = PaneSplitRequest(paneID: UUID(), direction: .horizontal, kind: .gitStatus)
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(!raw.keys.contains("viewOptions"))
    }

    @Test func requestJSONTopLevelKeysIncludeViewOptionsWhenPresent() throws {
        let request = PaneSplitRequest(paneID: UUID(), direction: .horizontal, kind: .gitStatus, viewOptions: ["path": "/tmp"])
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["paneID", "direction", "kind", "viewOptions"])
    }

    /// The bag is generic — nothing about the wire shape pins it to
    /// `"path"` specifically. A future kind's own key round-trips the
    /// same way, without touching this struct.
    @Test func requestViewOptionsCarriesArbitraryKeysForFutureKinds() throws {
        let request = PaneSplitRequest(paneID: UUID(), direction: .horizontal, kind: .processStatus, viewOptions: ["pid": "1234"])
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PaneSplitRequest.self, from: data)
        #expect(decoded.viewOptions?["pid"] == "1234")
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

    // MARK: - #0305's `processStatusPid` folded into `viewOptions["pid"]`
    //
    // #0305 landed `processStatusPid: Int32?` as its own flat field before
    // this issue's `viewOptions` bag existed; the #0304/#0305 rebase folds
    // it into `viewOptions["pid"]` the same way `path` already lives in
    // `viewOptions["path"]` — one generic bag, not one field per kind.
    // The general round-trip/default/omission behavior is already covered
    // by the `viewOptions` tests above (the bag doesn't care which string
    // key it holds); what's worth pinning specifically here is `pid`'s own
    // round trip and the legacy-client decode path.

    @Test func requestRoundTripsWithPidInViewOptions() throws {
        let request = PaneSplitRequest(paneID: UUID(), direction: .horizontal, kind: .processStatus, viewOptions: ["pid": "4242"])
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PaneSplitRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.viewOptions?["pid"] == "4242")
    }

    /// A legacy client (any `batty` binary built before `viewOptions`
    /// existed, including #0305's own `processStatusPid`-only build) never
    /// sends `viewOptions` at all — its JSON, decoded here as a raw
    /// literal rather than round-tripped through this version's own
    /// encoder, must still decode successfully with `viewOptions == nil`
    /// rather than failing to decode.
    @Test func requestDecodesFromLegacyJSONMissingTheViewOptionsKey() throws {
        let legacyJSON = """
        {"paneID":null,"direction":"horizontal"}
        """
        let decoded = try JSONDecoder().decode(PaneSplitRequest.self, from: Data(legacyJSON.utf8))
        #expect(decoded.paneID == nil)
        #expect(decoded.direction == .horizontal)
        #expect(decoded.kind == nil)
        #expect(decoded.viewOptions == nil)
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

    // MARK: - #0383's `unique` field

    @Test func requestRoundTripsWithUniqueTrue() throws {
        let request = PaneSplitRequest(paneID: UUID(), direction: .horizontal, kind: .gitStatus, unique: true)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PaneSplitRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.unique == true)
    }

    @Test func requestDefaultUniqueIsNil() {
        let request = PaneSplitRequest(paneID: nil, direction: .horizontal)
        #expect(request.unique == nil)
    }

    @Test func requestJSONOmitsUniqueKeyWhenNil() throws {
        let request = PaneSplitRequest(paneID: UUID(), direction: .horizontal, kind: .gitStatus)
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(!raw.keys.contains("unique"))
    }

    /// A CLI build predating `--unique` never sends the key at all — the
    /// app must still decode the rest of the request rather than failing
    /// closed on an absent optional field.
    @Test func requestDecodesFromLegacyJSONMissingTheUniqueKey() throws {
        let legacyJSON = """
        {"paneID":null,"direction":"horizontal"}
        """
        let decoded = try JSONDecoder().decode(PaneSplitRequest.self, from: Data(legacyJSON.utf8))
        #expect(decoded.unique == nil)
    }

    /// The `unique` addition is deliberate, visible wire-shape growth when
    /// present — the omission-when-nil test above only proves the key
    /// vanishes; this is the companion that proves it actually appears on
    /// the wire when set, the same pairing #0315 established for `kind`
    /// (`requestJSONOmitsKindKeyWhenNil` / `requestJSONTopLevelKeysIncludeKindWhenPresent`).
    @Test func requestJSONTopLevelKeysIncludeUniqueWhenPresent() throws {
        let request = PaneSplitRequest(paneID: UUID(), direction: .horizontal, kind: .gitStatus, unique: true)
        let data = try JSONEncoder().encode(request)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["paneID", "direction", "kind", "unique"])
    }

    // MARK: - #0383's `created` field on the reply

    @Test func replyRoundTripsWithCreatedFalse() throws {
        let paneID = UUID()
        let reply = PaneSplitReply(paneID: paneID, created: false)
        let data = try JSONEncoder().encode(reply)
        let decoded = try JSONDecoder().decode(PaneSplitReply.self, from: data)
        #expect(decoded == reply)
        #expect(decoded.created == false)
    }

    @Test func replyDefaultCreatedIsNil() {
        let reply = PaneSplitReply(paneID: UUID())
        #expect(reply.created == nil)
    }

    /// An app build predating #0383 never sends the key — a caller must
    /// still decode a bare `{"paneID": ...}` reply, interpreting the
    /// absent field as "no opinion," not a decode failure.
    @Test func replyDecodesFromLegacyJSONMissingTheCreatedKey() throws {
        let paneID = UUID()
        let legacyJSON = "{\"paneID\":\"\(paneID.uuidString)\"}"
        let decoded = try JSONDecoder().decode(PaneSplitReply.self, from: Data(legacyJSON.utf8))
        #expect(decoded.paneID == paneID)
        #expect(decoded.created == nil)
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

    /// The stable-keys test above only proves `created` vanishes when
    /// `nil` (the ordinary/legacy-compatible case); nothing until this
    /// test observed `created` in real encoded JSON at all.
    @Test func replyJSONTopLevelKeysIncludeCreatedWhenPresent() throws {
        let reply = PaneSplitReply(paneID: UUID(), created: false)
        let data = try JSONEncoder().encode(reply)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["paneID", "created"])
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
