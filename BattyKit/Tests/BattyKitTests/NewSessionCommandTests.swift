// NewSessionCommandTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import batty

/// Covers `NewSessionCommand.pollForNewSession` (#0380). `fetchTopology`
/// (#0380 round 4 review, B2) is an injected `(NSXPCListenerEndpoint) ->
/// AppServiceClient.Outcome<TopologyPayload>` closure, defaulting to the
/// real `AppServiceClient.list` call — a test overrides it with a pure
/// closure instead, so **every** branch of `pollForNewSession` is testable
/// with no live XPC connection at all: `resolveEndpoint` only needs to hand
/// back *some* `NSXPCListenerEndpoint` value (`NSXPCListener.anonymous()
/// .endpoint` below — never actually connected to, since `fetchTopology`
/// intercepts before any real call would happen) to reach the
/// `matches.count` `0`/`1`/`>1` dispatch, including the ambiguity branch
/// round 3 review (N2) shipped with no test for on the mistaken belief that
/// reaching it required a real endpoint.
///
/// `fetchPreDispatchState` is still *not* covered here: its `.unreachable`
/// / `.endpoint` branches call `BrokerAppEndpointClient.fetchEndpoint`
/// directly, which is not itself injectable, so any call to it opens a
/// real XPC connection attempt to the broker's Mach service — the "owning
/// code isn't reachable without a live app" problem `issues/0365.md`
/// documents for `AppConnectDance`/`StatusCommand` genuinely still applies
/// there, just not to `pollForNewSession` any more.
struct NewSessionCommandTests {

    private static let samplePath = "/tmp/NewSessionCommandTests"

    private static func emptySnapshot() -> TopologyPayload {
        TopologyPayload(pid: 0, windows: [])
    }

    /// A real (never-connected) endpoint value — `fetchTopology` intercepts
    /// before anything would try to use it, so nothing ever dials out.
    private static func fakeEndpoint() -> NSXPCListenerEndpoint {
        NSXPCListener.anonymous().endpoint
    }

    private static func leafSession(id: UUID, path: String?, paneID: UUID = UUID()) -> TopologySessionPayload {
        let tab = TopologyTabPayload(id: UUID(), title: "Tab", workingDirectory: path, isActive: true)
        let pane = TopologyPanePayload(id: paneID, isHidden: false, isFocused: true, activeTabID: tab.id, tabs: [tab], kind: .terminal)
        return TopologySessionPayload(id: id, name: "Session", path: path, isActive: false, focusedPaneID: paneID, root: .leaf(pane: pane))
    }

    private static func payload(sessions: [TopologySessionPayload]) -> TopologyPayload {
        let window = TopologyWindowPayload(id: UUID(), selectedSessionID: sessions.first?.id, sessions: sessions)
        return TopologyPayload(pid: 1, windows: [window])
    }

    // MARK: - endpointEverSeen (round 2 review, B2)

