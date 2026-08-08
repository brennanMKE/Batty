// AppStateStoreSessionCWDTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct AppStateStoreSessionCWDTests {

    @Test func newSessionInheritsFocusedPaneCWD() {
        let store = AppStateStore()
        let source = store.sessions[0]
        source.focusedPane.activeTab?.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"

        let created = store.addSession()!

        #expect(
            created.focusedPane.activeTab?.terminal.configuration.workingDirectory
                == "/Users/test/Developer/Batty"
        )
    }

    @Test func newSessionFallsBackWhenNoSelectedSession() {
        let store = AppStateStore()
        store.selectedSessionID = nil

        let created = store.addSession()!

        #expect(created.focusedPane.activeTab?.terminal.configuration.workingDirectory == nil)
    }

    @Test func newSessionInheritsFromCurrentlySelectedSourceAcrossMany() {
        let store = AppStateStore()
        let first = store.sessions[0]
        first.focusedPane.activeTab?.terminal.configuration.workingDirectory = "/tmp/first"
        let second = store.addSession()!
        second.focusedPane.activeTab?.terminal.configuration.workingDirectory = "/tmp/second"
        store.selectedSessionID = second.id

        let created = store.addSession()!

        #expect(created.focusedPane.activeTab?.terminal.configuration.workingDirectory == "/tmp/second")
    }
}
