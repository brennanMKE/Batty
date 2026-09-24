// WindowRuntimeCreatePaneTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `WindowRuntime.createPane(kind:direction:contentFactory:)` (#0331)
/// — the menu / Command Palette / keyboard-shortcut counterpart to #0315's
/// CLI `batty pane split --view <kind>`. `BattyCommands`' "New Pane"
/// submenus, `BattyShortcuts`' NSEvent-monitor cases, and
/// `CommandPaletteView.dispatch(_:)`'s new cases all call this one method,
/// so its own behavior (kind, direction, focus, no-session guard) is what
/// every surface actually depends on.
@MainActor
struct WindowRuntimeCreatePaneTests {

    @Test func createPaneAddsATypedPaneAndReturnsIt() {
        let store = AppStateStore()
        let window = store.windows[0]
        let session = window.selectedSession!
        let countBefore = session.tree.allPanes.count

        // contentFactory: { _ in nil } — this test is about the split
        // mechanics (count, kind, focus), not about a kind's real content.
        // Without it, `.gitStatus`'s real conformer would start a real
        // FSEventStream as a side effect of this unrelated test.
        let newPane = window.createPane(kind: .gitStatus, contentFactory: { _ in nil })

        #expect(newPane != nil)
        #expect(newPane?.content == nil)
        #expect(newPane?.kind == .gitStatus)
        #expect(session.tree.allPanes.count == countBefore + 1)
        #expect(session.tree.allPanes.contains { $0.id == newPane?.id })
    }

    @Test func createPaneMovesFocusToTheNewPane() {
        let store = AppStateStore()
        let window = store.windows[0]
        let session = window.selectedSession!
        let originalFocused = session.tree.focusedPaneID

        // contentFactory: { _ in nil } — see the comment above; this test
        // is about focus, not about `.systemMetrics`'s real sampling loop.
        let newPane = window.createPane(kind: .systemMetrics, contentFactory: { _ in nil })

        #expect(newPane != nil)
        #expect(session.tree.focusedPaneID == newPane?.id)
        #expect(session.tree.focusedPaneID != originalFocused)
    }

    @Test func createPaneDefaultsToHorizontalDirection() {
        let store = AppStateStore()
        let window = store.windows[0]
        let session = window.selectedSession!
        let sourcePane = session.tree.focusedPane

        // contentFactory: { _ in nil } — avoids `.processStatus`'s real
        // polling Task; this test is only about split geometry.
        let newPane = window.createPane(kind: .processStatus, contentFactory: { _ in nil })

        // A horizontal split places the new pane as a same-row sibling in
        // the next column (`docs`'s "2/1 is a horizontal sibling (second
        // column, first row)").
        let positions = session.tree.panePositions
        #expect(positions[sourcePane.id]?.row == positions[newPane!.id]?.row)
        #expect(positions[sourcePane.id]?.column != positions[newPane!.id]?.column)
    }

    @Test func createPaneRespectsAnExplicitVerticalDirection() {
        let store = AppStateStore()
        let window = store.windows[0]
        let session = window.selectedSession!
        let sourcePane = session.tree.focusedPane

        // contentFactory: { _ in nil } — avoids `.lmStudioDashboard`'s
        // real subprocess/HTTP polling; this test is only about split
        // geometry.
        let newPane = window.createPane(kind: .lmStudioDashboard, direction: .vertical, contentFactory: { _ in nil })

        let positions = session.tree.panePositions
        #expect(positions[sourcePane.id]?.column == positions[newPane!.id]?.column)
        #expect(positions[sourcePane.id]?.row != positions[newPane!.id]?.row)
    }

    @Test func createPaneReturnsNilWhenThereIsNoSelectedSession() {
        let store = AppStateStore()
        let window = store.windows[0]
        let countBefore = window.selectedSession!.tree.allPanes.count
        window.selectedSessionID = nil

        let newPane = window.createPane(kind: .gitStatus, contentFactory: { _ in nil })

        #expect(newPane == nil)
        window.selectedSessionID = store.sessions[0].id
        #expect(window.selectedSession!.tree.allPanes.count == countBefore,
                "createPane must not mutate any tree when there is no selected Session")
    }

    // MARK: - #0331: at least one full round trip through the real
    // production dispatch, not just the injected-factory mechanics above.
    // `.processStatus`'s real conformer is the one kind this suite already
    // constructs for real elsewhere (`AppStateStorePaneSplitTests`), with
    // deterministic `closePane` cleanup rather than leaving its 1s
    // sampling Task to the rest of the test process.

    @Test func dispatchSplitHorizontalProcessStatusCreatesARealProcessStatusPane() {
        let store = AppStateStore()
        let window = store.windows[0]
        let session = window.selectedSession!
        let countBefore = session.tree.allPanes.count
        let view = CommandPaletteView(isPresented: .constant(true), store: store)

        view.dispatch(.splitHorizontalProcessStatus)

        let newPane = session.tree.allPanes.first { $0.kind == .processStatus }
        #expect(newPane != nil)
        #expect(session.tree.allPanes.count == countBefore + 1)

        // Deterministic cleanup, not left to ARC timing (docs/pane-view-
        // lifecycle.md §5) — tears down the real sampling Task this test
        // deliberately constructed above.
        if let newPane { _ = store.closePane(id: newPane.id) }
    }

    /// `#0359`: `createPane` is a second, independent production path into
    /// `SplitTree`'s `.processStatus` construction branch (menus, the
    /// keyboard-shortcut monitors, and — exercised directly here — the
    /// Command Palette, none of which go through `AppStateStore.splitPane`
    /// at all per `WindowRuntime.createPane`'s own doc comment). Confirms the real
    /// conformer built through *this* path also gets a working `tabLookup`
    /// — a `.followingTab` target resolves (doesn't tombstone) rather than
    /// only `AppStateStorePaneSplitTests`'s XPC-path coverage proving it.
    @Test func dispatchSplitHorizontalProcessStatusFollowsTheSourcePanesTabThroughTheRealLookup() {
        let store = AppStateStore()
        let window = store.windows[0]
        let session = window.selectedSession!
        let source = session.tree.focusedPane
        let sourceTabID = source.activeTabID
        let view = CommandPaletteView(isPresented: .constant(true), store: store)

        view.dispatch(.splitHorizontalProcessStatus)

        let newPane = session.tree.allPanes.first { $0.kind == .processStatus }
        let content = newPane?.content as? ProcessStatusPaneContent
        #expect(content?.target == .followingTab(sourceTabID))
        // No AppKit surface in this headless test, so `foregroundPid` is
        // nil and the tick reports "no selection" — this asserts the tab
        // *lookup* succeeded, not a tombstone from a broken/absent lookup.
        #expect(content?.hasNoSelection == true)
        guard case .running = content?.runState else {
            Issue.record("expected .running (a successful, if empty, lookup), not a tombstone")
            if let newPane { _ = store.closePane(id: newPane.id) }
            return
        }

        // Deterministic cleanup — see the comment above.
        if let newPane { _ = store.closePane(id: newPane.id) }
    }
}
