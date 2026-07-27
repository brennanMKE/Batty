// BattyContextInjectionTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers #0281's env-injection plumbing: `BATTY_SESSION_ID`/`BATTY_PANE_ID`/
/// `BATTY_TAB_ID` land in the libghostty config text (via the `env =`
/// directive — see `TabRuntime.applyShellAndAppearancePreferences`) for
/// every tab, regardless of which path created it (initial session tree,
/// `addTab`, `splitFocusedPane`, `splitFullDimension`). Asserted against
/// `tab.terminal.renderedConfig`, the merged text libghostty actually
/// parses — the most direct proof the env vars would reach a real surface,
/// short of spawning one (out of bounds for a headless unit test).
@MainActor
struct BattyContextInjectionTests {

    // MARK: - Standalone TabRuntime (not yet attached)

    @Test func freshTabCarriesOnlyItsOwnTabID() {
        let tab = TabRuntime()
        #expect(tab.paneID == nil)
        #expect(tab.sessionID == nil)
        #expect(tab.terminal.renderedConfig.contains("env = BATTY_TAB_ID=\(tab.id.uuidString)"))
        #expect(!tab.terminal.renderedConfig.contains("BATTY_PANE_ID"))
        #expect(!tab.terminal.renderedConfig.contains("BATTY_SESSION_ID"))
    }

    @Test func attachContextSetsIdsAndRewritesRenderedConfig() {
        let tab = TabRuntime()
        let paneID = UUID()
        let sessionID = UUID()
        tab.attachContext(paneID: paneID, sessionID: sessionID)
        #expect(tab.paneID == paneID)
        #expect(tab.sessionID == sessionID)
        #expect(tab.terminal.renderedConfig.contains("env = BATTY_TAB_ID=\(tab.id.uuidString)"))
        #expect(tab.terminal.renderedConfig.contains("env = BATTY_PANE_ID=\(paneID.uuidString)"))
        #expect(tab.terminal.renderedConfig.contains("env = BATTY_SESSION_ID=\(sessionID.uuidString)"))
    }

    /// Proves the `env = KEY=VALUE` directive is genuinely accepted by the
    /// real bundled libghostty, not just documented — `setTerminalConfiguration`
    /// silently reverts to the previous (working) config and reports
    /// `lastConfigurationIssue` if `ghostty_config_load_file` diagnoses the
    /// generated config text as invalid. If the directive were rejected,
    /// `attachContextSetsIdsAndRewritesRenderedConfig` above would fail too
    /// (the env lines would never make it into `renderedConfig`); this test
    /// asserts the specific failure mode directly.
    @Test func attachContextProducesNoConfigurationIssue() {
        let tab = TabRuntime()
        tab.attachContext(paneID: UUID(), sessionID: UUID())
        #expect(tab.terminal.controller.lastConfigurationIssue == nil)
    }

    @Test func attachContextIsIdempotentForSameIds() {
        let tab = TabRuntime()
        let paneID = UUID()
        let sessionID = UUID()
        tab.attachContext(paneID: paneID, sessionID: sessionID)
        let renderedAfterFirst = tab.terminal.renderedConfig
        tab.attachContext(paneID: paneID, sessionID: sessionID)
        #expect(tab.terminal.renderedConfig == renderedAfterFirst)
    }

    // MARK: - SessionRuntime.init attaches the initial tree

    @Test func sessionRuntimeInitAttachesDefaultSinglePaneTab() {
        let session = SessionRuntime()
        let pane = session.tree.root.firstLeafPane
        let tab = pane.tabs[0]
        #expect(pane.sessionID == session.id)
        #expect(tab.paneID == pane.id)
        #expect(tab.sessionID == session.id)
        #expect(tab.terminal.renderedConfig.contains("env = BATTY_SESSION_ID=\(session.id.uuidString)"))
        #expect(tab.terminal.renderedConfig.contains("env = BATTY_PANE_ID=\(pane.id.uuidString)"))
    }

    @Test func sessionRuntimeInitAttachesACallerSuppliedTree() {
        let pane = PaneRuntime(tabs: [TabRuntime()])
        let tree = SplitTree(root: .leaf(pane))
        let session = SessionRuntime(tree: tree)
        #expect(pane.sessionID == session.id)
        #expect(pane.tabs[0].sessionID == session.id)
        #expect(pane.tabs[0].paneID == pane.id)
    }

    // MARK: - PaneRuntime.addTab

    @Test func addTabOnAttachedPaneAttachesTheNewTab() {
        let session = SessionRuntime()
        let pane = session.tree.root.firstLeafPane
        let newTab = pane.addTab()
        #expect(newTab.paneID == pane.id)
        #expect(newTab.sessionID == session.id)
        #expect(newTab.terminal.renderedConfig.contains("env = BATTY_SESSION_ID=\(session.id.uuidString)"))
    }

    @Test func addTabOnUnattachedPaneLeavesNewTabUnattached() {
        let pane = PaneRuntime()
        let newTab = pane.addTab()
        #expect(newTab.paneID == nil)
        #expect(newTab.sessionID == nil)
    }

    // MARK: - SplitTree.splitFocusedPane / splitFullDimension

    @Test func splitFocusedPaneAttachesNewPaneToSession() {
        let session = SessionRuntime()
        let newPane = session.tree.splitFocusedPane(direction: .vertical)
        #expect(newPane.sessionID == session.id)
        #expect(newPane.tabs[0].paneID == newPane.id)
        #expect(newPane.tabs[0].sessionID == session.id)
        #expect(newPane.tabs[0].terminal.renderedConfig.contains("env = BATTY_PANE_ID=\(newPane.id.uuidString)"))
    }

    @Test func splitFullDimensionAttachesNewPaneToSession() {
        let session = SessionRuntime()
        let newPane = session.tree.splitFullDimension(direction: .horizontal)
        #expect(newPane.sessionID == session.id)
        #expect(newPane.tabs[0].sessionID == session.id)
        #expect(newPane.tabs[0].paneID == newPane.id)
    }

    @Test func splitOnAStandaloneUnattachedTreeLeavesNewPaneUnattached() {
        let tree = SplitTree()
        let newPane = tree.splitFocusedPane(direction: .vertical)
        #expect(newPane.sessionID == nil)
        #expect(newPane.tabs[0].sessionID == nil)
    }

    @Test func splitPaneCarriesItsOwnIdsNotTheParents() {
        // Every pane created by a split gets its own tab/pane identity —
        // never the originating pane's — even though both now share the
        // same session (#0257: "env is a hint, not truth" for cross-session
        // moves, but within a session ids are always per-pane/per-tab).
        let session = SessionRuntime()
        let originalPane = session.tree.root.firstLeafPane
        let newPane = session.tree.splitFocusedPane(direction: .vertical, inheritingFrom: originalPane)
        #expect(newPane.id != originalPane.id)
        #expect(newPane.tabs[0].id != originalPane.tabs[0].id)
        #expect(newPane.tabs[0].terminal.renderedConfig.contains("BATTY_PANE_ID=\(newPane.id.uuidString)"))
        #expect(!newPane.tabs[0].terminal.renderedConfig.contains("BATTY_PANE_ID=\(originalPane.id.uuidString)"))
    }
}
