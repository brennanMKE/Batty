// AppStateStoreCloseSessionForXPCTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `AppStateStore.closeSessionForXPC(id:)` — #0382's XPC `session
/// close` verb. Mirrors `AppStateStoreClosePaneTests`'s shape one tier up:
/// reuses `removeSession(id:)` for the actual mutation, wrapped with the
/// same needs-confirmation/refused-last refusal shape `closePane(id:)`
/// (#0283) already established for panes.
@MainActor
struct AppStateStoreCloseSessionForXPCTests {

    // MARK: - Ordinary close

    @Test func closingANonLastSessionRemovesItFromItsWindow() {
        let store = AppStateStore()
        let firstSession = store.sessions[0]
        let secondSession = store.addSession(title: "Second")!

        let outcome = store.closeSessionForXPC(id: secondSession.id)

        #expect(outcome == .closed)
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == firstSession.id)
    }

    /// #0398: `.needsConfirmation` was unreachable in any environment
    /// before `TabRuntime.needsConfirmCloseOverride` — the polyfill
    /// hard-codes the real signal to `false`, and this doc comment on
    /// `SessionCloseOutcome.needsConfirmation` said so outright. Non-default
    /// fixture: a second session so this isn't also the app's last one
    /// (which would confound the assertion with `.refusedLastSession`
    /// instead), and the tab starts idle before being flipped busy.
    @Test func closingASessionWithABusyTabIsRefused() {
        let store = AppStateStore()
        let firstSession = store.sessions[0]
        _ = store.addSession(title: "Second")!
        firstSession.tree.allPanes[0].tabs[0].needsConfirmCloseOverride = true

        let outcome = store.closeSessionForXPC(id: firstSession.id)

        #expect(outcome == .needsConfirmation)
        #expect(store.sessions.count == 2, "a refused close must leave every session untouched")
        #expect(store.sessions.contains { $0.id == firstSession.id })
    }

    @Test func closingAnUnknownSessionIDReturnsUnknownSession() {
        let store = AppStateStore()
        let sessionsBefore = store.sessions.count

        let outcome = store.closeSessionForXPC(id: UUID())

        #expect(outcome == .unknownSession)
        #expect(store.sessions.count == sessionsBefore, "a stale id must leave every session untouched")
    }

    @Test func closeSessionForXPCResolvesASessionInANonKeyWindow() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())
        let target = w2.sessions[0]
        // A sibling session in w2 so closing `target` isn't also w2's last
        // session — this test is about cross-window resolution, not the
        // last-session refusal (covered separately below).
        _ = w2.addSession(title: "w2 sibling")

        let outcome = store.closeSessionForXPC(id: target.id)

        #expect(outcome == .closed)
        #expect(!w2.sessions.contains { $0.id == target.id })
    }

    // MARK: - Background-session close must not steal focus or switch the
    // active session (#0257, same discipline as #0283's pane-close tests)

    /// Review round 1 (B2): a 2-session fixture (selection on index 0,
    /// close index 1) passed under a mutation that inserted
    /// `window.selectedSessionID = sessionID` immediately before
    /// `removeSession(id: sessionID)` — precisely the slip of copying
    /// #0381's *activating* focus verbs into this *non-activating* verb.
    /// The mutation forces `selectedSessionID` onto the closed session's
    /// id, which trips `removeSession`'s own "reassign if the removed
    /// session was selected" branch: with the closed session at index 1
    /// (the last one), that branch's `max(0, index - 1)` fallback lands
    /// back on index 0 — the session that was *already* selected before
    /// the mutation ran — so the assertion held by coincidence, not
    /// because the mutation was actually caught.
    ///
    /// Fixed with 3 sessions and selection on the *last* one (`s3`),
    /// closing the *first* (`s1`): if the mutation force-selects `s1`
    /// before removal, `removeSession`'s fallback lands on `s2` (the new
    /// index-0 after `s1` leaves), which is neither `s3` (the real
    /// selection) nor `s1` (the closed session) — verified red under the
    /// mutation above, green without it.
    @Test func closingABackgroundSessionDoesNotChangeTheWindowsSelection() {
        let store = AppStateStore()
        let s1 = store.sessions[0]
        let s2 = store.addSession(title: "Second")!
        let s3 = store.addSession(title: "Third")!
        store.windows[0].selectedSessionID = s3.id

        let outcome = store.closeSessionForXPC(id: s1.id)

        #expect(outcome == .closed)
        #expect(store.windows[0].selectedSessionID == s3.id,
                "closing a background session must not change the window's selection")
        #expect(store.sessions.map(\.id) == [s2.id, s3.id])
    }

    @Test func closingTheSelectedSessionReassignsSelectionTheSameWayRemoveSessionAlwaysHas() {
        let store = AppStateStore()
        let firstSession = store.sessions[0]
        let secondSession = store.addSession(title: "Second")!
        store.windows[0].selectedSessionID = secondSession.id

        let outcome = store.closeSessionForXPC(id: secondSession.id)

        #expect(outcome == .closed)
        #expect(store.windows[0].selectedSessionID == firstSession.id,
                "closeSessionForXPC delegates to removeSession's existing reassignment rule unchanged")
    }

    // MARK: - Last session in the entire app: refused rather than walking
    // into #0217's silent-quit cascade with no human in the loop

    @Test func closingTheAppsVeryLastSessionIsRefused() {
        let store = AppStateStore()
        let onlySessionID = store.sessions[0].id

        let outcome = store.closeSessionForXPC(id: onlySessionID)

        #expect(outcome == .refusedLastSession)
        #expect(store.sessions.count == 1, "a refused close must leave the session untouched")
        #expect(store.sessions[0].id == onlySessionID)
    }

    @Test func closingTheLastSessionOfAWindowIsAllowedWhenAnotherWindowStillHasSessions() {
        let store = AppStateStore()
        let onlySessionID = store.sessions[0].id
        // A second window with its own session keeps the app-wide session
        // count above one, so the app-wide last-session guard does not
        // apply to this window's own only session.
        _ = store.windowRuntime(for: WindowID())

        let outcome = store.closeSessionForXPC(id: onlySessionID)

        #expect(outcome == .closed)
        #expect(store.windows[0].sessions.isEmpty)
    }

    @Test func totalSessionCountAcrossWindowsGatesTheRefusalNotPerWindowCount() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())
        // Two windows, two sessions total (one each) — closing either one
        // would leave exactly one session in the app, which must still be
        // allowed; only reaching zero is refused.
        #expect(store.sessions.count == 1)
        #expect(w2.sessions.count == 1)

        let outcome = store.closeSessionForXPC(id: store.sessions[0].id)

        #expect(outcome == .closed)
        #expect(store.windows[0].sessions.isEmpty)
        #expect(w2.sessions.count == 1, "the second window's session must be untouched")
    }
}