    /// The exact regression round 3 review named: an endpoint that never
    /// resolves within the poll bound must time out with
    /// `endpointEverSeen: false` (and, since `fetchTopology` is never
    /// reached, `sawAmbiguousMatch: false`) — the state `run()` maps to
    /// exit `3` ("app unavailable"), not exit `4`.
    @Test func timesOutWithEndpointNeverSeenWhenResolveEndpointAlwaysFails() {
        let outcome = NewSessionCommand.pollForNewSession(
            path: Self.samplePath,
            snapshot: Self.emptySnapshot(),
            maxAttempts: 2,
            interval: 0,
            resolveEndpoint: { nil }
        )

        guard case .timedOut(let endpointEverSeen, let sawAmbiguousMatch) = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            return
        }
        #expect(endpointEverSeen == false)
        #expect(sawAmbiguousMatch == false)
    }

    /// Same assertion at a different `maxAttempts`, to pin that the outcome
    /// doesn't depend on the bound being exactly the production value —
    /// this is a pure function of "did `resolveEndpoint` ever return
    /// non-`nil`," not of how many times it was tried.
    @Test func timesOutWithEndpointNeverSeenRegardlessOfAttemptCount() {
        let outcome = NewSessionCommand.pollForNewSession(
            path: Self.samplePath,
            snapshot: Self.emptySnapshot(),
            maxAttempts: 5,
            interval: 0,
            resolveEndpoint: { nil }
        )

        guard case .timedOut(let endpointEverSeen, _) = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            return
        }
        #expect(endpointEverSeen == false)
    }

    // MARK: - matches.count dispatch (round 4 review, B2)

    /// `matches.count == 0` every attempt: no Session ever shows up
    /// matching the path, so the poll runs out its full bound with a live
    /// endpoint the whole time — `endpointEverSeen: true`,
    /// `sawAmbiguousMatch: false`.
    @Test func noMatchKeepsPollingUntilTheBoundExpires() {
        let endpoint = Self.fakeEndpoint()
        let after = Self.payload(sessions: [Self.leafSession(id: UUID(), path: "/tmp/unrelated")])

        let outcome = NewSessionCommand.pollForNewSession(
            path: Self.samplePath,
            snapshot: Self.emptySnapshot(),
            maxAttempts: 3,
            interval: 0,
            resolveEndpoint: { endpoint },
            fetchTopology: { _ in .success(after) }
        )

        guard case .timedOut(let endpointEverSeen, let sawAmbiguousMatch) = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            return
        }
        #expect(endpointEverSeen == true)
        #expect(sawAmbiguousMatch == false)
    }

    /// `matches.count == 1` on the very first attempt: returns `.found`
    /// with that Session's id and focused Pane id.
    @Test func singleMatchReturnsFoundImmediately() {
        let endpoint = Self.fakeEndpoint()
        let sessionID = UUID()
        let paneID = UUID()
        let after = Self.payload(sessions: [Self.leafSession(id: sessionID, path: Self.samplePath, paneID: paneID)])

        let outcome = NewSessionCommand.pollForNewSession(
            path: Self.samplePath,
            snapshot: Self.emptySnapshot(),
            maxAttempts: 3,
            interval: 0,
            resolveEndpoint: { endpoint },
            fetchTopology: { _ in .success(after) }
        )

        guard case .found(let match) = outcome else {
            Issue.record("expected .found, got \(outcome)")
            return
        }
        #expect(match.sessionID == sessionID)
        #expect(match.paneID == paneID)
    }

    /// `matches.count > 1` every attempt — the cold-launch `$HOME`
    /// collision, simultaneous case — persists to the bound: exits the
    /// loop `.timedOut` with `sawAmbiguousMatch: true`, not `.found` with
    /// either candidate's id.
    @Test func staysAmbiguousUntilTheBoundExpires() {
        let endpoint = Self.fakeEndpoint()
        let defaultSessionID = UUID()
        let requestedSessionID = UUID()
        let after = Self.payload(sessions: [
            Self.leafSession(id: defaultSessionID, path: Self.samplePath),
            Self.leafSession(id: requestedSessionID, path: Self.samplePath),
        ])

        let outcome = NewSessionCommand.pollForNewSession(
            path: Self.samplePath,
            snapshot: Self.emptySnapshot(),
            maxAttempts: 3,
            interval: 0,
            resolveEndpoint: { endpoint },
            fetchTopology: { _ in .success(after) }
        )

        guard case .timedOut(let endpointEverSeen, let sawAmbiguousMatch) = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            return
        }
        #expect(endpointEverSeen == true)
        #expect(sawAmbiguousMatch == true)
    }

    /// Ambiguity that later resolves: the first attempt sees both the
    /// default Session and the requested Session matching (e.g. both
    /// happened to report their OSC 7 cwd before the first poll), a later
    /// attempt sees only the requested Session still qualifying (the
    /// default Session's path having since changed, or — more realistically
    /// — this models any transient double-match that clears without ever
    /// implying the *default* Session was the answer). `pollForNewSession`
    /// must keep polling through the ambiguous attempt and return `.found`
    /// with the **requested** Session once it resolves, not get stuck
    /// `.timedOut` and not latch onto the wrong id from the ambiguous
    /// attempt.
    @Test func matchesCorrectSessionOnceAmbiguityResolves() {
        let endpoint = Self.fakeEndpoint()
        let defaultSessionID = UUID()
        let requestedSessionID = UUID()
        let requestedPaneID = UUID()
        let ambiguous = Self.payload(sessions: [
            Self.leafSession(id: defaultSessionID, path: Self.samplePath),
            Self.leafSession(id: requestedSessionID, path: Self.samplePath, paneID: requestedPaneID),
        ])
        let resolved = Self.payload(sessions: [
            Self.leafSession(id: requestedSessionID, path: Self.samplePath, paneID: requestedPaneID),
        ])

        var attempt = 0
        let outcome = NewSessionCommand.pollForNewSession(
            path: Self.samplePath,
            snapshot: Self.emptySnapshot(),
            maxAttempts: 5,
            interval: 0,
            resolveEndpoint: { endpoint },
            fetchTopology: { _ in
                attempt += 1
                return .success(attempt == 1 ? ambiguous : resolved)
            }
        )

        guard case .found(let match) = outcome else {
            Issue.record("expected .found, got \(outcome)")
            return
        }
        #expect(match.sessionID == requestedSessionID)
        #expect(match.paneID == requestedPaneID)
    }

    /// #0380 round 4 review, B1 residual probe (the reviewer's own name for
    /// this test, kept verbatim): a cold launch's default Session can have
    /// its path resolve to the requested path (`$HOME`) while the
    /// requested Session has not appeared in topology *at all* yet — every
    /// attempt sees only the default Session as a candidate, so
    /// `matches.count == 1` throughout and `pollForNewSession` has no
    /// ambiguity to detect. This **passes today**, and is meant to: it
    /// demonstrates, rather than merely asserts in prose, the residual the
    /// round-4 pinned decision in `issues/0380.md` accepts — the
    /// simultaneous-collision guard (round 3, B1) narrows the cold-launch
    /// `$HOME` defect but does not close the sequential-ordering case. If
    /// this test ever starts failing (i.e. `pollForNewSession` stops
    /// returning the default Session here), the pinned decision and the
    /// Gotchas entry describing this residual need updating to match,
    /// not the other way around.
    @Test func singleTransientDefaultSessionMatchIsStillReturned() {
        let endpoint = Self.fakeEndpoint()
        let defaultSessionID = UUID()
        let defaultPaneID = UUID()
        // The requested Session never appears — models both orderings the
        // pinned decision names: the URL not yet delivered, and the URL
        // dropped outright (#0251).
        let after = Self.payload(sessions: [Self.leafSession(id: defaultSessionID, path: Self.samplePath, paneID: defaultPaneID)])

        let outcome = NewSessionCommand.pollForNewSession(
            path: Self.samplePath,
            snapshot: Self.emptySnapshot(),
            maxAttempts: 3,
            interval: 0,
            resolveEndpoint: { endpoint },
            fetchTopology: { _ in .success(after) }
        )

        guard case .found(let match) = outcome else {
            Issue.record("expected .found (the accepted residual — see issues/0380.md), got \(outcome)")
            return
        }
        #expect(match.sessionID == defaultSessionID)
        #expect(match.paneID == defaultPaneID)
    }
}
