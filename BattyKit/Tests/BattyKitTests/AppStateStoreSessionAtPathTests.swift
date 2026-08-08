// AppStateStoreSessionAtPathTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct AppStateStoreSessionAtPathTests {

    @Test func addSessionWithExplicitWorkingDirectoryCarriesPath() {
        let store = AppStateStore()
        let path = "/Users/test/Developer/MyProject"

        let session = store.addSession(workingDirectory: path)!

        let configuredPath = session.focusedPane.activeTab?.terminal.configuration.workingDirectory
        #expect(configuredPath == path)
    }

    @Test func addSessionWithExplicitPathOverridesCWDInheritance() {
        let store = AppStateStore()
        let source = store.sessions[0]
        source.focusedPane.activeTab?.terminal.configuration.workingDirectory = "/Users/test/inherited"
        let explicit = "/Users/test/explicit"

        let session = store.addSession(workingDirectory: explicit)!

        let configuredPath = session.focusedPane.activeTab?.terminal.configuration.workingDirectory
        #expect(configuredPath == explicit)
    }

    @Test func addSessionWithNilWorkingDirectoryFallsBackToInheritance() {
        let store = AppStateStore()
        let source = store.sessions[0]
        source.focusedPane.activeTab?.terminal.configuration.workingDirectory = "/Users/test/inherited"

        let session = store.addSession(workingDirectory: nil)!

        let configuredPath = session.focusedPane.activeTab?.terminal.configuration.workingDirectory
        #expect(configuredPath == "/Users/test/inherited")
    }

    @Test func addSessionWithWorkingDirectoryAppliesCachedName() {
        let store = AppStateStore()
        let path = "/Users/test/Developer/CoolApp"
        store.nameCache.record(path: path, name: "Cool App")

        let session = store.addSession(workingDirectory: path)!

        #expect(session.title == "Cool App")
    }
}
