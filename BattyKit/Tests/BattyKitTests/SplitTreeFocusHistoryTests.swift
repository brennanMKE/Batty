// SplitTreeFocusHistoryTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `SplitTree.removePane`'s recency-based focus successor (#0337) at
/// the Model layer, directly: no organic focus history for the surviving
/// panes (trees are composed with `SplitTreeNode.split`/`.leaf` rather than
/// via `splitFocusedPane`/`splitPane`, so nothing is recorded except the one
/// explicit `focusedPaneID` write each test makes), isolating the fallback
/// chain — sibling subtree, then first visible leaf, then `firstLeafPaneID`
/// — from the recency-stack behavior already covered end-to-end in
/// `AppStateStoreClosePaneTests.swift` and `CloseTabCascadeTests.swift`.
@MainActor
struct SplitTreeFocusHistoryTests {

    /// A fresh `SplitTree` records no history until a deliberate focus
    /// change happens — otherwise `init`'s own `focusedPaneID =
    /// root.firstLeafPaneID` write would permanently seed history with the
    /// tree's leftmost leaf, which would make every "no history" fallback
    /// test below indistinguishable from "history happens to agree with
    /// the leftmost leaf."
    @Test func aFreshTreeHasNoUsableHistoryUntilAFocusChangeHappens() {
        let distraction = PaneRuntime()
        let sibling = PaneRuntime()
        let focusTarget = PaneRuntime()
        let root = SplitTreeNode.split(
            id: UUID(), direction: .horizontal, ratio: 0.5,
            left: .leaf(distraction),
            right: .split(id: UUID(), direction: .vertical, ratio: 0.5, left: .leaf(sibling), right: .leaf(focusTarget))
        )
        let tree = SplitTree(root: root)
        // Never explicitly focused: distraction and sibling should not be
        // "recently focused" just because the tree was created.
        #expect(tree.focusedPaneID == distraction.id, "precondition: firstLeafPaneID is distraction")

        tree.focusedPaneID = focusTarget.id
        tree.removePane(id: focusTarget.id)

        // With no usable history for either survivor, the sibling subtree
        // that absorbed focusTarget's space (not the unrelated distraction
        // branch, which happens to be the tree's global leftmost leaf) must
        // win.
        #expect(tree.focusedPaneID == sibling.id,
                "no history exists for either survivor, so the fallback must prefer the sibling that absorbed the space over the unrelated global-leftmost pane")
    }

    /// Same shape, but the sibling that would absorb the closed pane's
    /// space is itself hidden (#0256) — the fallback must skip past it to
    /// the next visible pane rather than land on a hidden one, even though
    /// nothing chose it via history.
    @Test func theFallbackNeverLandsOnAHiddenSiblingEvenWithNoHistory() {
        let distraction = PaneRuntime()
        let hiddenSibling = PaneRuntime(isHidden: true)
        let focusTarget = PaneRuntime()
        let root = SplitTreeNode.split(
            id: UUID(), direction: .horizontal, ratio: 0.5,
            left: .leaf(distraction),
            right: .split(id: UUID(), direction: .vertical, ratio: 0.5, left: .leaf(hiddenSibling), right: .leaf(focusTarget))
        )
        let tree = SplitTree(root: root)
        tree.focusedPaneID = focusTarget.id

        tree.removePane(id: focusTarget.id)

        #expect(tree.focusedPaneID == distraction.id,
                "the sibling that absorbed the space is hidden, so the fallback must skip it and land on the next visible pane instead")
        #expect(tree.allPanes.first { $0.id == tree.focusedPaneID }?.isHidden == false,
                "focus must never land on a hidden pane (#0256), even at the end of the fallback chain")
    }

    /// Distinct from `theFallbackNeverLandsOnAHiddenSiblingEvenWithNoHistory`,
    /// which exercises hidden-skipping in the *sibling-subtree* fallback
    /// with an empty history. This puts a hidden pane in the recency stack
    /// itself, ranked ahead of a visible one, so the history-lookup step's
    /// own `isHidden == false` filter is what has to fire.
    ///
    /// Deliberately calls `tree.removePane(id:)` directly rather than going
    /// through `AppStateStore.closePane`/`WindowRuntime.closePane`, as the
    /// minimal isolation case with no Runtime layer in the call path at
    /// all. **This is not the only place the filter is provable** — an
    /// earlier draft of this comment claimed it was, because this test's
    /// own fixture happens to make `WindowRuntime`'s
    /// `resolveHiddenFocusFallback(in:)` backstop correct a dropped-filter
    /// bug back to the *same* answer this test expects (`main`, which is
    /// also `visiblePanes.first` here), papering over the mutation when run
    /// through `store.closePane`. `AppStateStoreClosePaneTests
    /// .closingFallsBackToTheMostRecentVisibleHistoryEntryNotTheFirstVisiblePane`
    /// uses a fixture where the correct recency answer and
    /// `visiblePanes.first` differ, and *that* one does go red through the
    /// full production `closePane` path under the same mutation.
    @Test func theHistoryLookupItselfSkipsAHiddenEntryRankedAheadOfAVisibleOne() {
        let tree = SplitTree()
        let main = tree.focusedPane
        let focused = tree.splitFocusedPane(direction: .horizontal)
        let hiddenSurvivor = tree.splitPane(id: main.id, direction: .vertical)!
        // Click into hiddenSurvivor, then back to focused, so history reads
        // [focused, hiddenSurvivor] — hiddenSurvivor is a real, ranked
        // history entry, not merely absent from it.
        tree.focusedPaneID = hiddenSurvivor.id
        tree.focusedPaneID = focused.id
        hiddenSurvivor.isHidden = true

        tree.removePane(id: focused.id)

        #expect(tree.focusedPaneID == main.id,
                "hiddenSurvivor ranks ahead of main in history but is hidden, so the history lookup must skip it and fall through to the sibling subtree (main), not land on a hidden pane straight out of history")
        #expect(tree.allPanes.first { $0.id == tree.focusedPaneID }?.isHidden == false,
                "focus must never sit on a hidden pane (#0256), including when the hidden pane is the most recent history entry")
    }

    /// The dedupe in `focusedPaneID`'s `didSet` (`removeAll` before
    /// `insert`) is the only thing bounding `focusHistory`'s length —
    /// without it, alternating focus between the same two Panes would
    /// append a fresh duplicate id on every switch, forever (the issue's
    /// fix sketch item 3 explicitly required the stack not grow
    /// unboundedly). `focusHistory` is `private(set)` specifically so this
    /// test can observe the count directly rather than inferring
    /// boundedness from behavior.
    @Test func alternatingFocusBetweenTwoPanesDoesNotGrowHistoryUnboundedly() {
        let tree = SplitTree()
        let main = tree.focusedPane
        let other = tree.splitFocusedPane(direction: .horizontal)

        for _ in 0..<25 {
            tree.focusedPaneID = main.id
            tree.focusedPaneID = other.id
        }

        #expect(tree.focusHistory.count == 2,
                "alternating between two panes must dedupe to their two ids, not append a duplicate per switch")
    }

    /// The `if !newRoot.contains(paneID: focusedPaneID)` guard in
    /// `removePane` is unreachable from any *production* call path (every
    /// production caller reaches a multi-pane tree only by splitting, which
    /// always writes `focusedPaneID` and therefore always populates
    /// history — the guarded value and `focusHistory[0]` are always the
    /// same pane in practice, which is *why* the guard is safe to remove
    /// there without changing behavior). `SplitTree(root:)` is a public
    /// initializer that can build a multi-pane tree with **no** focus
    /// history at all, though: `focused` here is `root.firstLeafPaneID`
    /// from `init` and is never subsequently written, so history stays
    /// empty for the whole test.
    ///
    /// Closing `victim` (not focused) must leave `focused` alone.
    /// `victim`'s own *sibling*, `decoy`, is what an unconditional
    /// recompute would wrongly produce — with no history to consult,
    /// `resolveSuccessor`'s next step is exactly `decoy`, so this proves
    /// the guard is load-bearing for this entry point, not merely
    /// dead defensive code, even though it can never fire once a tree is
    /// grown by splitting.
    @Test func closingANonFocusedPaneInATreeBuiltDirectlyLeavesFocusUnchangedEvenWithNoHistory() {
        let focused = PaneRuntime()
        let victim = PaneRuntime()
        let decoy = PaneRuntime()
        let root = SplitTreeNode.split(
            id: UUID(), direction: .horizontal, ratio: 0.5,
            left: .leaf(focused),
            right: .split(id: UUID(), direction: .vertical, ratio: 0.5, left: .leaf(victim), right: .leaf(decoy))
        )
        let tree = SplitTree(root: root)
        #expect(tree.focusedPaneID == focused.id, "precondition: firstLeafPaneID is focused, and it is never explicitly (re)written, so history stays empty")

        tree.removePane(id: victim.id)

        #expect(tree.focusedPaneID == focused.id,
                "closing victim, which was not focused, must leave focus on focused untouched — decoy (victim's own structural sibling) is the wrong answer an unconditional recompute would produce with no history to consult")
    }

    /// `resolveSuccessor`'s step 3 (`newRoot.firstVisibleLeafPaneID`, a scan
    /// of the *whole* tree) is distinct from step 2 (the sibling subtree
    /// alone): this builds a case where the sibling subtree has no visible
    /// leaf of its own, but a visible Pane survives elsewhere in the tree —
    /// and puts a hidden Pane at the tree's true leftmost position, so a
    /// naive `firstLeafPaneID` (ignoring `isHidden`) would land on it
    /// instead of scanning past it to the real answer.
    @Test func theFinalFallbackScansTheWholeTreeForAVisibleLeafNotJustTheSibling() {
        let hiddenLeftmost = PaneRuntime(isHidden: true)
        let visibleDeep = PaneRuntime()
        let focused = PaneRuntime()
        let hiddenSibling = PaneRuntime(isHidden: true)
        let root = SplitTreeNode.split(
            id: UUID(), direction: .horizontal, ratio: 0.5,
            left: .split(id: UUID(), direction: .vertical, ratio: 0.5, left: .leaf(hiddenLeftmost), right: .leaf(visibleDeep)),
            right: .split(id: UUID(), direction: .vertical, ratio: 0.5, left: .leaf(focused), right: .leaf(hiddenSibling))
        )
        let tree = SplitTree(root: root)
        tree.focusedPaneID = focused.id

        tree.removePane(id: focused.id)

        #expect(tree.focusedPaneID == visibleDeep.id,
                "the sibling subtree (hiddenSibling alone) has no visible leaf, so the fallback must scan the whole tree rather than default to firstLeafPaneID's blind leftmost pick (the hidden pane)")
    }

    /// A closed pane's id is pruned from history, not merely superseded —
    /// closing the same-named successor a second time later must not
    /// resurrect it.
    @Test func aClosedPanesIDIsPrunedFromHistoryNotJustPopped() {
        let tree = SplitTree()
        let main = tree.focusedPane
        let paneA = tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.splitFocusedPane(direction: .horizontal)
        tree.focusedPaneID = paneA.id
        tree.focusedPaneID = paneB.id
        // History is now [B, A, Main]. Close A directly (not the focused
        // pane) so it leaves the tree while still parked in history.
        tree.removePane(id: paneA.id)
        #expect(tree.focusedPaneID == paneB.id, "closing non-focused A must not move focus off B")

        // Now close B (focused). If A's id had merely been superseded
        // rather than pruned, a stale copy could resurface here; it must
        // not, both because it should already be gone and because A no
        // longer exists in the tree at all.
        tree.removePane(id: paneB.id)

        #expect(tree.focusedPaneID == main.id)
        #expect(!tree.allPanes.contains { $0.id == paneA.id })
    }
}
