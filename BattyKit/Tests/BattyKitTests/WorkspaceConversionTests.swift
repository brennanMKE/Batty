// WorkspaceConversionTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct WorkspaceConversionTests {

    @Test func sessionRuntimeRoundTripsThroughPersistedSession() {
        let original = SessionRuntime(title: "Frontend")
        original.tree.focusedPaneID = original.tree.root.firstLeafPaneID

        let persisted = Session(from: original)
        let restored = SessionRuntime(from: persisted)

        #expect(restored.id == original.id)
        #expect(restored.title == original.title)
        #expect(restored.tree.focusedPaneID == original.tree.focusedPaneID)
        #expect(restored.tree.allPanes.count == original.tree.allPanes.count)
    }

    @Test func splitTreePreservesShape() {
        let pane = PaneRuntime()
        let tree = SplitTree(root: .leaf(pane))
        tree.splitFocusedPane(direction: .horizontal)
        tree.splitFocusedPane(direction: .vertical)

        let session = SessionRuntime(title: "Demo", tree: tree)
        let persisted = Session(from: session)
        let restored = SessionRuntime(from: persisted)

        #expect(restored.tree.allPanes.count == session.tree.allPanes.count)
        #expect(restored.tree.allPanes.count == 3)
    }

    @Test func appStateStoreRoundTripsThroughWindowState() {
        let store = AppStateStore()
        store.addSession(title: "Backend")
        store.addSession(title: "Logs")

        let snapshot = WindowState(from: store)
        let restored = AppStateStore(from: snapshot)

        #expect(restored.sessions.count == store.sessions.count)
        #expect(restored.sessions.map(\.title) == store.sessions.map(\.title))
        #expect(restored.selectedSessionID == store.selectedSessionID)
    }

    @Test func workspaceJSONRoundTripsAcrossDecoderEncoder() throws {
        let store = AppStateStore()
        store.addSession(title: "Alpha")
        store.addSession(title: "Beta")
        store.selectedSessionID = store.sessions[1].id

        let workspace = Workspace(windows: [WindowState(from: store)])
        let data = try Workspace.prettyEncoder.encode(workspace)
        let decoded = try Workspace.decoder.decode(Workspace.self, from: data)

        #expect(decoded.windows.count == 1)
        #expect(decoded.windows[0].sessions.count == 3)
        #expect(decoded.windows[0].sessions.map(\.title) == ["Session 1", "Alpha", "Beta"])
        #expect(decoded.windows[0].selectedSessionID == store.selectedSessionID)
    }

    @Test func tabTitleOverridePersists() {
        let tab = TabRuntime(titleOverride: "logs")
        let pane = PaneRuntime(tabs: [tab])
        let session = SessionRuntime(tree: SplitTree(root: .leaf(pane)))

        let persisted = Session(from: session)
        let restored = SessionRuntime(from: persisted)

        #expect(restored.tree.root.firstLeafPane.tabs.first?.titleOverride == "logs")
    }
}
