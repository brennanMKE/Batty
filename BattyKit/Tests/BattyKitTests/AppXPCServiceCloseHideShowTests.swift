// AppXPCServiceCloseHideShowTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `AppXPCService.perform`'s `sessionClose`/`paneHide`/`paneShow`
/// cases (#0382 review round 1, finding B1) — the only tests anywhere in
/// `BattyKitTests` that exercise these three verbs through the real
/// `AppXPCService.perform` dispatcher rather than only the `AppStateStore`
/// methods (`closeSessionForXPC`/`hidePaneForXPC`/`showPaneForXPC`) it
/// calls. Round 1 shipped with zero coverage at this layer: a reviewer
/// mutation that collapsed `paneHide`'s `case .hidden, .alreadyHidden:`
/// success branch so `.alreadyHidden` resolved the generic `"unknown pane
/// id"` failure reply — turning idempotent `pane hide` on an
/// already-hidden Pane into exit `4` with the wrong message — passed the
/// entire 1418-test suite, because nothing exercised the verb-string ->
/// `AppStateStore` outcome -> `XPCResponse` mapping, or the *distinctness*
/// of the stderr-facing error strings the issue pins ("distinct stderr
/// messages for each cause so an agent can act on them").
///
/// Follows `AppXPCServicePaneSplitUniqueTests`'s round-2 pattern exactly:
/// `AppXPCService.perform` hardcodes `AppStateStore.shared` (not an
/// injectable store), so every test here gives itself its own Session via
/// `AppStateStore.shared.addSession(title:)!` rather than touching
/// `sessions[0]`, and no `.serialized` is needed since no two tests share
/// a Session.
///
/// **`SessionCloseOutcome.needsConfirmation`** is covered at this layer too
/// (#0398, `performSessionCloseWithABusyTabReturnsNeedsConfirmationFailure`)
/// via `TabRuntime.needsConfirmCloseOverride` — the polyfill still hard-codes
/// the real `needsConfirmClose` signal to `false`
/// (`TerminalViewState+Polyfill.swift`), so this remains unreachable against
/// a live process, but the seam makes the verb-string -> outcome ->
/// `XPCResponse` mapping (and its error string) testable regardless.
///
/// **Not covered at this layer**: `.refusedLastSession` — forcing the
/// *entire app-wide* `.shared` singleton down to exactly one Session would
/// disturb every other test's Sessions running against the same
/// process-wide store, unsafe to construct here. That *outcome* is covered
/// at the `AppStateStore` layer by `AppStateStoreCloseSessionForXPCTests`,
/// which exercises `closeSessionForXPC` directly against a throwaway
/// `AppStateStore()`. Its error string is not: that lives in
/// `AppXPCService.swift`, and `"refusing to close the app's last session"`
/// is pinned nowhere.
struct AppXPCServiceCloseHideShowTests {

    private func performSessionClose(_ request: SessionCloseRequest) async throws -> XPCResponse {
        try await perform(verb: XPCVerb.sessionClose, payload: try JSONEncoder().encode(request))
    }

    private func performPaneHide(_ request: PaneHideRequest) async throws -> XPCResponse {
        try await perform(verb: XPCVerb.paneHide, payload: try JSONEncoder().encode(request))
    }

    private func performPaneShow(_ request: PaneShowRequest) async throws -> XPCResponse {
        try await perform(verb: XPCVerb.paneShow, payload: try JSONEncoder().encode(request))
    }

    private func perform(verb: String, payload: Data) async throws -> XPCResponse {
        let service = AppXPCService()
        let requestData = try JSONEncoder().encode(XPCRequest(verb: verb, payload: payload))
        let responseData: Data = await withCheckedContinuation { continuation in
            service.perform(requestData) { data in
                continuation.resume(returning: data)
            }
        }
        return try JSONDecoder().decode(XPCResponse.self, from: responseData)
    }

    // MARK: - pane hide: idempotence must resolve `ok: true`, not a failure
    // (the exact case the reviewer's mutation broke)

