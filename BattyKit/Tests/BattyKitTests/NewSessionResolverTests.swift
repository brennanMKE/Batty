// NewSessionResolverTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `NewSessionResolver` (#0380) — the pure "which Session did `batty
/// new` just create" logic, given a before/after topology pair. No XPC
/// connection, endpoint, or running app involved; every payload here is a
/// literal fixture.
struct NewSessionResolverTests {

    private static func leafSession(id: UUID, path: String?, paneID: UUID = UUID()) -> TopologySessionPayload {
        let tab = TopologyTabPayload(id: UUID(), title: "Tab", workingDirectory: path, isActive: true)
        let pane = TopologyPanePayload(id: paneID, isHidden: false, isFocused: true, activeTabID: tab.id, tabs: [tab], kind: .terminal)
        return TopologySessionPayload(id: id, name: "Session", path: path, isActive: false, focusedPaneID: paneID, root: .leaf(pane: pane))
    }

    private static func payload(windowID: UUID = UUID(), sessions: [TopologySessionPayload]) -> TopologyPayload {
        let window = TopologyWindowPayload(id: windowID, selectedSessionID: sessions.first?.id, sessions: sessions)
        return TopologyPayload(pid: 1, windows: [window])
    }

    @Test func findsANewSessionMatchingThePath() {
        let before = Self.payload(sessions: [])
        let newPaneID = UUID()
        let newSessionID = UUID()
        let after = Self.payload(sessions: [Self.leafSession(id: newSessionID, path: "/tmp/project", paneID: newPaneID)])

        let match = NewSessionResolver.findNewSession(before: before, after: after, path: "/tmp/project")

        #expect(match?.sessionID == newSessionID)
        #expect(match?.paneID == newPaneID)
    }

    /// The hard case named directly in the issue: the user already has a
    /// Session open on the same path when `batty new` runs. Path alone is
    /// not enough to identify the new one — only the pre-dispatch snapshot's
    /// id set can.
    @Test func samePathTwiceReturnsOnlyTheGenuinelyNewSession() {
        let existingSessionID = UUID()
        let existingPaneID = UUID()
        let before = Self.payload(sessions: [Self.leafSession(id: existingSessionID, path: "/tmp/project", paneID: existingPaneID)])

        let newSessionID = UUID()
        let newPaneID = UUID()
        let after = Self.payload(sessions: [
            Self.leafSession(id: existingSessionID, path: "/tmp/project", paneID: existingPaneID),
            Self.leafSession(id: newSessionID, path: "/tmp/project", paneID: newPaneID),
        ])

        let match = NewSessionResolver.findNewSession(before: before, after: after, path: "/tmp/project")

        #expect(match?.sessionID == newSessionID)
        #expect(match?.paneID == newPaneID)
    }

    @Test func returnsNilWhenNoSessionMatchesThePath() {
        let before = Self.payload(sessions: [])
        let after = Self.payload(sessions: [Self.leafSession(id: UUID(), path: "/tmp/other")])

        #expect(NewSessionResolver.findNewSession(before: before, after: after, path: "/tmp/project") == nil)
    }

    @Test func returnsNilWhenNothingChangedSinceBefore() {
        let sessionID = UUID()
        let session = Self.leafSession(id: sessionID, path: "/tmp/project")
        let before = Self.payload(sessions: [session])
        let after = Self.payload(sessions: [session])

        #expect(NewSessionResolver.findNewSession(before: before, after: after, path: "/tmp/project") == nil)
    }

    /// `TopologySessionPayload.path` is `nil` until it resolves — a new
    /// Session can appear before its path does. That must not match (and
    /// must not crash on the `nil` compare); the caller is expected to keep
    /// polling.
    @Test func skipsANewSessionWhosePathHasNotResolvedYet() {
        let before = Self.payload(sessions: [])
        let after = Self.payload(sessions: [Self.leafSession(id: UUID(), path: nil)])

        #expect(NewSessionResolver.findNewSession(before: before, after: after, path: "/tmp/project") == nil)
    }

