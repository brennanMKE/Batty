// AppStateStoreTopologyPayloadTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `AppStateStore.topologyPayload()` and
/// `.sessionInfoPayload(sessionID:)` — the app-side source of the `list`
/// and `sessionInfo` XPC verbs (#0274).
@MainActor
struct AppStateStoreTopologyPayloadTests {

    // MARK: - topologyPayload()

    @Test func topologyPayloadReportsCurrentProcessID() {
        let store = AppStateStore()
        #expect(store.topologyPayload().pid == ProcessInfo.processInfo.processIdentifier)
    }

    @Test func topologyPayloadReportsOneWindowPerRuntimeWindow() {
        let store = AppStateStore()
        _ = store.windowRuntime(for: WindowID())
        #expect(store.topologyPayload().windows.count == store.windows.count)
        #expect(store.topologyPayload().windows.count == 2)
    }

    @Test func topologyPayloadWindowIDMatchesRuntimeWindowID() {
        let store = AppStateStore()
        let payload = store.topologyPayload()
        #expect(payload.windows.map(\.id) == store.windows.map { $0.id.value })
    }

    @Test func topologyPayloadSelectedSessionIDMatchesRuntime() {
        let store = AppStateStore()
        let session = store.addSession(title: "Extra")!
        store.windows[0].selectedSessionID = session.id
        let payload = store.topologyPayload()
        #expect(payload.windows[0].selectedSessionID == session.id)
    }

    @Test func topologyPayloadSessionCountAndNamesMatchRuntime() {
        let store = AppStateStore()
        _ = store.addSession(title: "Second")
        let payload = store.topologyPayload()
        #expect(payload.windows[0].sessions.count == store.windows[0].sessions.count)
        #expect(payload.windows[0].sessions.map(\.name) == store.windows[0].sessions.map(\.title))
    }

    @Test func topologyPayloadMarksOnlySelectedSessionActive() {
        let store = AppStateStore()
        let second = store.addSession(title: "Second")!
        store.windows[0].selectedSessionID = second.id
        let payload = store.topologyPayload()
        let activeFlags = Dictionary(uniqueKeysWithValues: payload.windows[0].sessions.map { ($0.id, $0.isActive) })
        #expect(activeFlags[second.id] == true)
        for session in store.windows[0].sessions where session.id != second.id {
            #expect(activeFlags[session.id] == false)
        }
    }

