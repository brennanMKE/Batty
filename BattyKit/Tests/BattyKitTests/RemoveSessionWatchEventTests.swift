// RemoveSessionWatchEventTests.swift

import Foundation
import Testing
@testable import BattyKit

/// #0396: `WindowRuntime.removeSession(id:)` was the only Session-removal
/// path that neither gated on `needsConfirmClose` nor emitted
/// `session_destroyed` — while its siblings (`requestCloseTab`,
/// `closePane`) did the first and `AppStateStore.removeSession` did the
/// second. This suite pins the fix: `session_destroyed` now emits from
/// `WindowRuntime.removeSession` itself (the single choke point every
/// removal path funnels through — Sidebar via `requestRemoveSession`, the
/// `closeTab`/`closePane` cascades, and `AppStateStore`/XPC), fires exactly
/// once per removal, never fires for an unknown id (the phantom-event
/// defect the old `AppStateStore`-level emission had), and carries
/// `fromCli` correctly — including for `closePane`, whose only
/// Session-emptying production caller (`AppStateStore.closePane(id:)`) is
/// itself the XPC `batty pane close` verb, not a GUI path (review round 1,
/// B1).
///
/// Fixtures that assert a specific `sessionID` use `makeTwoSessionWindow()`
/// with the target at index 1, not `makeWindow()`'s single Session (review
/// round 1's fixture-thinness finding: a single-Session window makes
/// `sessionID == session.id` true for *any* id the code happens to emit).
///
/// **What this suite cannot cover**: the confirmation-*refusal* branch of
/// `requestRemoveSession` (raising `PendingCloseRequest` instead of closing
/// immediately). `TerminalViewState.needsConfirmClose` is hard-coded
/// `false` by `TerminalViewState+Polyfill.swift` for every real
/// `TerminalViewState` — a class from the external `libghostty-spm`
/// package, not mockable — so no `TabRuntime` in any test can ever report
/// "needs confirmation." The same hole already made
/// `PaneCloseOutcome.needsConfirmation`/`SessionCloseOutcome
/// .needsConfirmation` untestable in #0283/#0382. `confirmPendingCloseRoutesTheSessionCaseToRemoveSession`
/// below covers the *reachable* half of that plumbing instead: it injects
/// a `PendingCloseRequest(kind: .session(...))` directly (bypassing the
/// unreachable busy-tab detection) and confirms `confirmPendingClose()`
/// wires that case to `removeSession(id:)`.
@MainActor
struct RemoveSessionWatchEventTests {

    /// Records every `session_destroyed` delivery seen while subscribed,
    /// via `AppEventWatcher.shared` — the real singleton every production
    /// caller (`AppXPCService`) subscribes through. Always unsubscribes in
    /// `deinit`-style `defer` at each call site so a test never leaks a
    /// live subscription into a sibling test running later in the process.
    @MainActor
    private final class EventRecorder {
        private(set) var payloads: [WatchEventPayload] = []
        private var subscriptionID: UUID?

        init(events: [String] = ["session_destroyed"]) {
            subscriptionID = AppEventWatcher.shared.subscribe(events: events) { [weak self] payload in
                // `replyBlock` is `@Sendable` (it also serves XPC callers on
                // arbitrary queues), but `AppEventWatcher.send` is itself
                // `@MainActor`-isolated and calls it synchronously — every
                // delivery in this test suite genuinely happens on the main
                // actor, so this assumption always holds here.
                MainActor.assumeIsolated {
                    self?.payloads.append(payload)
                }
            }
        }

        func stop() {
            guard let subscriptionID else { return }
            AppEventWatcher.shared.unsubscribe(id: subscriptionID)
            self.subscriptionID = nil
        }
    }

    private func makeWindow() -> (window: WindowRuntime, session: SessionRuntime) {
        let session = SessionRuntime()
        let window = WindowRuntime(sessions: [session], bellFeed: BellFeedStore(), nameCache: SessionNameCache())
        return (window, session)
    }

