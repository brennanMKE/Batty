// SessionClipboardConfirmationTests.swift

import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

/// `TerminalClipboardRequestKind` (upstream, `GhosttyTerminal`) has no
/// associated values and doesn't declare `Equatable`, so this compares by
/// switching rather than adding a retroactive conformance to an upstream
/// type.
private func isKind(_ actual: TerminalClipboardRequestKind?, _ expected: TerminalClipboardRequestKind) -> Bool {
    switch (actual, expected) {
    case (.paste, .paste), (.osc52Read, .osc52Read), (.osc52Write, .osc52Write):
        return true
    default:
        return false
    }
}

/// Covers #0390's per-Session, per-kind clipboard confirmation policy at
/// the model level — no live app or terminal surface required. The wrapper
/// side of the "exactly one of complete/deny fires for every request"
/// guarantee lives in libghostty-spm itself
/// (`TerminalClipboardConfirmationRequest`'s deinit backstop and
/// `TerminalCallbackBridge.denyAllPendingClipboardRequests()`); this covers
/// the Batty-side policy that decides *what* answer a request gets, and the
/// two Batty-side fail-open legs that would otherwise let a request through
/// with no explicit user allow.
///
/// Upstream's `TerminalClipboardConfirmationRequest` carries only `kind`
/// (no requesting-program name, no per-request `canRemember`), so this
/// policy can't name the program and always treats a request as
/// rememberable.
@MainActor
struct SessionClipboardConfirmationTests {
    @Test func firstRequestShowsAPendingConfirmation() {
        let session = SessionRuntime()
        var decisions: [Bool] = []

        session.requestClipboardReadConfirmation(kind: .osc52Read) { decisions.append($0) }

        #expect(isKind(session.pendingClipboardConfirmation?.kind, .osc52Read))
        #expect(decisions.isEmpty)
    }

    @Test func answeringAllowRemembersAndSuppressesLaterPromptsOfTheSameKind() {
        let session = SessionRuntime()
        var firstDecisions: [Bool] = []
        session.requestClipboardReadConfirmation(kind: .osc52Read) { firstDecisions.append($0) }
        let firstRequest = try! #require(session.pendingClipboardConfirmation)

        session.answerPendingClipboardConfirmation(firstRequest, allow: true)

        #expect(firstDecisions == [true])
        #expect(session.pendingClipboardConfirmation == nil)
        #expect(session.rememberedClipboardDecision(for: .osc52Read) == true)

        // A second request of the SAME kind in the same Session is answered
        // from the remembered per-kind decision without prompting again.
        var secondDecisions: [Bool] = []
        session.requestClipboardReadConfirmation(kind: .osc52Read) { secondDecisions.append($0) }

        #expect(session.pendingClipboardConfirmation == nil)
        #expect(secondDecisions == [true])
    }

    /// #0390 round 2, B1: a `Bool?` shared across all three
    /// `TerminalClipboardRequestKind` cases let an Allow on the
    /// benign-sounding `.osc52Write` prompt silently pre-authorize the
    /// exfiltration-risk `.osc52Read` request, and vice versa. Mirrors the
    /// reviewer's live probe: allow a `.osc52Write` request, then confirm
    /// both `.osc52Read` and `.paste` still prompt fresh.
    @Test func allowingOneKindDoesNotAuthorizeADifferentKind() {
        let session = SessionRuntime()
        session.requestClipboardReadConfirmation(kind: .osc52Write) { _ in }
        let writeRequest = try! #require(session.pendingClipboardConfirmation)
        session.answerPendingClipboardConfirmation(writeRequest, allow: true)

        #expect(session.rememberedClipboardDecision(for: .osc52Write) == true)
        #expect(session.rememberedClipboardDecision(for: .osc52Read) == nil)
        #expect(session.rememberedClipboardDecision(for: .paste) == nil)

        var readDecisions: [Bool] = []
        session.requestClipboardReadConfirmation(kind: .osc52Read) { readDecisions.append($0) }
        #expect(isKind(session.pendingClipboardConfirmation?.kind, .osc52Read))
        #expect(readDecisions.isEmpty)

        let readRequest = try! #require(session.pendingClipboardConfirmation)
        session.cancelPendingClipboardConfirmation(readRequest)

        var pasteDecisions: [Bool] = []
        session.requestClipboardReadConfirmation(kind: .paste) { pasteDecisions.append($0) }
        #expect(isKind(session.pendingClipboardConfirmation?.kind, .paste))
        #expect(pasteDecisions.isEmpty)
    }

