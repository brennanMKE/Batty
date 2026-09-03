// AppStateStoreXPCFocusTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `AppStateStore.focusSessionForXPC(id:)`,
/// `.focusPaneForXPC(id:)`, and `.focusTabForXPC(id:)` — the app-side
/// source of the `sessionFocus`/`paneFocus`/`tabFocus` XPC verbs (#0381).
/// Distinct from `AppStateStoreFocusTests` (which covers the pre-existing,
/// non-activating `AppStateStore.focusPane(id:)` used by clicks/chip
/// selection): the XPC focus verbs are the CLI's one sanctioned exception
/// to "a mutation aimed at a background session must not switch the
/// active session," so they select the target session and activate its
/// window — behavior `focusPane(id:)` deliberately does not have.
///
/// #0257's 2026-07-27 terminology amendment pins the test shape: assert
/// the resulting store state (`selectedSessionID`, the target session's
/// `focusedPaneID`, the target pane's `activeTabID`), not merely the
/// absence of a crash. Every test below reads state directly rather than
/// re-deriving what the mutation was supposed to do.
@MainActor
struct AppStateStoreXPCFocusTests {

    // MARK: - session focus

    @Test func focusSessionForXPCSelectsABackgroundSession() {
        let store = AppStateStore()
        let selected = store.sessions[0]
        let background = store.addSession(title: "Background")!
        store.windows[0].selectedSessionID = selected.id

        let outcome = store.focusSessionForXPC(id: background.id)

        #expect(outcome == .focused)
        #expect(store.windows[0].selectedSessionID == background.id,
                "session focus must select the target session even though it started as a background session")
    }

    @Test func focusSessionForXPCReturnsUnknownSessionForAnUnknownID() {
        let store = AppStateStore()
        let selectedBefore = store.windows[0].selectedSessionID

        let outcome = store.focusSessionForXPC(id: UUID())

        #expect(outcome == .unknownSession)
        #expect(store.windows[0].selectedSessionID == selectedBefore,
                "an unknown session id must not change the current selection")
    }

    @Test func focusSessionForXPCResolvesASessionInANonKeyWindow() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())
        let target = w2.sessions[0]

        let outcome = store.focusSessionForXPC(id: target.id)

        #expect(outcome == .focused)
        #expect(w2.selectedSessionID == target.id)
    }

    /// #0257's "session focus" semantic — select the session and activate
    /// its window, nothing else — has no Pane/Tab writes of its own. A
    /// mutation that clobbers `focusedPaneID` and `activeTabID` after
    /// selecting the session passed the rest of the suite (nothing else
    /// pins this), so it needs its own coverage capturing both values
    /// before the call and asserting they are unchanged after.
    @Test func focusSessionForXPCLeavesTheTargetSessionsPaneAndTabFocusUnchanged() {
        let store = AppStateStore()
        let target = store.sessions[0]
        // Give the session a *non-default* focused pane — a fresh session's
        // only pane is trivially `allPanes.first`, which can't distinguish
        // "left alone" from "reset to the first pane" (the round-2 review
        // finding: a mutation that re-focused the session's first pane
        // passed against the single-pane setup this test used to have).
        let second = target.tree.splitFocusedPane(direction: .horizontal)
        target.tree.focusedPaneID = second.id
        #expect(target.tree.allPanes.first?.id != second.id)
        let pane = second
        let newTab = pane.addTab()
        pane.activeTabID = newTab.id
        let originalFocusedPaneID = target.tree.focusedPaneID
        let originalActiveTabID = pane.activeTabID

        let outcome = store.focusSessionForXPC(id: target.id)

        #expect(outcome == .focused)
        #expect(target.tree.focusedPaneID == originalFocusedPaneID,
                "session focus must not change the target session's focused pane")
        #expect(pane.activeTabID == originalActiveTabID,
                "session focus must not change the target pane's active tab")
    }

    // MARK: - pane focus (#0257: leaves the pane's selected tab unchanged)

    @Test func focusPaneForXPCSelectsTheOwningBackgroundSessionAndFocusesThePane() {
        let store = AppStateStore()
        let selected = store.sessions[0]
        let background = store.addSession(title: "Background")!
        store.windows[0].selectedSessionID = selected.id
        let originalPane = background.focusedPaneAnyKind
        let target = background.tree.splitFocusedPane(direction: .horizontal)
        // `splitFocusedPane` moves the tree's own focus to the new pane
        // (mirrors `splitPane`'s UI behavior) — move it back to the
        // original pane so the assertion below actually exercises the
        // focus write below rather than finding it already true.
        background.tree.focusedPaneID = originalPane.id
        #expect(background.tree.focusedPaneID != target.id)

        let outcome = store.focusPaneForXPC(id: target.id)

        #expect(outcome == .focused)
        #expect(store.windows[0].selectedSessionID == background.id,
                "focusing a pane in a non-selected session must select that session — the opposite of every other mutation verb")
        #expect(background.tree.focusedPaneID == target.id)
    }

    /// A mutation that re-selects the pane's *first* tab on every focus
    /// (exactly the "pane focus re-selects tabs" regression #0257 forbids)
    /// passed this test as originally written, because it left
    /// `activeTabID` at the default first tab both before and after the
    /// call — the assertion never distinguished "left alone" from
    /// "reset to first." Asserting against a non-first tab closes that gap.
    @Test func focusPaneForXPCLeavesThePanesActiveTabUnchanged() {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        let newTab = pane.addTab()
        // addTab() makes the new tab active, and it is not the pane's
        // first tab — exactly the non-default active tab needed to catch
        // a "reset to first tab" regression.
        pane.activeTabID = newTab.id
        #expect(pane.tabs.first?.id != newTab.id)

        let outcome = store.focusPaneForXPC(id: pane.id)

        #expect(outcome == .focused)
        #expect(pane.activeTabID == newTab.id,
                "pane focus must never re-select the pane's active tab")
    }

    /// Cross-session variant of the above: focusing a pane in a background
    /// session must also leave that pane's non-first active tab untouched.
    @Test func focusPaneForXPCInABackgroundSessionLeavesItsActiveTabUnchanged() {
        let store = AppStateStore()
        let selected = store.sessions[0]
        let background = store.addSession(title: "Background")!
        store.windows[0].selectedSessionID = selected.id
        let pane = background.focusedPaneAnyKind
        let newTab = pane.addTab()
        pane.activeTabID = newTab.id
        #expect(pane.tabs.first?.id != newTab.id)

        let outcome = store.focusPaneForXPC(id: pane.id)

        #expect(outcome == .focused)
        #expect(store.windows[0].selectedSessionID == background.id)
        #expect(pane.activeTabID == newTab.id,
                "pane focus in a background session must never re-select its active tab")
    }

    @Test func focusPaneForXPCReturnsUnknownPaneForAnUnknownID() {
        let store = AppStateStore()
        let selectedBefore = store.windows[0].selectedSessionID

        let outcome = store.focusPaneForXPC(id: UUID())

        #expect(outcome == .unknownPane)
        #expect(store.windows[0].selectedSessionID == selectedBefore)
    }

    /// #0256's invariant ("focus must never land on a hidden pane",
    /// restated in `WindowRuntime.hidePane`'s and `closePane`'s comments,
    /// and in #0337's Expected behavior) applies to `pane focus` too. A
    /// throwaway mutation that dropped the un-hide step and called
    /// `window.focusPane(id:)` directly produced `focused` /
    /// `focusedIsTarget=true` / `isHidden=true` — this test pins that the
    /// target must end both focused AND visible.
    @Test func focusPaneForXPCUnhidesTheTargetIfItWasHidden() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let originalPane = session.focusedPaneAnyKind
        let target = session.tree.splitFocusedPane(direction: .horizontal)
        // Move focus off the target before hiding it — `hidePane` moves
        // focus itself when the pane being hidden is the focused one, which
        // would mask whether `focusPaneForXPC` is the one doing the un-hide.
        session.tree.focusedPaneID = originalPane.id
        store.hidePane(id: target.id)
        #expect(target.isHidden, "setup: target must start hidden")

        let outcome = store.focusPaneForXPC(id: target.id)

        #expect(outcome == .focused)
        #expect(!target.isHidden,
                "pane focus must un-hide a hidden target — focus must never land on a hidden pane")
        #expect(session.tree.focusedPaneID == target.id)
    }

    @Test func focusPaneForXPCResolvesAPaneInANonKeyWindow() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())
        let target = w2.sessions[0].focusedPaneAnyKind

        let outcome = store.focusPaneForXPC(id: target.id)

        #expect(outcome == .focused)
        #expect(w2.selectedSessionID == w2.sessions[0].id)
        #expect(w2.sessions[0].tree.focusedPaneID == target.id)
    }

    // MARK: - tab focus (#0257: selects the tab if not already selected,
    // and implies focusing its containing pane)

    @Test func focusTabForXPCSelectsTheTabAndFocusesItsPaneAndSession() {
        let store = AppStateStore()
        let selected = store.sessions[0]
        let background = store.addSession(title: "Background")!
        store.windows[0].selectedSessionID = selected.id
        let pane = background.tree.splitFocusedPane(direction: .horizontal)
        let newTab = pane.addTab()
        // Move focus/active-tab away from the target so this test actually
        // exercises both writes rather than finding them already true.
        background.tree.focusedPaneID = background.tree.allPanes.first { $0.id != pane.id }!.id
        pane.activeTabID = pane.tabs[0].id
        #expect(pane.activeTabID != newTab.id)

        let outcome = store.focusTabForXPC(id: newTab.id)

        #expect(outcome == .focused)
        #expect(store.windows[0].selectedSessionID == background.id,
                "focusing a tab in a non-selected session must select that session")
        #expect(background.tree.focusedPaneID == pane.id,
                "tab focus implies focusing its containing pane")
        #expect(pane.activeTabID == newTab.id,
                "tab focus must select the target tab")
    }

    /// Same #0256 invariant as `focusPaneForXPCUnhidesTheTargetIfItWasHidden`,
    /// exercised through `tab focus`: the target tab's containing pane must
    /// end visible, since `tab focus` implies focusing that pane.
    @Test func focusTabForXPCUnhidesTheContainingPaneIfItWasHidden() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let originalPane = session.focusedPaneAnyKind
        let target = session.tree.splitFocusedPane(direction: .horizontal)
        let targetTabID = target.activeTabID
        session.tree.focusedPaneID = originalPane.id
        store.hidePane(id: target.id)
        #expect(target.isHidden, "setup: target pane must start hidden")

        let outcome = store.focusTabForXPC(id: targetTabID)

        #expect(outcome == .focused)
        #expect(!target.isHidden,
                "tab focus must un-hide the containing pane — focus must never land on a hidden pane")
        #expect(session.tree.focusedPaneID == target.id)
        #expect(target.activeTabID == targetTabID)
    }

    @Test func focusTabForXPCOnAnAlreadyActiveTabIsIdempotent() {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        let activeTabID = pane.activeTabID

        let outcome = store.focusTabForXPC(id: activeTabID)

        #expect(outcome == .focused)
        #expect(pane.activeTabID == activeTabID)
    }

    @Test func focusTabForXPCReturnsUnknownTabForAnUnknownID() {
        let store = AppStateStore()
        let selectedBefore = store.windows[0].selectedSessionID

        let outcome = store.focusTabForXPC(id: UUID())

        #expect(outcome == .unknownTab)
        #expect(store.windows[0].selectedSessionID == selectedBefore)
    }

    @Test func focusTabForXPCResolvesATabInANonKeyWindow() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())
        let targetPane = w2.sessions[0].focusedPaneAnyKind
        let targetTabID = targetPane.activeTabID

        let outcome = store.focusTabForXPC(id: targetTabID)

        #expect(outcome == .focused)
        #expect(w2.selectedSessionID == w2.sessions[0].id)
        #expect(w2.sessions[0].tree.focusedPaneID == targetPane.id)
    }

    // MARK: - focusedSessionIDFallback()

    @Test func focusedSessionIDFallbackResolvesTheSelectedSession() {
        let store = AppStateStore()
        let second = store.addSession(title: "Second")!
        store.windows[0].selectedSessionID = second.id

        #expect(store.focusedSessionIDFallback() == second.id)
        #expect(store.focusedSessionIDFallback() != store.sessions[0].id)
    }
}