    /// Two-Session fixture where the target is **not** `sessions[0]` —
    /// review round 1's fixture-thinness finding: every single-Session
    /// test's `sessionID` assertion is vacuous (any id in `sessions` would
    /// pass), and a mutation swapping the emitted payload for
    /// `sessions[0].id` was caught by exactly one test in the whole suite.
    /// Tests built on this fixture close `target` (index 1) and assert the
    /// payload names `target`, not `bystander`.
    private func makeTwoSessionWindow() -> (window: WindowRuntime, bystander: SessionRuntime, target: SessionRuntime) {
        let bystander = SessionRuntime(title: "Bystander")
        let target = SessionRuntime(title: "Target")
        let window = WindowRuntime(sessions: [bystander, target], bellFeed: BellFeedStore(), nameCache: SessionNameCache())
        return (window, bystander, target)
    }

    // MARK: - removeSession emits exactly once, for the right id

    @Test func removeSessionEmitsSessionDestroyedForTheClosedSessionID() {
        // Two-Session fixture (review round 1): target is sessions[1], so a
        // mutation that hard-codes sessions[0].id into the payload fails
        // this assertion instead of passing by fixture coincidence.
        let (window, bystander, target) = makeTwoSessionWindow()
        let recorder = EventRecorder()
        defer { recorder.stop() }

        window.removeSession(id: target.id)

        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads.first?.sessionID == target.id)
        #expect(recorder.payloads.first?.fromCli == false)
        #expect(window.sessions.map(\.id) == [bystander.id])
    }

    @Test func removeSessionDoesNotEmitForAnUnknownID() {
        // The phantom-event defect this pins: the old emission lived in
        // AppStateStore.removeSession and fired unconditionally, before
        // checking whether the id resolved to a real, owned session — an
        // unknown id emitted session_destroyed for a session that was
        // never destroyed. The emission now lives after WindowRuntime
        // .removeSession's own existence guard.
        let (window, _) = makeWindow()
        let recorder = EventRecorder()
        defer { recorder.stop() }

        window.removeSession(id: UUID())

        #expect(recorder.payloads.isEmpty, "an unknown id must not emit a phantom session_destroyed")
    }

    // MARK: - emission ordering (round 2 review, N1)

    /// Watches `session_destroyed` and records, at the moment of delivery,
    /// whether `targetID` is still present in `window.sessions` — pins the
    /// doc comment's claim ("notify the active XPC watchers before
    /// mutating") rather than leaving it an unchecked comment. Round 2
    /// review moved the emission to the end of `removeSession` and the
    /// suite stayed fully green with no other test noticing.
    @MainActor
    private final class OrderingProbe {
        private(set) var targetStillPresentAtDelivery: Bool?
        private let window: WindowRuntime
        private let targetID: UUID
        private var subscriptionID: UUID?

        init(window: WindowRuntime, targetID: UUID) {
            self.window = window
            self.targetID = targetID
            subscriptionID = AppEventWatcher.shared.subscribe(events: ["session_destroyed"]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.targetStillPresentAtDelivery = self.window.sessions.contains { $0.id == self.targetID }
                }
            }
        }

        func stop() {
            guard let subscriptionID else { return }
            AppEventWatcher.shared.unsubscribe(id: subscriptionID)
            self.subscriptionID = nil
        }
    }

    @Test func removeSessionEmitsBeforeMutatingSessionsArray() {
        let (window, _, target) = makeTwoSessionWindow()
        let probe = OrderingProbe(window: window, targetID: target.id)
        defer { probe.stop() }

        window.removeSession(id: target.id)

        #expect(
            probe.targetStillPresentAtDelivery == true,
            "session_destroyed must fire before removeSession removes the Session from window.sessions"
        )
    }

    // MARK: - fromCli threading

    @Test func removeSessionDefaultsFromCliToFalse() {
        let (window, session) = makeWindow()
        let recorder = EventRecorder()
        defer { recorder.stop() }

        window.removeSession(id: session.id)

        #expect(recorder.payloads.first?.fromCli == false)
    }

    @Test func removeSessionPassesThroughAnExplicitFromCliTrue() {
        let (window, session) = makeWindow()
        let recorder = EventRecorder()
        defer { recorder.stop() }

        window.removeSession(id: session.id, fromCli: true)

        #expect(recorder.payloads.first?.fromCli == true)
    }

    // MARK: - AppStateStore.removeSession forwards without double-emitting

    @Test func appStateStoreRemoveSessionEmitsExactlyOnce() {
        // Guards against the double-emit the issue warned about: before
        // this fix, AppStateStore.removeSession emitted its own copy and
        // then called WindowRuntime.removeSession, which (after this fix)
        // also emits — a naive fix that added the WindowRuntime emission
        // without deleting the AppStateStore one would fire twice.
        let store = AppStateStore()
        let session = store.sessions[0]
        _ = store.addSession(title: "Second") // avoid the last-session path being relevant here
        let recorder = EventRecorder()
        defer { recorder.stop() }

        store.removeSession(id: session.id)

        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads.first?.sessionID == session.id)
    }

    @Test func closeSessionForXPCEmitsWithFromCliTrue() {
        let store = AppStateStore()
        let firstSession = store.sessions[0]
        let secondSession = store.addSession(title: "Second")!
        let recorder = EventRecorder()
        defer { recorder.stop() }

        let outcome = store.closeSessionForXPC(id: secondSession.id)

        #expect(outcome == .closed)
        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads.first?.sessionID == secondSession.id)
        #expect(recorder.payloads.first?.fromCli == true)
        _ = firstSession
    }

    // MARK: - Cascades (closeTab / closePane emptying a Session's tree)
    // must emit too — the issue's "CLI-origin cascade hole" and the
    // GUI-origin equivalent both route through removeSession, so both are
    // fixed by the same change.

    @Test func closeTabCascadeThatEmptiesTheTreeEmitsSessionDestroyed() {
        // Two-Session fixture (review round 1): closes the second Session's
        // only tab, leaving the first (`bystander`) alone — a mutation that
        // reports `sessions[0].id` (the bystander) instead of the actual
        // target fails both the payload assertion and the survivor check.
        let (window, bystander, target) = makeTwoSessionWindow()
        let onlyTabID = target.tree.allPanes[0].tabs[0].id
        let recorder = EventRecorder()
        defer { recorder.stop() }

        window.closeTab(id: onlyTabID)

        #expect(window.sessions.map(\.id) == [bystander.id])
        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads.first?.sessionID == target.id)
        #expect(recorder.payloads.first?.fromCli == false, "closeTab's cascade is GUI/PTY-origin only")
    }

    @Test func closePaneCascadeThatEmptiesTheTreeEmitsSessionDestroyed() {
        // Two-Session fixture (review round 1), same shape as the closeTab
        // test above.
        let (window, bystander, target) = makeTwoSessionWindow()
        let onlyPaneID = target.tree.allPanes[0].id
        let recorder = EventRecorder()
        defer { recorder.stop() }

        let outcome = window.closePane(id: onlyPaneID, refuseIfAppsLastPane: false)

        #expect(outcome == .closed)
        #expect(window.sessions.map(\.id) == [bystander.id])
        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads.first?.sessionID == target.id)
        #expect(recorder.payloads.first?.fromCli == false, "the GUI caller (closeFocusedNonTerminalPane) keeps the default")
    }

    // MARK: - closePane's fromCli threading (#0396 review round 1, B1)
    //
    // WindowRuntime.closePane has no GUI caller that empties a Session in
    // practice (closeFocusedNonTerminalPane's non-terminal pane always has
    // a sibling in the fixtures above); AppStateStore.closePane(id:) is the
    // one call site that does, and it is exclusively the XPC `batty pane
    // close` verb (see that method's doc comment) — so a pane close that
    // empties its Session must report fromCli: true.

    @Test func windowRuntimeClosePaneDefaultsFromCliToFalse() {
        let (window, _, target) = makeTwoSessionWindow()
        let onlyPaneID = target.tree.allPanes[0].id
        let recorder = EventRecorder()
        defer { recorder.stop() }

        _ = window.closePane(id: onlyPaneID, refuseIfAppsLastPane: false)

        #expect(recorder.payloads.first?.fromCli == false)
    }

    @Test func windowRuntimeClosePanePassesThroughAnExplicitFromCliTrue() {
        let (window, _, target) = makeTwoSessionWindow()
        let onlyPaneID = target.tree.allPanes[0].id
        let recorder = EventRecorder()
        defer { recorder.stop() }

        _ = window.closePane(id: onlyPaneID, refuseIfAppsLastPane: false, fromCli: true)

        #expect(recorder.payloads.first?.fromCli == true)
    }

    @Test func appStateStoreClosePaneEmitsWithFromCliTrueWhenItEmptiesTheSession() {
        // Review round 1's B1 probe, verbatim shape: batty pane close on a
        // Session's last pane is CLI-origin end to end.
        let store = AppStateStore()
        let secondSession = store.addSession(title: "Second")!
        let recorder = EventRecorder()
        defer { recorder.stop() }

        let outcome = store.closePane(id: secondSession.tree.allPanes[0].id)

        #expect(outcome == .closed)
        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads.first?.sessionID == secondSession.id)
        #expect(recorder.payloads.first?.fromCli == true)
    }

    // MARK: - requestRemoveSession (the Sidebar's confirmation-gated entry point)

    @Test func requestRemoveSessionClosesImmediatelyWhenNothingNeedsConfirmation() {
        // Every real TabRuntime reports needsConfirmClose == false today
        // (the polyfill), so this is the only branch of
        // requestRemoveSession reachable by a live TerminalViewState.
        let (window, session) = makeWindow()
        let recorder = EventRecorder()
        defer { recorder.stop() }

        window.requestRemoveSession(id: session.id)

        #expect(window.sessions.isEmpty)
        #expect(window.pendingCloseRequest == nil)
        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads.first?.sessionID == session.id)
    }

    @Test func requestRemoveSessionOnAnUnknownIDIsANoOp() {
        let (window, _) = makeWindow()
        let recorder = EventRecorder()
        defer { recorder.stop() }

        window.requestRemoveSession(id: UUID())

        #expect(window.pendingCloseRequest == nil)
        #expect(recorder.payloads.isEmpty)
    }

    // MARK: - confirmPendingClose's new .session case

    @Test func confirmPendingCloseRoutesTheSessionCaseToRemoveSession() {
        // Injects the PendingCloseRequest directly rather than going
        // through requestRemoveSession's busy-tab sweep (unreachable, see
        // the type doc comment above) — this isolates and pins the new
        // switch case in confirmPendingClose() itself: given a pending
        // .session request, confirming it must call removeSession(id:),
        // not leave the session in place.
        let (window, session) = makeWindow()
        window.pendingCloseRequest = PendingCloseRequest(
            kind: .session(sessionID: session.id),
            message: "test"
        )
        let recorder = EventRecorder()
        defer { recorder.stop() }

        window.confirmPendingClose()

        #expect(window.sessions.isEmpty)
        #expect(window.pendingCloseRequest == nil)
        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads.first?.sessionID == session.id)
        // Round-2 review, N2: confirmPendingClose's .session case is a
        // dialog the user confirmed in the GUI, never an XPC call — this
        // must stay fromCli: false, not inherit true from anywhere.
        #expect(recorder.payloads.first?.fromCli == false)
    }

    @Test func pendingCloseRequestSessionKindHasTheExpectedTitle() {
        let request = PendingCloseRequest(kind: .session(sessionID: UUID()), message: "test")
        #expect(request.title == "Close session?")
    }
}