    @Test func matchesAcrossMultipleWindows() {
        let before = Self.payload(sessions: [])
        let newSessionID = UUID()
        let newPaneID = UUID()
        let otherWindow = TopologyWindowPayload(id: UUID(), selectedSessionID: nil, sessions: [Self.leafSession(id: UUID(), path: "/tmp/unrelated")])
        let matchingWindow = TopologyWindowPayload(id: UUID(), selectedSessionID: newSessionID, sessions: [Self.leafSession(id: newSessionID, path: "/tmp/project", paneID: newPaneID)])
        let after = TopologyPayload(pid: 1, windows: [otherWindow, matchingWindow])

        let match = NewSessionResolver.findNewSession(before: before, after: after, path: "/tmp/project")

        #expect(match?.sessionID == newSessionID)
        #expect(match?.paneID == newPaneID)
    }

    /// #0380 round 1 review: `SessionURLBuilder.resolve` standardizes the CLI's
    /// path but does not resolve symlinks, while the Session's own `path`
    /// is eventually overwritten with libghostty's OSC 7 report — fully
    /// symlink-resolved (`getcwd()`). `/tmp` is a symlink into `/private/tmp`
    /// on macOS, so a Session reporting `/private/tmp/project` must still
    /// match a query for `/tmp/project`, not stall the poll to its bound.
    /// `URL.resolvingSymlinksInPath()` only actually resolves a path that
    /// exists on disk — an existing directory under `/tmp` is required to
    /// exercise the real behavior (`/tmp` and `/private/tmp` normalize to
    /// the same value only once the path is real; two spellings of a
    /// nonexistent path are left untouched and would falsely pass).
    @Test func matchesDespiteASymlinkResolvedSessionPath() throws {
        let tmpStylePath = "/tmp/batty-new-session-resolver-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpStylePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpStylePath) }
        let privateStylePath = "/private" + tmpStylePath

        let before = Self.payload(sessions: [])
        let newSessionID = UUID()
        let newPaneID = UUID()
        let after = Self.payload(sessions: [Self.leafSession(id: newSessionID, path: privateStylePath, paneID: newPaneID)])

        let match = NewSessionResolver.findNewSession(before: before, after: after, path: tmpStylePath)

        #expect(match?.sessionID == newSessionID)
        #expect(match?.paneID == newPaneID)
    }

    /// Review round 2 (B1): `matchesDespiteASymlinkResolvedSessionPath`
    /// above uses a *subdirectory* of `/tmp` — both spellings name a real,
    /// existing directory, so `URL(fileURLWithPath:)`'s stat-based
    /// trailing-slash logic appends a slash to both and they agree. That
    /// test structurally cannot catch the case where the path's *final
    /// component itself* is the symlink: `/tmp` is a symlink to
    /// `/private/tmp`, so the unresolved spelling stats the symlink (not a
    /// directory, per `URL(fileURLWithPath:)`'s own stat) and gets no
    /// trailing slash, while `/private/tmp` stats a real directory and
    /// does. `resolvingSymlinksInPath()` carries that mismatched flag
    /// through unchanged, so the two sides differ by a trailing `/` even
    /// after resolving. Confirmed on this machine to fail against the
    /// pre-fix `URL(fileURLWithPath:)` (no `isDirectory:`) implementation
    /// and pass once it becomes `URL(fileURLWithPath:isDirectory: true)`.
    @Test func matchesWhenTheFinalPathComponentIsItselfASymlink() {
        let before = Self.payload(sessions: [])
        let newSessionID = UUID()
        let newPaneID = UUID()
        let after = Self.payload(sessions: [Self.leafSession(id: newSessionID, path: "/private/tmp", paneID: newPaneID)])

        let match = NewSessionResolver.findNewSession(before: before, after: after, path: "/tmp")

        #expect(match?.sessionID == newSessionID)
        #expect(match?.paneID == newPaneID)
    }