    @Test func answeringDenyRemembersDenialForThatKindOnly() {
        let session = SessionRuntime()
        var firstDecisions: [Bool] = []
        session.requestClipboardReadConfirmation(kind: .osc52Read) { firstDecisions.append($0) }
        let firstRequest = try! #require(session.pendingClipboardConfirmation)
        session.answerPendingClipboardConfirmation(firstRequest, allow: false)

        #expect(firstDecisions == [false])
        #expect(session.rememberedClipboardDecision(for: .osc52Read) == false)
        // Not remembered for a different kind — a denied read must not
        // silently pre-deny (or pre-allow) an unrelated paste prompt.
        #expect(session.rememberedClipboardDecision(for: .paste) == nil)

        var secondDecisions: [Bool] = []
        session.requestClipboardReadConfirmation(kind: .osc52Read) { secondDecisions.append($0) }

        #expect(session.pendingClipboardConfirmation == nil)
        #expect(secondDecisions == [false])
    }

    @Test func aDifferentSessionHasIndependentPolicyAndPromptsAgain() {
        let sessionA = SessionRuntime(title: "A")
        let sessionB = SessionRuntime(title: "B")

        sessionA.requestClipboardReadConfirmation(kind: .osc52Read) { _ in }
        let requestA = try! #require(sessionA.pendingClipboardConfirmation)
        sessionA.answerPendingClipboardConfirmation(requestA, allow: true)
        #expect(sessionA.rememberedClipboardDecision(for: .osc52Read) == true)

        var decisionsB: [Bool] = []
        sessionB.requestClipboardReadConfirmation(kind: .osc52Read) { decisionsB.append($0) }

        #expect(sessionB.rememberedClipboardDecision(for: .osc52Read) == nil)
        #expect(isKind(sessionB.pendingClipboardConfirmation?.kind, .osc52Read))
        #expect(decisionsB.isEmpty)
    }

    @Test func dismissingWithoutAnAnswerDeniesRatherThanLeavingTheRequestUnresolved() {
        let session = SessionRuntime()
        var decisions: [Bool] = []
        session.requestClipboardReadConfirmation(kind: .osc52Read) { decisions.append($0) }
        let request = try! #require(session.pendingClipboardConfirmation)

        // e.g. Escape / click-outside on the confirmationDialog.
        session.cancelPendingClipboardConfirmation(request)

        #expect(session.pendingClipboardConfirmation == nil)
        #expect(decisions == [false])
        // A dismiss must never be remembered — it isn't the user
        // expressing a Session-wide policy, just closing the prompt.
        #expect(session.rememberedClipboardDecision(for: .osc52Read) == nil)
    }

    /// #0390 round 2, B2: a second request arriving while the first is
    /// still awaiting the user's answer must not leave the first hanging
    /// (surviving only on upstream's `deinit` backstop) or get silently
    /// dropped. It's resolved to deny, explicitly, the moment it's
    /// displaced.
    @Test func displacedRequestIsExplicitlyDeniedRatherThanLeftPending() {
        let session = SessionRuntime()
        var firstDecisions: [Bool] = []
        session.requestClipboardReadConfirmation(kind: .osc52Read) { firstDecisions.append($0) }

        var secondDecisions: [Bool] = []
        session.requestClipboardReadConfirmation(kind: .paste) { secondDecisions.append($0) }

        #expect(firstDecisions == [false])
        #expect(secondDecisions.isEmpty)
        #expect(isKind(session.pendingClipboardConfirmation?.kind, .paste))
    }

