// SplitTreeTargetedSplitTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `SplitTree.splitPane(id:direction:ratio:command:)` (#0282) — the
/// targeted split variant `pane split`'s XPC dispatch calls, as distinct
/// from `splitFocusedPane` which always operates on `focusedPaneID`.
@MainActor
struct SplitTreeTargetedSplitTests {

    private func fraction(of paneID: UUID, in node: SplitTreeNode, available: Double = 1.0) -> Double? {
        switch node {
        case .leaf(let pane):
            return pane.id == paneID ? available : nil
        case .split(_, _, let ratio, let left, let right):
            return fraction(of: paneID, in: left, available: available * ratio)
                ?? fraction(of: paneID, in: right, available: available * (1.0 - ratio))
        }
    }

    private func isApprox(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
        abs(a - b) < tolerance
    }

    // MARK: - Splits the named pane, not the focused one

    @Test func splitsTheNamedPaneEvenWhenAnotherPaneIsFocused() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        let paneB = tree.splitFocusedPane(direction: .horizontal)
        // paneB is now focused (splitFocusedPane's existing behavior).
        // Target paneA explicitly instead.
        tree.focusedPaneID = paneB.id

        let newPane = tree.splitPane(id: paneA.id, direction: .vertical)!

        // `newPane != nil` / `allPanes.count == 3` / `root.contains(...)`
        // would all pass identically if the split had wrongly landed on
        // paneB instead — only position distinguishes "split the named
        // pane" from "split whatever's focused": the new pane must land
        // *below* paneA (1/2), pushing paneB to 2/1. A mis-targeted split
        // (landing on paneB) would instead put the new pane at 2/2 with
        // paneB unchanged at 2/1 — same panePositions.count, same
        // fractions, wrong pane split.
        let positions = tree.panePositions
        #expect(positions[paneA.id]?.label == "1/1")
        #expect(positions[newPane.id]?.label == "1/2")
        #expect(positions[paneB.id]?.label == "2/1")
    }

    @Test func focusStaysOnTheAlreadyFocusedPaneWhenTargetingADifferentPane() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        let paneB = tree.splitFocusedPane(direction: .horizontal)
        tree.focusedPaneID = paneB.id

        let newPane = tree.splitPane(id: paneA.id, direction: .vertical)

        // paneA was targeted (not focused); the tree's focus must remain on
        // paneB exactly as it was before the split.
        #expect(tree.focusedPaneID == paneB.id)
        #expect(tree.focusedPaneID != newPane?.id)
    }

    @Test func focusMovesToTheNewPaneWhenTargetingTheCurrentlyFocusedPane() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        #expect(tree.focusedPaneID == paneA.id)

        let newPane = tree.splitPane(id: paneA.id, direction: .horizontal)

        #expect(newPane != nil)
        #expect(tree.focusedPaneID == newPane!.id)
    }

    // MARK: - Even 1/n rebalance still holds for the targeted variant

    @Test func rebalancesToThirdsWhenSplittingANonFocusedPane() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        let paneB = tree.splitFocusedPane(direction: .horizontal)
        tree.focusedPaneID = paneB.id // move focus away from paneA

        let paneC = tree.splitPane(id: paneA.id, direction: .horizontal)!

        // Splitting paneB instead (a mis-target) would rebalance to thirds
        // identically, so the fractions alone can't prove *which* pane was
        // split — position can: paneC lands adjacent to paneA (slot 2/1),
        // pushing paneB out to 3/1. A mis-targeted split would instead
        // leave paneB at 2/1 and put paneC at 3/1.
        let positions = tree.panePositions
        #expect(positions[paneA.id]?.label == "1/1")
        #expect(positions[paneC.id]?.label == "2/1")
        #expect(positions[paneB.id]?.label == "3/1")
        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 1.0 / 3.0))
        #expect(isApprox(fraction(of: paneB.id, in: tree.root)!, 1.0 / 3.0))
        #expect(isApprox(fraction(of: paneC.id, in: tree.root)!, 1.0 / 3.0))
    }

    // MARK: - Unknown id fails visibly rather than silently no-oping

    @Test func returnsNilForAnUnknownPaneID() {
        let tree = SplitTree()
        let before = tree.root
        let focusedBefore = tree.focusedPaneID

        let result = tree.splitPane(id: UUID(), direction: .horizontal)

        #expect(result == nil)
        #expect(tree.allPanes.count == 1, "an unknown target must not insert a pane")
        #expect(tree.focusedPaneID == focusedBefore)
        if case .leaf(let pane) = before, case .leaf(let paneAfter) = tree.root {
            #expect(pane.id == paneAfter.id)
        } else {
            Issue.record("expected a single-leaf tree before and after a failed split")
        }
    }

    // MARK: - `-c` command threading (#0282)

    @Test func commandOverrideReachesTheNewPanesRenderedConfig() {
        let tree = SplitTree()
        let target = tree.focusedPane

        let newPane = tree.splitPane(id: target.id, direction: .horizontal, command: "htop")!

        #expect(newPane.tabs[0].terminal.renderedConfig.contains("command = htop"))
    }

    @Test func nilCommandLeavesTheDefaultShellPreferenceInPlace() {
        let tree = SplitTree()
        let target = tree.focusedPane

        let newPane = tree.splitPane(id: target.id, direction: .horizontal)!

        // Asserting only the *absence* of "command = htop" would pass even
        // if the command line were dropped entirely — assert the shell
        // preference's own line is genuinely present instead.
        #expect(newPane.tabs[0].terminal.renderedConfig.contains("command = \(SettingsPreference.resolvedShell())"))
    }

    // MARK: - `-c` panes survive their command exiting (#0282 round 3)

    /// Verified against the pinned libghostty
    /// (`c69c34354e511af7a3e6d7e5e2a4fa2fed4b90ff`) via a standalone harness
    /// calling `ghostty_config_new`/`load_file`/`finalize` directly:
    /// `wait-after-command = true` produces zero config diagnostics, and a
    /// deliberately misspelled `wait-after-comand` key produces
    /// `diagnostics=1 "unknown field"` — the control proving the harness
    /// would have caught it if the directive didn't exist. `ghostty
    /// +show-config --default --docs` (Ghostty.app 1.3.1) documents the
    /// semantic directly: "With this true, the terminal window will stay
    /// open until any keypress is received," default `false`. This test
    /// asserts the same acceptance through Batty's own config pipeline —
    /// `renderedConfig` only reflects a config libghostty's diagnostics
    /// accepted (`prepareConfig` fails closed otherwise), so this is proof
    /// of acceptance, not just string formatting.
    @Test func commandOverridePaneWaitsAfterTheCommandExits() {
        let tree = SplitTree()
        let target = tree.focusedPane

        let newPane = tree.splitPane(id: target.id, direction: .horizontal, command: "htop")!

        #expect(newPane.tabs[0].terminal.renderedConfig.contains("wait-after-command = true"))
    }

    /// The wait directive must be scoped to `-c` panes only — an ordinary
    /// shell tab (no command override) must keep closing when its shell
    /// exits, since Cmd-D and every existing tab rely on that behavior.
    @Test func nilCommandPaneDoesNotWaitAfterItsShellExits() {
        let tree = SplitTree()
        let target = tree.focusedPane

        let newPane = tree.splitPane(id: target.id, direction: .horizontal)!

        #expect(!newPane.tabs[0].terminal.renderedConfig.contains("wait-after-command"))
    }

    @Test func newPaneFromTargetedSplitInheritsSourceCWD() {
        let tree = SplitTree()
        let target = tree.focusedPane
        target.activeTab!.terminal.configuration.workingDirectory = "/tmp/example"

        let newPane = tree.splitPane(id: target.id, direction: .horizontal)!

        #expect(newPane.tabs[0].terminal.configuration.workingDirectory == "/tmp/example")
    }

    // MARK: - Session attachment carries through the targeted variant too

    @Test func targetedSplitAttachesTheNewPaneToTheOwningSession() {
        let session = SessionRuntime()
        let target = session.tree.root.firstLeafPane

        let newPane = session.tree.splitPane(id: target.id, direction: .vertical)!

        #expect(newPane.sessionID == session.id)
        #expect(newPane.tabs[0].paneID == newPane.id)
        #expect(newPane.tabs[0].sessionID == session.id)
    }
}
