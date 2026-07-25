// TopologyPayloadTests.swift

import Foundation
import Testing
@testable import BattyKit

// MARK: - Off-actor compile-time isolation guards
//
// Mirrors the guard pattern in `XPCContractTests.swift` (#0269): every
// `@Test` in this file runs on the MainActor, which would not notice a
// future edit that drops `nonisolated` from one of these payload types —
// a MainActor caller compiles fine against main-actor-isolated
// declarations too. These free functions exist purely to fail to
// *compile* if that discipline regresses. One overload per type that is
// itself encoded/decoded directly in a nonisolated context somewhere in
// the product (`AppXPCService.perform`, `AppServiceClient.perform`, or a
// nested payload's own `Codable` conformance) — nesting does not
// propagate the check: a `nonisolated` outer type containing a
// non-`nonisolated` inner `Codable` type compiles and runs clean off the
// main actor, so each type needs its own direct round trip here.

private nonisolated func roundTripOffActor(_ payload: TopologyPayload) throws -> TopologyPayload {
    let data = try JSONEncoder().encode(payload)
    return try JSONDecoder().decode(TopologyPayload.self, from: data)
}

private nonisolated func roundTripOffActor(_ payload: TopologyWindowPayload) throws -> TopologyWindowPayload {
    let data = try JSONEncoder().encode(payload)
    return try JSONDecoder().decode(TopologyWindowPayload.self, from: data)
}

private nonisolated func roundTripOffActor(_ payload: TopologySessionPayload) throws -> TopologySessionPayload {
    let data = try JSONEncoder().encode(payload)
    return try JSONDecoder().decode(TopologySessionPayload.self, from: data)
}

private nonisolated func roundTripOffActor(_ node: TopologySplitNodePayload) throws -> TopologySplitNodePayload {
    let data = try JSONEncoder().encode(node)
    return try JSONDecoder().decode(TopologySplitNodePayload.self, from: data)
}

private nonisolated func roundTripOffActor(_ pane: TopologyPanePayload) throws -> TopologyPanePayload {
    let data = try JSONEncoder().encode(pane)
    return try JSONDecoder().decode(TopologyPanePayload.self, from: data)
}

private nonisolated func roundTripOffActor(_ tab: TopologyTabPayload) throws -> TopologyTabPayload {
    let data = try JSONEncoder().encode(tab)
    return try JSONDecoder().decode(TopologyTabPayload.self, from: data)
}

private nonisolated func roundTripOffActor(_ direction: TopologySplitDirection) throws -> TopologySplitDirection {
    let data = try JSONEncoder().encode(direction)
    return try JSONDecoder().decode(TopologySplitDirection.self, from: data)
}

private nonisolated func roundTripOffActor(_ request: SessionInfoRequest) throws -> SessionInfoRequest {
    let data = try JSONEncoder().encode(request)
    return try JSONDecoder().decode(SessionInfoRequest.self, from: data)
}

/// No XPC involved — pure round-trip and shape checks for the `list`/
/// `sessionInfo` payload types (#0274).
struct TopologyPayloadTests {

    // MARK: - Fixtures

    private static func leafPane(hidden: Bool = false, focused: Bool = false, tabCount: Int = 1) -> TopologyPanePayload {
        let tabs = (0..<tabCount).map { index in
            TopologyTabPayload(id: UUID(), title: "tab\(index)", workingDirectory: "/tmp", isActive: index == 0)
        }
        return TopologyPanePayload(id: UUID(), isHidden: hidden, isFocused: focused, activeTabID: tabs[0].id, tabs: tabs)
    }

    // MARK: - TopologySplitDirection

    @Test func splitDirectionRoundTrips() throws {
        for direction in [TopologySplitDirection.horizontal, .vertical] {
            let data = try JSONEncoder().encode(direction)
            let decoded = try JSONDecoder().decode(TopologySplitDirection.self, from: data)
            #expect(decoded == direction)
        }
    }

    @Test func splitDirectionRoundTripsOffActor() throws {
        let decoded = try roundTripOffActor(TopologySplitDirection.horizontal)
        #expect(decoded == .horizontal)
    }

    // MARK: - TopologyTabPayload

    @Test func tabPayloadRoundTrips() throws {
        let tab = TopologyTabPayload(id: UUID(), title: "zsh", workingDirectory: "/Users/brennan", isActive: true)
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(TopologyTabPayload.self, from: data)
        #expect(decoded == tab)
        #expect(decoded.title == "zsh")
        #expect(decoded.isActive)
    }

    @Test func tabPayloadWorkingDirectoryRoundTripsNil() throws {
        let tab = TopologyTabPayload(id: UUID(), title: "zsh", workingDirectory: nil, isActive: false)
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(TopologyTabPayload.self, from: data)
        #expect(decoded.workingDirectory == nil)
    }

