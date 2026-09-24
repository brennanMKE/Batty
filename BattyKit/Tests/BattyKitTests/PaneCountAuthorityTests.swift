// PaneCountAuthorityTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Pins a Session's Pane count in agreement across every surface that
/// reports it: `SplitTree.allPanes` (`SplitTreeNode.allLeafPanes`), the
/// Sidebar's per-Session listing (`SplitTree.panesSortedByColumnThenRow`,
/// which is `allPanes.sorted(...)` and so can only drift if a filter is
/// added to it directly), and `TopologySessionPayload.allPanes` (`batty
/// list`'s `panes=`, built by `TopologyPayloadBuilder`'s own recursion over
/// `SplitTreeNode`). The two independent tree walks are `allLeafPanes` and
/// `TopologyPayloadBuilder`/`TopologySplitNodePayload.allPanes`; neither
/// filters by `isHidden` or `kind` at the Pane level today. Covers a hidden
/// Pane, a non-terminal Pane, a Session that isn't the window's selected
/// one, and a Pane closed via its last Tab — the states where a filter
/// added to only one of the two walks (or to the Sidebar's sort) would go
/// unnoticed.
@MainActor
struct PaneCountAuthorityTests {

    /// Builds a Session with two terminal Panes plus one non-terminal
    /// (`.gitStatus`) Pane — three Panes total. Callers hide one of the
    /// terminal Panes themselves so each test controls which Pane ends up
    /// hidden.
    @discardableResult
    private func makeMixedStateSession(
        in session: SessionRuntime
    ) -> (terminalA: PaneRuntime, terminalHidden: PaneRuntime, nonTerminal: PaneRuntime) {
        let terminalA = session.focusedPaneAnyKind
        let terminalHidden = session.tree.splitFocusedPane(direction: .horizontal)
        // `contentFactory: { _ in nil }` avoids constructing a real
        // `GitStatusPaneContent` (and its real `FSEventStream`) as a side
        // effect of fixture setup — see PaneHideTests.swift's test 10/13 for
        // why this matters in a headless unit test.
        let nonTerminal = session.tree.splitPane(
            id: terminalHidden.id,
            direction: .vertical,
            kind: .gitStatus,
            contentFactory: { _ in nil }
        )!
        #expect(nonTerminal.content == nil)
        return (terminalA, terminalHidden, nonTerminal)
    }

    /// The three count/identity sources for a single Session, gathered in
    /// one place so every test below compares the same three things the
    /// same way.
    private struct CountSources {
        let treeAllPanesIDs: Set<UUID>
        let sidebarListingIDs: Set<UUID>
        let topologyPayloadIDs: Set<UUID>

        init(session: SessionRuntime, store: AppStateStore) {
            treeAllPanesIDs = Set(session.tree.allPanes.map(\.id))
            sidebarListingIDs = Set(session.tree.panesSortedByColumnThenRow.map(\.id))
            let payload = store.sessionInfoPayload(sessionID: session.id)
            topologyPayloadIDs = Set(payload?.allPanes.map(\.id) ?? [])
        }
    }

    // MARK: 1. Selected Session, mixed hidden + non-terminal state

    @Test func paneCountSourcesAgreeInSelectedSessionWithHiddenAndNonTerminalPanes() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let (terminalA, terminalHidden, nonTerminal) = makeMixedStateSession(in: session)
        store.hidePane(id: terminalHidden.id)

        #expect(session.tree.allPanes.count == 3)
        #expect(session.tree.visiblePanes.count == 2)

        let sources = CountSources(session: session, store: store)
        let expectedIDs: Set<UUID> = [terminalA.id, terminalHidden.id, nonTerminal.id]

