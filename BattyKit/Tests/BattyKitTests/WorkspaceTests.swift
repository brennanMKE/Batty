// WorkspaceTests.swift

import Foundation
import Testing
@testable import BattyKit

struct WorkspaceTests {

    @Test func emptyWorkspaceIsCoherent() {
        let w = Workspace.empty()
        #expect(w.schemaVersion == Workspace.currentSchemaVersion)
        #expect(w.windows.count == 1)
        #expect(w.windows[0].sessions.count == 1)
        #expect(w.bellFeed.isEmpty)
    }

    @Test func workspaceRoundTripsThroughPrettyEncoder() throws {
        let session1 = Session.makeDefault(title: "frontend")
        let session2 = Session.makeDefault(title: "backend")
        let window = WindowState(
            frame: WindowFrame(x: 100, y: 200, width: 1280, height: 800),
            isZoomed: false,
            sidebarCollapsed: false,
            selectedSessionID: session1.id,
            sessions: [session1, session2]
        )
        let bell = BellFeedEntry(
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            windowID: window.id,
            sessionID: session1.id,
            paneID: session1.focusedPaneID,
            tabID: session1.root.firstPane.tabs[0].id,
            surfaceID: session1.root.firstPane.tabs[0].surfaceID,
            message: "build complete",
            seen: false
        )
        let original = Workspace(windows: [window], bellFeed: [bell])

        let data = try Workspace.prettyEncoder.encode(original)
        let decoded = try Workspace.decoder.decode(Workspace.self, from: data)
        #expect(decoded == original)
    }

    @Test func windowRequiresAtLeastOneSession() {
        let s = Session.makeDefault()
        let w = WindowState(sessions: [s])
        #expect(w.selectedSessionID == s.id)
    }

    @Test func windowSelectionDefaultsToFirstSession() {
        let s1 = Session.makeDefault(title: "a")
        let s2 = Session.makeDefault(title: "b")
        let w = WindowState(sessions: [s1, s2])
        #expect(w.selectedSessionID == s1.id)
    }

    @Test func bellFeedCapDropsOldestEntries() {
        var w = Workspace.empty()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let windowID = w.windows[0].id
        let sessionID = w.windows[0].sessions[0].id
        let paneID = w.windows[0].sessions[0].focusedPaneID
        let tabID = w.windows[0].sessions[0].root.firstPane.tabs[0].id
        let surfaceID = w.windows[0].sessions[0].root.firstPane.tabs[0].surfaceID

        for i in 0..<(Workspace.bellFeedCap + 50) {
            w.recordBell(BellFeedEntry(
                timestamp: baseDate.addingTimeInterval(Double(i)),
                windowID: windowID,
                sessionID: sessionID,
                paneID: paneID,
                tabID: tabID,
                surfaceID: surfaceID,
                message: "bell #\(i)"
            ))
        }

        #expect(w.bellFeed.count == Workspace.bellFeedCap)
        // Newest is at index 0
        #expect(w.bellFeed[0].message == "bell #\(Workspace.bellFeedCap + 49)")
        // Oldest still in the cap is at the tail
        let expectedOldestIndex = (Workspace.bellFeedCap + 50) - Workspace.bellFeedCap
        #expect(w.bellFeed.last?.message == "bell #\(expectedOldestIndex)")
    }

    @Test func schemaVersionIsPersisted() throws {
        let original = Workspace.empty()
        let data = try Workspace.prettyEncoder.encode(original)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"schemaVersion\""))
        #expect(json.contains(": 1"))
    }
}