    @Test func tabPayloadRoundTripsOffActor() throws {
        let decoded = try roundTripOffActor(TopologyTabPayload(id: UUID(), title: "zsh", workingDirectory: nil, isActive: true))
        #expect(decoded.title == "zsh")
    }

    // MARK: - TopologyPanePayload

    @Test func panePayloadRoundTrips() throws {
        let pane = Self.leafPane(hidden: true, focused: false, tabCount: 2)
        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(TopologyPanePayload.self, from: data)
        #expect(decoded == pane)
        #expect(decoded.isHidden)
        #expect(decoded.tabs.count == 2)
    }

    @Test func panePayloadRoundTripsOffActor() throws {
        let decoded = try roundTripOffActor(Self.leafPane())
        #expect(decoded.tabs.count == 1)
    }

    // MARK: - TopologySplitNodePayload (leaf / split)

    @Test func splitNodeLeafRoundTrips() throws {
        let node = TopologySplitNodePayload.leaf(pane: Self.leafPane())
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(TopologySplitNodePayload.self, from: data)
        #expect(decoded == node)
        #expect(decoded.allPanes.count == 1)
    }

    @Test func splitNodeSplitRoundTrips() throws {
        let left = TopologySplitNodePayload.leaf(pane: Self.leafPane())
        let right = TopologySplitNodePayload.leaf(pane: Self.leafPane(hidden: true))
        let node = TopologySplitNodePayload.split(id: UUID(), direction: .horizontal, ratio: 0.5, left: left, right: right)
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(TopologySplitNodePayload.self, from: data)
        #expect(decoded == node)
    }

    @Test func splitNodeRoundTripsOffActor() throws {
        let decoded = try roundTripOffActor(TopologySplitNodePayload.leaf(pane: Self.leafPane()))
        #expect(decoded.allPanes.count == 1)
    }

    @Test func splitNodeAllPanesFlattensNestedSplitsDepthFirst() {
        let paneA = Self.leafPane()
        let paneB = Self.leafPane()
        let paneC = Self.leafPane()
        // horizontal(vertical(A, B), C) — mirrors SplitTreeNode.allLeafPanes shape.
        let inner = TopologySplitNodePayload.split(id: UUID(), direction: .vertical, ratio: 0.5, left: .leaf(pane: paneA), right: .leaf(pane: paneB))
        let root = TopologySplitNodePayload.split(id: UUID(), direction: .horizontal, ratio: 0.5, left: inner, right: .leaf(pane: paneC))
        #expect(root.allPanes.map(\.id) == [paneA.id, paneB.id, paneC.id])
    }

    // MARK: - Wire-shape stability (review round 1: shape-blind round trips
    // can't catch a key-name regression since the encoder and decoder
    // change together)

    /// Asserts the *actual* top-level JSON keys `list`/`sessionInfo` emit,
    /// not just that encode-then-decode round-trips. Specifically guards
    /// against the compiler-synthesized `"_0"` key an unlabeled
    /// single-payload enum case would produce for `.leaf` — the `--json`
    /// contract this issue freezes for #0257/#0266 to consume.
    @Test func listJSONTopLevelKeysAreStableNotCompilerSynthesized() throws {
        let pane = Self.leafPane()
        let leaf = TopologySplitNodePayload.leaf(pane: pane)
        let data = try JSONEncoder().encode(leaf)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["leaf"])
        let leafBody = try #require(raw["leaf"] as? [String: Any])
        #expect(Set(leafBody.keys) == ["pane"], "the leaf payload must be keyed \"pane\", not the compiler-synthesized \"_0\"")
        #expect(leafBody["_0"] == nil)

        let paneBody = try #require(leafBody["pane"] as? [String: Any])
        #expect(Set(paneBody.keys) == ["id", "isHidden", "isFocused", "activeTabID", "tabs"])

