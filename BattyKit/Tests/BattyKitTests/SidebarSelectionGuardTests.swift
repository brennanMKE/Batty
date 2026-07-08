// SidebarSelectionGuardTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Guards for #0258: sidebar List selection must never leave the window
/// without a selected session while sessions exist. macOS List offers
/// implicit selection values from ForEach identity (pane ids) and nil
/// (empty-area click); `setSelectedSession` rejects both.
@MainActor
struct SidebarSelectionGuardTests {

    @Test func acceptsValidSessionID() {
        let store = AppStateStore()
        let s1 = store.sessions[0]
        let s2 = store.addSession()
        #expect(store.selectedSessionID == s2.id)

        store.windows[0].setSelectedSession(id: s1.id)

        #expect(store.selectedSessionID == s1.id)
    }

    @Test func rejectsPaneID() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let newPane = session.tree.splitFocusedPane(direction: .horizontal)

        store.windows[0].setSelectedSession(id: newPane.id)

        #expect(store.selectedSessionID == session.id)
        #expect(store.windows[0].selectedSession != nil)
    }

    @Test func rejectsNilWhileSessionsExist() {
        let store = AppStateStore()
        let session = store.sessions[0]

        store.windows[0].setSelectedSession(id: nil)

        #expect(store.selectedSessionID == session.id)
    }

    @Test func rejectsForeignUUID() {
        let store = AppStateStore()
        let session = store.sessions[0]

        store.windows[0].setSelectedSession(id: UUID())

        #expect(store.selectedSessionID == session.id)
    }

    @Test func rejectsOtherWindowsSessionID() {
        let store = AppStateStore()
        let first = store.sessions[0]
        let otherWindow = store.windowRuntime(for: WindowID())
        let foreign = otherWindow.addSession()

        store.windows[0].setSelectedSession(id: foreign.id)

        #expect(store.windows[0].selectedSessionID == first.id)
    }

    @Test func equalValueWriteKeepsSelection() {
        let store = AppStateStore()
        let session = store.sessions[0]

        store.windows[0].setSelectedSession(id: session.id)

        #expect(store.selectedSessionID == session.id)
    }
}