    /// #0390 round 2, B2: a view holding a reference to a request that has
    /// since been displaced (e.g. a stale button closure) must not be able
    /// to resolve whichever request happens to be pending *now* — it
    /// should no-op against its own, already-answered request instead of
    /// clobbering the live one's bookkeeping.
    @Test func answeringAStaleDisplacedRequestDoesNotAffectTheCurrentlyPendingRequest() {
        let session = SessionRuntime()
        var firstDecisions: [Bool] = []
        session.requestClipboardReadConfirmation(kind: .osc52Read) { firstDecisions.append($0) }
        let staleRequest = try! #require(session.pendingClipboardConfirmation)

        var secondDecisions: [Bool] = []
        session.requestClipboardReadConfirmation(kind: .paste) { secondDecisions.append($0) }
        #expect(firstDecisions == [false]) // displaced, already denied

        // A stale "Allow" tap against the request that used to be pending.
        session.answerPendingClipboardConfirmation(staleRequest, allow: true)

        // The live (second) request is untouched: still pending, still
        // unanswered, and its kind's remembered decision was not set by
        // the stale tap.
        #expect(isKind(session.pendingClipboardConfirmation?.kind, .paste))
        #expect(secondDecisions.isEmpty)
        #expect(session.rememberedClipboardDecision(for: .paste) == nil)
        // The stale request's own decision does not fire a second time.
        #expect(firstDecisions == [false])
    }

    /// #0390 round 2, B4: with no route wired to a Session at all (e.g. the
    /// terminal delegate proxy has nothing set for
    /// `onClipboardReadConfirmationRequest`), the request must deny, never
    /// hang and never default to allow. `TerminalClipboardConfirmationRequest`'s
    /// initializer is internal to `GhosttyTerminal`, so this exercises the
    /// extracted, testable `resolveClipboardConfirmationRoute` rather than
    /// the real delegate method.
    @Test func unwiredTerminalDelegateProxyRouteDenies() {
        let state = TerminalViewState(theme: .default)
        let proxy = TerminalDelegateProxy(state: state)
        var decisions: [Bool] = []

        proxy.resolveClipboardConfirmationRoute(kind: .osc52Read) { decisions.append($0) }

        #expect(decisions == [false])
    }

    @Test func wiredTerminalDelegateProxyRouteForwardsToTheHandler() {
        let state = TerminalViewState(theme: .default)
        let proxy = TerminalDelegateProxy(state: state)
        var routedKind: TerminalClipboardRequestKind?
        proxy.onClipboardReadConfirmationRequest = { kind, decide in
            routedKind = kind
            decide(true)
        }

        var decisions: [Bool] = []
        proxy.resolveClipboardConfirmationRoute(kind: .paste) { decisions.append($0) }

        #expect(isKind(routedKind, .paste))
        #expect(decisions == [true])
    }

    /// #0390 round 2, B4: the other fail-open leg — a clipboard-read
    /// confirmation whose owning Session cannot be resolved (e.g. the tab
    /// closed before `PaneView`'s wiring ran) must deny, never hang.
    @Test func missingSessionClipboardConfirmationRouteDenies() {
        var decisions: [Bool] = []

        routeClipboardReadConfirmation(to: nil, kind: .osc52Read) { decisions.append($0) }

        #expect(decisions == [false])
    }

    @Test func resolvedSessionClipboardConfirmationRouteAppliesItsPolicy() {
        let session = SessionRuntime()
        var decisions: [Bool] = []

        routeClipboardReadConfirmation(to: session, kind: .osc52Read) { decisions.append($0) }

        #expect(isKind(session.pendingClipboardConfirmation?.kind, .osc52Read))
        #expect(decisions.isEmpty)
    }
}