    @Test func performPaneHideOnAnAlreadyHiddenPaneReturnsOK() async throws {
        let session = AppStateStore.shared.addSession(title: "AppXPCServiceCloseHideShowTests-hide-already-hidden")!
        let paneA = session.tree.allPanes[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        AppStateStore.shared.hidePane(id: paneB.id)
        #expect(paneB.isHidden, "precondition: paneB starts hidden")

        let response = try await performPaneHide(PaneHideRequest(paneID: paneB.id))

        #expect(response.ok == true, "hiding an already-hidden pane must succeed quietly (idempotent), not fail")
        #expect(response.error == nil)
        _ = try JSONDecoder().decode(PaneHideReply.self, from: try #require(response.payload))
        #expect(paneB.isHidden)
        #expect(!paneA.isHidden)
    }

    @Test func performPaneHideHidesAVisiblePane() async throws {
        let session = AppStateStore.shared.addSession(title: "AppXPCServiceCloseHideShowTests-hide-visible")!
        let paneA = session.tree.allPanes[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        #expect(!paneB.isHidden, "precondition: paneB starts visible")

        let response = try await performPaneHide(PaneHideRequest(paneID: paneB.id))

        #expect(response.ok == true)
        #expect(paneB.isHidden, "the actual mutation must have run through this seam, not just returned success")
        #expect(!paneA.isHidden)
    }

    @Test func performPaneHideWithStalePaneIDReturnsUnknownPaneIDFailure() async throws {
        let response = try await performPaneHide(PaneHideRequest(paneID: UUID()))

        #expect(response.ok == false)
        #expect(response.error == "unknown pane id")
    }

    @Test func performPaneHideOnASessionsLastVisiblePaneRefusesWithADistinctMessage() async throws {
        let session = AppStateStore.shared.addSession(title: "AppXPCServiceCloseHideShowTests-hide-last-visible")!
        let onlyPane = session.tree.allPanes[0]

        let response = try await performPaneHide(PaneHideRequest(paneID: onlyPane.id))

        #expect(response.ok == false)
        #expect(response.error == "refusing to hide the session's last visible pane",
                "must be distinct from the stale-id message above so an agent can tell the two causes apart")
        #expect(!onlyPane.isHidden, "a refused hide must leave the pane visible")
    }

    // MARK: - pane show: idempotence must resolve `ok: true`, not a failure

    @Test func performPaneShowOnAnAlreadyVisiblePaneReturnsOK() async throws {
        let session = AppStateStore.shared.addSession(title: "AppXPCServiceCloseHideShowTests-show-already-visible")!
        let onlyPane = session.tree.allPanes[0]
        #expect(!onlyPane.isHidden, "precondition: onlyPane starts visible")

        let response = try await performPaneShow(PaneShowRequest(paneID: onlyPane.id))

        #expect(response.ok == true, "showing an already-visible pane must succeed quietly (idempotent), not fail")
        #expect(response.error == nil)
        _ = try JSONDecoder().decode(PaneShowReply.self, from: try #require(response.payload))
        #expect(!onlyPane.isHidden)
    }

    @Test func performPaneShowShowsAHiddenPane() async throws {
        let session = AppStateStore.shared.addSession(title: "AppXPCServiceCloseHideShowTests-show-hidden")!
        let paneA = session.tree.allPanes[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        AppStateStore.shared.hidePane(id: paneB.id)
        #expect(paneB.isHidden, "precondition: paneB starts hidden")

        let response = try await performPaneShow(PaneShowRequest(paneID: paneB.id))

        #expect(response.ok == true)
        #expect(!paneB.isHidden, "the actual mutation must have run through this seam, not just returned success")
        #expect(!paneA.isHidden)
    }

    @Test func performPaneShowWithStalePaneIDReturnsUnknownPaneIDFailure() async throws {
        let response = try await performPaneShow(PaneShowRequest(paneID: UUID()))

        #expect(response.ok == false)
        #expect(response.error == "unknown pane id")
    }

    // MARK: - session close

    @Test func performSessionCloseClosesANonLastSession() async throws {
        // `addSession` itself guarantees the app-wide session count is at
        // least two by the time this runs (the seeded session plus this
        // new one, on top of whatever other tests already left on
        // `.shared`), so the last-session guard can never spuriously
        // refuse this close regardless of test execution order. Asserted
        // by presence/absence of this specific session only — an
        // aggregate before/after session *count* comparison would be
        // racy against `.shared` under Swift Testing's parallel
        // execution, since sibling tests (in this file and others) add
        // and remove their own sessions on the same singleton
        // concurrently.
        let session = AppStateStore.shared.addSession(title: "AppXPCServiceCloseHideShowTests-session-close")!
        #expect(AppStateStore.shared.windows.contains { window in window.sessions.contains { $0.id == session.id } },
                "precondition: the session exists before the close")

        let response = try await performSessionClose(SessionCloseRequest(sessionID: session.id))

        #expect(response.ok == true)
        #expect(response.error == nil)
        _ = try JSONDecoder().decode(SessionCloseReply.self, from: try #require(response.payload))
        #expect(!AppStateStore.shared.windows.contains { window in window.sessions.contains { $0.id == session.id } },
                "the actual mutation must have run through this seam, not just returned success")
    }

    @Test func performSessionCloseWithStaleSessionIDReturnsUnknownSessionIDFailure() async throws {
        let response = try await performSessionClose(SessionCloseRequest(sessionID: UUID()))

        #expect(response.ok == false)
        #expect(response.error == "unknown session id")
    }

    /// #0398: `.needsConfirmation` is no longer unreachable at this layer
    /// either — `TabRuntime.needsConfirmCloseOverride` forces the signal on
    /// this session's own tab, so the full `verb string -> AppStateStore
    /// outcome -> XPCResponse` mapping this file exists to cover (see the
    /// doc comment above) now includes the refusal path too, error string
    /// included.
    @Test func performSessionCloseWithABusyTabReturnsNeedsConfirmationFailure() async throws {
        let session = AppStateStore.shared.addSession(title: "AppXPCServiceCloseHideShowTests-session-close-busy")!
        let tab = session.tree.allPanes[0].tabs[0]
        tab.needsConfirmCloseOverride = true
        // #0398 review round 1, N2: a refused close is a *permanently*
        // busy Session by design — left as-is, it survives on
        // `AppStateStore.shared` for the rest of the test process (this
        // file's own doc comment above cites exactly that hazard for
        // `.refusedLastSession`). Clear the override and actually close it
        // so nothing lands on a future test sweeping the shared store.
        defer {
            tab.needsConfirmCloseOverride = nil
            _ = AppStateStore.shared.closeSessionForXPC(id: session.id)
        }

        let response = try await performSessionClose(SessionCloseRequest(sessionID: session.id))

        #expect(response.ok == false)
        #expect(response.error == "session has a running process; close refused without confirmation")
        #expect(AppStateStore.shared.windows.contains { window in window.sessions.contains { $0.id == session.id } },
                "a refused close must leave the session untouched")
    }
}
