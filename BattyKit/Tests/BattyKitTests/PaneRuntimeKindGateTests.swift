// PaneRuntimeKindGateTests.swift

import Foundation
import Testing
@testable import BattyKit

/// #0332 B1: the round-1 reviewer disproved the round-1 mechanism (renaming
/// `SessionRuntime.focusedPane` to `focusedPaneAnyKind`) by compiling this
/// exact probe against `SplitTree.focusedPane` — the untouched, 16-call-site
/// production idiom the rename never reached:
///
/// ```swift
/// let pane = session.tree.focusedPane
/// pane.addTab(inheritingCWDFrom: pane.activeTab)   // the exact #0315 defect
/// pane.closeActiveTab()
/// ```
///
/// It compiled cleanly and, before this round's fix, would have silently
/// added a second invisible tab to a non-terminal pane's structural
/// placeholder and then removed one. This suite runs that exact probe
/// against a live non-terminal pane and asserts it is now a no-op — the
/// gate lives on `PaneRuntime.addTab(inheritingCWDFrom:)`/
/// `.closeActiveTab()` themselves, so it holds no matter which accessor
/// spelling got the caller to this pane.
@MainActor
struct PaneRuntimeKindGateTests {

    private func makeNonTerminalPane(in session: SessionRuntime) -> PaneRuntime {
        let terminalPane = session.focusedPaneAnyKind
        // `contentFactory: { _ in nil }` (#0313's seam) keeps this split
        // from starting `.gitStatus`'s real conformer (a real
        // `FSEventStream`) as a side effect.
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .gitStatus, contentFactory: { _ in nil }, isSessionSelected: true)!
        #expect(nonTerminalPane.content == nil)
        return nonTerminalPane
    }

    @Test func theRound1ReviewersExactProbeIsANoOpOnANonTerminalPane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = makeNonTerminalPane(in: session)
        #expect(pane.kind != .terminal, "test setup: the probe must run against a non-terminal pane")
        let tabCountBefore = pane.tabs.count
        let activeTabIDBefore = pane.activeTabID

        // The reviewer's probe, verbatim, resolved through `session.tree
        // .focusedPane` — the spelling the round-1 rename never reached.
        let probedPane = session.tree.focusedPane
        probedPane.addTab(inheritingCWDFrom: probedPane.activeTab)
        #expect(probedPane.tabs.count == tabCountBefore, "addTab must not add a second, unrendered tab to a non-terminal pane")

        probedPane.closeActiveTab()
        #expect(probedPane.tabs.count == tabCountBefore, "closeActiveTab must not remove a non-terminal pane's only, structural tab")
        #expect(probedPane.activeTabID == activeTabIDBefore)
    }

    @Test func addTabStillWorksOnATerminalPane() {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        #expect(pane.kind == .terminal, "test setup")
        let tabCountBefore = pane.tabs.count

        let newTab = pane.addTab()

        #expect(pane.tabs.count == tabCountBefore + 1)
        #expect(pane.activeTabID == newTab.id)
    }

    @Test func closeActiveTabStillWorksOnATerminalPane() {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        #expect(pane.kind == .terminal, "test setup")
        pane.addTab()
        let tabCountBefore = pane.tabs.count

        pane.closeActiveTab()

        #expect(pane.tabs.count == tabCountBefore - 1)
    }
}