        let split = TopologySplitNodePayload.split(id: UUID(), direction: .horizontal, ratio: 0.5, left: leaf, right: leaf)
        let splitData = try JSONEncoder().encode(split)
        let splitRaw = try #require(JSONSerialization.jsonObject(with: splitData) as? [String: Any])
        #expect(Set(splitRaw.keys) == ["split"])
        let splitBody = try #require(splitRaw["split"] as? [String: Any])
        #expect(Set(splitBody.keys) == ["id", "direction", "ratio", "left", "right"])
        #expect(splitBody["_0"] == nil)
    }

    @Test func sessionInfoJSONTopLevelKeysAreStable() throws {
        let pane = Self.leafPane()
        let session = TopologySessionPayload(id: UUID(), name: "S", path: "/tmp", isActive: true, focusedPaneID: pane.id, root: .leaf(pane: pane))
        let data = try JSONEncoder().encode(session)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["id", "name", "path", "isActive", "focusedPaneID", "root"])
    }

    // MARK: - TopologySessionPayload

    @Test func sessionPayloadRoundTrips() throws {
        let pane = Self.leafPane(focused: true)
        let session = TopologySessionPayload(
            id: UUID(),
            name: "Session 1",
            path: "/Users/brennan/dev",
            isActive: true,
            focusedPaneID: pane.id,
            root: .leaf(pane: pane)
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(TopologySessionPayload.self, from: data)
        #expect(decoded == session)
        #expect(decoded.allPanes.count == 1)
        #expect(decoded.allTabs.count == 1)
    }

    @Test func sessionPayloadPathRoundTripsNil() throws {
        let pane = Self.leafPane()
        let session = TopologySessionPayload(id: UUID(), name: "Session 1", path: nil, isActive: false, focusedPaneID: pane.id, root: .leaf(pane: pane))
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(TopologySessionPayload.self, from: data)
        #expect(decoded.path == nil)
    }

    @Test func sessionPayloadRoundTripsOffActor() throws {
        let pane = Self.leafPane()
        let session = TopologySessionPayload(id: UUID(), name: "S", path: nil, isActive: false, focusedPaneID: pane.id, root: .leaf(pane: pane))
        let decoded = try roundTripOffActor(session)
        #expect(decoded.name == "S")
    }

    // MARK: - TopologyWindowPayload / TopologyPayload

    @Test func windowPayloadRoundTripsOffActor() throws {
        let pane = Self.leafPane()
        let session = TopologySessionPayload(id: UUID(), name: "S", path: nil, isActive: true, focusedPaneID: pane.id, root: .leaf(pane: pane))
        let decoded = try roundTripOffActor(TopologyWindowPayload(id: UUID(), selectedSessionID: session.id, sessions: [session]))
        #expect(decoded.sessions.count == 1)
    }

    @Test func topologyPayloadRoundTrips() throws {
        let pane = Self.leafPane()
        let session = TopologySessionPayload(id: UUID(), name: "S", path: nil, isActive: true, focusedPaneID: pane.id, root: .leaf(pane: pane))
        let window = TopologyWindowPayload(id: UUID(), selectedSessionID: session.id, sessions: [session])
        let payload = TopologyPayload(pid: 4242, windows: [window])
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TopologyPayload.self, from: data)
        #expect(decoded == payload)
        #expect(decoded.pid == 4242)
        #expect(decoded.windows.count == 1)
    }

    @Test func topologyPayloadRoundTripsInsideXPCResponsePayload() throws {
        let pane = Self.leafPane()
        let session = TopologySessionPayload(id: UUID(), name: "S", path: nil, isActive: true, focusedPaneID: pane.id, root: .leaf(pane: pane))
        let window = TopologyWindowPayload(id: UUID(), selectedSessionID: session.id, sessions: [session])
        let payload = TopologyPayload(pid: 1, windows: [window])
        let payloadData = try JSONEncoder().encode(payload)
        let response = XPCResponse(ok: true, payload: payloadData)
        let responseData = try JSONEncoder().encode(response)
        let decodedResponse = try JSONDecoder().decode(XPCResponse.self, from: responseData)
        let decodedPayload = try JSONDecoder().decode(TopologyPayload.self, from: decodedResponse.payload!)
        #expect(decodedPayload == payload)
    }

    @Test func topologyPayloadRoundTripsOffActor() throws {
        let payload = TopologyPayload(pid: 7, windows: [])
        let decoded = try roundTripOffActor(payload)
        #expect(decoded.pid == 7)
        #expect(decoded.windows.isEmpty)
    }

    // MARK: - SessionInfoRequest

    @Test func sessionInfoRequestRoundTripsWithID() throws {
        let id = UUID()
        let request = SessionInfoRequest(sessionID: id)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(SessionInfoRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.sessionID == id)
    }

    @Test func sessionInfoRequestRoundTripsWithNilID() throws {
        let request = SessionInfoRequest()
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(SessionInfoRequest.self, from: data)
        #expect(decoded.sessionID == nil)
    }

    @Test func sessionInfoRequestRoundTripsOffActor() throws {
        let id = UUID()
        let decoded = try roundTripOffActor(SessionInfoRequest(sessionID: id))
        #expect(decoded.sessionID == id)
    }

    // MARK: - XPCVerb (#0274 additions)

    @Test func xpcVerbListAndSessionInfoAreDistinctFromStatus() {
        let verbs: Set<String> = [XPCVerb.status, XPCVerb.list, XPCVerb.sessionInfo]
        #expect(verbs.count == 3)
        #expect(XPCVerb.list == "list")
        #expect(XPCVerb.sessionInfo == "sessionInfo")
    }
}
