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
/// **The confirmation-*refusal* branch of `requestRemoveSession`** (raising
/// `PendingCloseRequest` instead of closing immediately) used to be
/// uncoverable here: `TerminalViewState.needsConfirmClose` is hard-coded
/// `false` by `TerminalViewState+Polyfill.swift` for every real
/// `TerminalViewState` — a class from the external `libghostty-spm`
/// package, not mockable directly. #0398 added
/// `TabRuntime.needsConfirmCloseOverride`, an indirection one layer up that
/// every one of the seven `needsConfirmClose` call sites now reads instead
/// of `terminal.needsConfirmClose` directly, so
/// `requestRemoveSessionWithABusyTabRaisesAConfirmationInsteadOfClosing`
/// below exercises the busy-tab sweep for real. This does not change
/// production behavior — the polyfill is untouched, and no real
/// `TerminalViewState` can ever set the override — only which branches are
/// unit-testable.
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

    /// Adds a Session via `AppStateStore.addSession` (so it starts as a
    /// real Session would, with the default single `.terminal` pane), then
    /// reshapes it to hold exactly one non-terminal `.systemMetrics` pane —
    /// splitting one off and removing the original terminal pane — so a
    /// test naming a non-terminal-Pane scenario actually exercises a
    /// non-terminal pane rather than the terminal one `addSession`
    /// produces by default.
    private func addNonTerminalOnlySession(to store: AppStateStore, title: String) -> (session: SessionRuntime, paneID: UUID) {
        let session = store.addSession(title: title)!
        let terminalPaneID = session.tree.allPanes[0].id
        let nonTerminalPane = session.tree.splitPane(id: terminalPaneID, direction: .horizontal, kind: .systemMetrics, isSessionSelected: true)!
        session.tree.removePane(id: terminalPaneID)
        return (session, nonTerminalPane.id)
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
        #expect(recorder.payloads.first?.fromCli == false, "the GUI caller (closeNonTerminalPane) keeps the default")
    }

    // MARK: - closePane's fromCli threading (#0396 review round 1, B1)
    //
    // WindowRuntime.closePane has no GUI caller that empties a Session in
    // practice (closeNonTerminalPane's non-terminal pane always has
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

    /// Drives the exact call `PaneView.paneCloseButton` makes —
    /// `PaneView.performPaneClose(paneID:in:)` — rather than reaching past
    /// the view layer to call `AppStateStore.closeNonTerminalPane(id:)`
    /// directly. A prior version of this test called the store method
    /// directly and stayed green even when the button's own call site
    /// regressed to `AppStateStore.closePane(id:)` (the XPC verb, `fromCli:
    /// true`) — nothing in the suite reached through the view layer to the
    /// store call the button actually makes. This version pins that
    /// routing decision itself: a GUI click that happens to empty its
    /// Session must never be reported as CLI-driven. Mirrors
    /// `appStateStoreClosePaneEmitsWithFromCliTrueWhenItEmptiesTheSession`
    /// with the opposite expectation.
    @Test func paneViewPerformPaneCloseEmitsWithFromCliFalseWhenItEmptiesTheSession() {
        let store = AppStateStore()
        let (secondSession, paneID) = addNonTerminalOnlySession(to: store, title: "Second")
        let recorder = EventRecorder()
        defer { recorder.stop() }

        let outcome = PaneView.performPaneClose(paneID: paneID, in: store)

        #expect(outcome == .closed)
        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads.first?.sessionID == secondSession.id)
        #expect(recorder.payloads.first?.fromCli == false)
    }

    /// #0378: ⌘W on a non-terminal Pane
    /// (`WindowRuntime.closeFocusedTab()`) and the header's close button
    /// must agree about the app's last Pane — both use `closeNonTerminalPane`,
    /// which always passes `refuseIfAppsLastPane: false` (#0334's
    /// contract), unlike the XPC `batty pane close` verb
    /// (`AppStateStore.closePane(id:)`), which still refuses. Both calls
    /// target the same pane in the same store to prove the two entry
    /// points now differ only where they should: the first call is a
    /// non-mutating refusal (`WindowRuntime.closePane` returns
    /// `.refusedLastPane` before touching the tree), so the pane is still
    /// there for the second call to actually close.
    @Test func appStateStoreCloseNonTerminalPaneClosesTheAppsOnlyPaneWhereClosePaneWouldRefuse() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let terminalPaneID = session.tree.allPanes[0].id
        let paneID = session.tree.splitPane(id: terminalPaneID, direction: .horizontal, kind: .systemMetrics, isSessionSelected: true)!.id
        session.tree.removePane(id: terminalPaneID)
        #expect(store.sessions.reduce(0) { $0 + $1.tree.allPanes.count } == 1, "precondition: this is the app's only pane")
        #expect(session.tree.allPanes[0].kind == .systemMetrics, "precondition: that pane is non-terminal")

        #expect(store.closePane(id: paneID) == .refusedLastPane, "the XPC verb still refuses the app's last pane")
        #expect(store.closeNonTerminalPane(id: paneID) == .closed, "the GUI close button must not refuse, matching ⌘W's #0334 contract")
    }

    // MARK: - requestRemoveSession (the Sidebar's confirmation-gated entry point)

    @Test func requestRemoveSessionClosesImmediatelyWhenNothingNeedsConfirmation() {
        // Every real TabRuntime reports needsConfirmClose == false today
        // against a live TerminalViewState (the polyfill) — this is the
        // branch of requestRemoveSession a real surface can reach. The
        // dialog branch below is reachable only via the #0398 test seam.
        let (window, session) = makeWindow()
        let recorder = EventRecorder()
        defer { recorder.stop() }

        window.requestRemoveSession(id: session.id)

        #expect(window.sessions.isEmpty)
        #expect(window.pendingCloseRequest == nil)
        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads.first?.sessionID == session.id)
    }

    /// #0398: forcing `TabRuntime.needsConfirmCloseOverride` drives the
    /// busy-tab sweep this type doc comment used to call unreachable by
    /// construction. Review round 1, B1b: uses `makeTwoSessionWindow()`,
    /// not `makeWindow()` — a single-Session fixture makes
    /// `sessionID == session.id` true for *any* id the code happens to
    /// emit (this file's own fixture doc above says so), so `target` at
    /// index 1 is the one flipped busy and asserted, with `bystander`
    /// checked absent to make a mutation that names the wrong session fail
    /// loudly. Non-default fixture: the tab starts idle and is flipped
    /// busy explicitly, then the session must still be present and no
    /// event must have fired — a no-op dialog raise looks identical to a
    /// silently-skipped sweep unless both are asserted. Also pins the
    /// dialog message (#0398 review round 1, N1) — #0396's Gotchas noted
    /// this message, with a real Session title interpolated, "has never
    /// been seen"; this is now assertable at the model layer.
    @Test func requestRemoveSessionWithABusyTabRaisesAConfirmationInsteadOfClosing() {
        let (window, bystander, target) = makeTwoSessionWindow()
        target.tree.allPanes[0].tabs[0].needsConfirmCloseOverride = true
        let recorder = EventRecorder()
        defer { recorder.stop() }

        window.requestRemoveSession(id: target.id)

        #expect(window.sessions.contains { $0.id == target.id }, "a busy session must not close before confirmation")
        #expect(recorder.payloads.isEmpty, "no session_destroyed until the dialog is confirmed")
        guard case .session(let sessionID) = window.pendingCloseRequest?.kind else {
            Issue.record("expected requestRemoveSession to raise a .session pending close request")
            return
        }
        #expect(sessionID == target.id)
        #expect(sessionID != bystander.id)
        #expect(window.pendingCloseRequest?.message == "Target has a tab that is still running a process. Closing it will end that process.")
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
        // through requestRemoveSession's busy-tab sweep (covered separately
        // by requestRemoveSessionWithABusyTabRaisesAConfirmationInsteadOfClosing
        // above) — this isolates and pins the new switch case in
        // confirmPendingClose() itself: given a pending .session request,
        // confirming it must call removeSession(id:), not leave the
        // session in place.
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