    @Test func topologyPayloadLeafPaneHasNoSplitShape() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.focusedPane
        let payload = store.topologyPayload()
        guard case .leaf(pane: let leafPane) = payload.windows[0].sessions[0].root else {
            Issue.record("expected a leaf root for a single-pane session")
            return
        }
        #expect(leafPane.id == pane.id)
        #expect(leafPane.isFocused)
    }

    @Test func topologyPayloadSplitShapeMatchesTree() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.focusedPane
        let paneB = session.tree.splitFocusedPane(direction: .horizontal, ratio: 0.5)
        let payload = store.topologyPayload()
        guard case .split(let id, let direction, let ratio, let left, let right) = payload.windows[0].sessions[0].root else {
            Issue.record("expected a split root after splitFocusedPane")
            return
        }
        guard case .split(let treeID, let treeDirection, let treeRatio, _, _) = session.tree.root else {
            Issue.record("expected the underlying tree to itself be a split")
            return
        }
        #expect(id == treeID)
        #expect(direction == .horizontal)
        #expect(direction.rawValue == treeDirection.rawValue)
        #expect(ratio == treeRatio)
        let payloadPaneIDs = Set([left, right].flatMap(\.allPanes).map(\.id))
        #expect(payloadPaneIDs == Set([paneA.id, paneB.id]))
    }

    /// `topologyPayloadSplitShapeMatchesTree` above only checks the root
    /// split and a *set* of leaf pane ids, which would still pass on a
    /// wrongly-shaped nested tree (e.g. children swapped, or a
    /// perpendicular split flattened). This walks a depth-2 tree
    /// (`horizontal(vertical(A, B), C)`) and compares the runtime
    /// `SplitTreeNode` against the payload `TopologySplitNodePayload`
    /// recursively, node by node.
    @Test func topologyPayloadNestedSplitShapeMatchesTreeRecursively() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.focusedPane
        let paneB = session.tree.splitFocusedPane(direction: .vertical)
        session.tree.focusedPaneID = paneA.id
        let paneC = session.tree.splitFocusedPane(direction: .horizontal)

        let payload = store.topologyPayload()
        let payloadRoot = payload.windows[0].sessions[0].root

        func assertStructurallyEqual(_ node: SplitTreeNode, _ payloadNode: TopologySplitNodePayload) {
            switch (node, payloadNode) {
            case (.leaf(let pane), .leaf(let panePayload)):
                #expect(pane.id == panePayload.id)
            case (.split(let id, let direction, let ratio, let left, let right), .split(let payloadID, let payloadDirection, let payloadRatio, let payloadLeft, let payloadRight)):
                #expect(id == payloadID)
                #expect(direction.rawValue == payloadDirection.rawValue)
                #expect(ratio == payloadRatio)
                assertStructurallyEqual(left, payloadLeft)
                assertStructurallyEqual(right, payloadRight)
            default:
                Issue.record("tree/payload shape mismatch at this node — leaf/split kind disagrees")
            }
        }

        assertStructurallyEqual(session.tree.root, payloadRoot)
        // The recursive walk above only proves shape agreement; also pin
        // traversal order against SplitTreeNode.allLeafPanes so a
        // structurally-symmetric-but-swapped tree can't slip through.
        #expect(payloadRoot.allPanes.map(\.id) == session.tree.allPanes.map(\.id))
        #expect(Set(payloadRoot.allPanes.map(\.id)) == Set([paneA.id, paneB.id, paneC.id]))
    }

    @Test func topologyPayloadReportsHiddenPane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.focusedPane
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        store.hidePane(id: paneB.id)
        let payload = store.topologyPayload()
        let panes = payload.windows[0].sessions[0].allPanes
        #expect(panes.first { $0.id == paneB.id }?.isHidden == true)
        #expect(panes.first { $0.id == paneA.id }?.isHidden == false)
    }

    @Test func topologyPayloadTabTitleAndActiveFlagMatchRuntime() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.focusedPane
        let secondTab = pane.addTab()
        let payload = store.topologyPayload()
        let panePayload = payload.windows[0].sessions[0].allPanes[0]
        #expect(panePayload.activeTabID == secondTab.id)
        let activeTabPayload = panePayload.tabs.first { $0.id == secondTab.id }
        #expect(activeTabPayload?.isActive == true)
        let firstTabPayload = panePayload.tabs.first { $0.id != secondTab.id }
        #expect(firstTabPayload?.isActive == false)
        #expect(panePayload.tabs.allSatisfy { !$0.title.isEmpty })
    }

    /// #0315 review round 1, finding 3: a non-terminal pane's one
    /// `TabRuntime` is a structural placeholder `PaneView` never renders —
    /// `batty list`/`batty list --tabs` must not show agents a
    /// targetable-looking terminal tab on it.
    @Test func topologyPayloadReportsEmptyTabsForANonTerminalPane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let terminalPane = session.focusedPane
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .gitStatus)!

        let payload = store.topologyPayload()
        let panePayload = payload.windows[0].sessions[0].allPanes.first { $0.id == nonTerminalPane.id }

        #expect(panePayload != nil)
        #expect(panePayload?.tabs.isEmpty == true)
        // The terminal sibling is unaffected.
        let terminalPanePayload = payload.windows[0].sessions[0].allPanes.first { $0.id == terminalPane.id }
        #expect(terminalPanePayload?.tabs.isEmpty == false)
    }

    // MARK: - sessionInfoPayload(sessionID:)

    @Test func sessionInfoPayloadResolvesExplicitSessionID() {
        let store = AppStateStore()
        let target = store.addSession(title: "Target")!
        let payload = store.sessionInfoPayload(sessionID: target.id)
        #expect(payload?.id == target.id)
        #expect(payload?.name == "Target")
    }

    @Test func sessionInfoPayloadReturnsNilForUnknownSessionID() {
        let store = AppStateStore()
        #expect(store.sessionInfoPayload(sessionID: UUID()) == nil)
    }

    @Test func sessionInfoPayloadFallsBackToSelectedSessionWhenNilAndNoKeyWindow() {
        let store = AppStateStore()
        let second = store.addSession(title: "Second")!
        store.windows[0].selectedSessionID = second.id
        // No NSWindow registered in this unit-test context, so
        // keyWindowRuntime() is nil and the fallback resolves to
        // windows.first's selectedSession — exactly the "focused session"
        // seam #0257's env-var fallback will slot ahead of.
        let payload = store.sessionInfoPayload(sessionID: nil)
        #expect(payload?.id == second.id)
        #expect(payload?.isActive == true)
    }

    @Test func sessionInfoPayloadExplicitIDBeatsSelectedSession() {
        let store = AppStateStore()
        let selected = store.sessions[0]
        let other = store.addSession(title: "Other")!
        store.windows[0].selectedSessionID = selected.id
        // Explicit --session always wins over the focused-session fallback,
        // even though `other` isn't selected.
        let payload = store.sessionInfoPayload(sessionID: other.id)
        #expect(payload?.id == other.id)
        #expect(payload?.isActive == false)
    }

    @Test func sessionInfoPayloadResolvesSessionInNonKeyWindow() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())
        let sessionInW2 = w2.sessions[0]
        let payload = store.sessionInfoPayload(sessionID: sessionInW2.id)
        #expect(payload?.id == sessionInW2.id)
    }

    // MARK: - Reads must not mutate (#0274 binding rule)

    /// A cross-session `sessionInfo` read (an explicit id for a session
    /// that is neither the window's selected session nor holds focus) must
    /// leave every window's selection and every session's focused pane
    /// untouched — this is the load-bearing guarantee both #0257 and #0274
    /// call out explicitly for reads. Asserted against the store's own
    /// state, not merely "the call didn't crash."
    @Test func sessionInfoReadOfBackgroundSessionDoesNotChangeSelectionOrFocus() {
        let store = AppStateStore()
        let selected = store.sessions[0]
        let background = store.addSession(title: "Background")!
        store.windows[0].selectedSessionID = selected.id

        // Give the background session a split with a non-default focused pane
        // and a non-default active tab, so any accidental reset is visible.
        let bgPaneA = background.focusedPane
        let bgPaneB = background.tree.splitFocusedPane(direction: .vertical)
        background.tree.focusedPaneID = bgPaneB.id
        let bgSecondTab = bgPaneB.addTab()
        bgPaneB.activeTabID = bgSecondTab.id

        let selectedSessionIDBefore = store.windows[0].selectedSessionID
        let selectedFocusedPaneBefore = selected.tree.focusedPaneID
        let selectedActiveTabBefore = selected.focusedPane.activeTabID
        let backgroundFocusedPaneBefore = background.tree.focusedPaneID
        let backgroundActiveTabBefore = bgPaneB.activeTabID

        let payload = store.sessionInfoPayload(sessionID: background.id)

        #expect(payload?.id == background.id)
        #expect(payload?.focusedPaneID == bgPaneB.id)
        #expect(store.windows[0].selectedSessionID == selectedSessionIDBefore,
                "reading a background session's info must not change the window's selected session")
        #expect(selected.tree.focusedPaneID == selectedFocusedPaneBefore,
                "reading a background session's info must not change the selected session's focus")
        #expect(selected.focusedPane.activeTabID == selectedActiveTabBefore,
                "reading a background session's info must not change the selected session's active tab")
        #expect(background.tree.focusedPaneID == backgroundFocusedPaneBefore,
                "reading a session's own info must not change its own focused pane")
        #expect(bgPaneB.activeTabID == backgroundActiveTabBefore,
                "reading a session's own info must not change its own active tab")
        _ = bgPaneA
    }

    /// Same guarantee for `topologyPayload()` (`list`) — walking every
    /// window/session/pane/tab must not disturb any of them.
    @Test func topologyPayloadDoesNotChangeSelectionOrFocusAcrossWindows() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())
        let w1Session = store.sessions[0]
        let w2Session = w2.sessions[0]
        store.windows[0].selectedSessionID = w1Session.id
        w2.selectedSessionID = w2Session.id

        let w1FocusBefore = w1Session.tree.focusedPaneID
        let w2FocusBefore = w2Session.tree.focusedPaneID
        let w1SelectedBefore = store.windows[0].selectedSessionID
        let w2SelectedBefore = w2.selectedSessionID

        _ = store.topologyPayload()

        #expect(store.windows[0].selectedSessionID == w1SelectedBefore)
        #expect(w2.selectedSessionID == w2SelectedBefore)
        #expect(w1Session.tree.focusedPaneID == w1FocusBefore)
        #expect(w2Session.tree.focusedPaneID == w2FocusBefore)
    }
}