    /// #0380 review round 2 (N6): the resolver's own doc comment promises
    /// "first match wins" when more than one Session in `after` qualifies
    /// (not expected in practice for a single `batty new`, but not
    /// structurally impossible if two agents raced on the same path) — pin
    /// that ordering contract with a case where two qualifying Sessions
    /// exist and the first one in `after.windows` order must be the one
    /// returned.
    @Test func firstQualifyingMatchWinsWhenMultipleSessionsQualify() {
        let before = Self.payload(sessions: [])
        let firstSessionID = UUID()
        let firstPaneID = UUID()
        let secondSessionID = UUID()
        let secondPaneID = UUID()
        let after = Self.payload(sessions: [
            Self.leafSession(id: firstSessionID, path: "/tmp/project", paneID: firstPaneID),
            Self.leafSession(id: secondSessionID, path: "/tmp/project", paneID: secondPaneID),
        ])

        let match = NewSessionResolver.findNewSession(before: before, after: after, path: "/tmp/project")

        #expect(match?.sessionID == firstSessionID)
        #expect(match?.paneID == firstPaneID)
    }

    /// #0380 round 3 review (B1): the exact `$HOME` collision scenario.
    /// A cold launch creates `Session 1` at `$HOME` (`WindowRuntime.init`)
    /// *and* the requested Session — both can qualify against an empty
    /// `before` snapshot once their paths resolve, since neither id was
    /// present beforehand. `findNewSessions` must surface both rather than
    /// silently resolving to one, so the caller (`NewSessionCommand`) can
    /// tell the difference between "found it" and "can't tell which one is
    /// new" instead of ever returning `Session 1`'s id for a `batty ~`
    /// request that actually wanted the freshly created one.
    @Test func returnsBothCandidatesWhenAColdLaunchDefaultSessionCollidesWithTheRequestedPath() {
        let before = Self.payload(sessions: [])
        let defaultSessionID = UUID()
        let defaultPaneID = UUID()
        let requestedSessionID = UUID()
        let requestedPaneID = UUID()
        let after = Self.payload(sessions: [
            Self.leafSession(id: defaultSessionID, path: "/Users/agent", paneID: defaultPaneID),
            Self.leafSession(id: requestedSessionID, path: "/Users/agent", paneID: requestedPaneID),
        ])

        let matches = NewSessionResolver.findNewSessions(before: before, after: after, path: "/Users/agent")

        #expect(matches.count == 2)
        #expect(matches.map(\.sessionID) == [defaultSessionID, requestedSessionID])
    }

    /// The unambiguous case `findNewSessions` must still handle correctly:
    /// exactly one qualifying Session comes back as a single-element array.
    @Test func findNewSessionsReturnsExactlyOneMatchWhenUnambiguous() {
        let before = Self.payload(sessions: [])
        let newSessionID = UUID()
        let newPaneID = UUID()
        let after = Self.payload(sessions: [Self.leafSession(id: newSessionID, path: "/tmp/project", paneID: newPaneID)])

        let matches = NewSessionResolver.findNewSessions(before: before, after: after, path: "/tmp/project")

        #expect(matches.count == 1)
        #expect(matches.first?.sessionID == newSessionID)
    }

    /// `findNewSession` (singular) must still degrade to "first match wins"
    /// on top of `findNewSessions` — existing behavior for callers that
    /// have already ruled out ambiguity.
    @Test func findNewSessionStillReturnsTheFirstQualifyingMatch() {
        let before = Self.payload(sessions: [])
        let defaultSessionID = UUID()
        let requestedSessionID = UUID()
        let after = Self.payload(sessions: [
            Self.leafSession(id: defaultSessionID, path: "/Users/agent"),
            Self.leafSession(id: requestedSessionID, path: "/Users/agent"),
        ])

        let match = NewSessionResolver.findNewSession(before: before, after: after, path: "/Users/agent")

        #expect(match?.sessionID == defaultSessionID)
    }

    /// The `--json` output shape (#0380's Expected behavior item 5):
    /// `{"sessionID": …, "paneID": …}` — same assertion style as
    /// `BattyIdentityContextTests.jsonTopLevelKeysAreStable`.
    @Test func jsonTopLevelKeysAreStable() throws {
        let match = NewSessionMatch(sessionID: UUID(), paneID: UUID())
        let data = try JSONEncoder().encode(match)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["sessionID", "paneID"])
    }
}