        #expect(sources.treeAllPanesIDs == expectedIDs)
        #expect(sources.sidebarListingIDs == expectedIDs,
                "Sidebar's panesSortedByColumnThenRow must list exactly the Panes SplitTree.allPanes does")
        #expect(sources.topologyPayloadIDs == expectedIDs,
                "batty list's TopologySessionPayload.allPanes must report exactly the Panes SplitTree.allPanes does")

        // Count parity alone would pass on "right count, wrong Panes" —
        // the identity-set checks above are the load-bearing assertions;
        // these restate the headline "3 vs 2" shape as plain counts.
        #expect(session.tree.panesSortedByColumnThenRow.count == 3)
        #expect(store.topologyPayload().windows[0].sessions.first { $0.id == session.id }?.allPanes.count == 3)
    }

    // MARK: 2. A Session that is NOT the window's selected Session

    /// `TopologyPayload`/`batty list` walks every Session in every Window
    /// regardless of selection (`WindowRuntime.topologyPayload`), and the
    /// Sidebar renders one `DisclosureGroup` per Session via
    /// `ForEach(windowRuntime.sessions)` (`SessionSidebarView.swift`), also
    /// unconditional on selection. A count source that only worked for the
    /// selected Session would still pass every other test in this file.
    @Test func paneCountSourcesAgreeInANonSelectedSession() {
        let store = AppStateStore()
        let selected = store.sessions[0]
        let background = store.addSession(title: "Background")!
        store.windows[0].selectedSessionID = selected.id
        #expect(store.windows[0].selectedSessionID != background.id)

        let (terminalA, terminalHidden, nonTerminal) = makeMixedStateSession(in: background)
        store.hidePane(id: terminalHidden.id)

        let sources = CountSources(session: background, store: store)
        let expectedIDs: Set<UUID> = [terminalA.id, terminalHidden.id, nonTerminal.id]

        #expect(sources.treeAllPanesIDs == expectedIDs)
        #expect(sources.sidebarListingIDs == expectedIDs)
        #expect(sources.topologyPayloadIDs == expectedIDs)

        // Also confirmed via the multi-window `list` payload (`topologyPayload()`),
        // not just the single-Session `sessionInfo` payload above.
        let listPanes = store.topologyPayload().windows[0].sessions.first { $0.id == background.id }?.allPanes
        #expect(Set(listPanes?.map(\.id) ?? []) == expectedIDs)
    }

    // MARK: 3. All three sources stay in agreement after a Pane closes via its last Tab

    /// Extends `PaneHideTests.closingPaneDecrementsAllPanesCountWithNoStaleNode`
    /// (which only checked `SplitTree.allPanes`/`.visiblePanes`) to the
    /// Sidebar-listing and `batty list` sources too — a stale entry
    /// surviving in only one of the two tree walks is exactly the kind of
    /// divergence #0362 asked whether these sources could produce. Closes
    /// the Pane through `AppStateStore.closeTab(id:)` (the real Cmd-W
    /// cascade: `WindowRuntime.closeTab` removes the last Tab, finds the
    /// Pane now empty, and removes it from the tree) rather than calling
    /// `SplitTree.removePane` directly, so this exercises the actual close
    /// path, not just the tree primitive it bottoms out in.
    @Test func paneCountSourcesStayInAgreementAfterAPaneClosesViaItsLastTab() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let (terminalA, terminalToClose, nonTerminal) = makeMixedStateSession(in: session)
        store.hidePane(id: terminalToClose.id)
        let closedTabID = terminalToClose.activeTabID

        store.closeTab(id: closedTabID)

        let remainingIDs: Set<UUID> = [terminalA.id, nonTerminal.id]
        let sources = CountSources(session: session, store: store)

        #expect(session.tree.allPanes.count == 2)
        #expect(sources.treeAllPanesIDs == remainingIDs)
        #expect(sources.sidebarListingIDs == remainingIDs)
        #expect(sources.topologyPayloadIDs == remainingIDs)
        #expect(!sources.treeAllPanesIDs.contains(terminalToClose.id))
        #expect(!sources.sidebarListingIDs.contains(terminalToClose.id))
        #expect(!sources.topologyPayloadIDs.contains(terminalToClose.id),
                "batty list must not retain a stale entry for a Pane closed via its last Tab")
    }
}
