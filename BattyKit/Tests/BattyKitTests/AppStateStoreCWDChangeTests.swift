// AppStateStoreCWDChangeTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct AppStateStoreCWDChangeTests {

    private func makeStore() -> (AppStateStore, URL) {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-cwd-change-\(UUID().uuidString)")
            .appendingPathComponent("session-name-cache.json")
        let cache = SessionNameCache(fileURL: cacheURL, debounce: .zero)
        let store = AppStateStore(nameCache: cache)
        return (store, cacheURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func anchorTabCWDChangeAppliesCachedName() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Batty", name: "Batty")

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == "Batty")
    }

    @Test func anchorTabCWDChangeWithNoCacheHitLeavesTitleAlone() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        let session = store.sessions[0]
        let originalTitle = session.title
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/never-seen"

        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == originalTitle)
    }

    @Test func nonAnchorTabCWDChangeIsIgnored() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Batty", name: "Batty")

        let session = store.sessions[0]
        let originalTitle = session.title
        let pane = session.focusedPane
        let secondTab = pane.addTab()
        secondTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"

        store.handleWorkingDirectoryChange(forTabID: secondTab.id)

        #expect(session.title == originalTitle)
    }

    @Test func anchorTabCWDChangeIsIdempotent() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Batty", name: "Batty")

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"

        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        let firstApplied = session.title
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == firstApplied)
        #expect(session.title == "Batty")
    }

    @Test func anchorTabCWDChangeWithEmptyPathIsNoOp() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Batty", name: "Batty")

        let session = store.sessions[0]
        let originalTitle = session.title
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = nil

        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == originalTitle)
    }

    @Test func renameThenCDBackAppliesCachedNameAgain() {
        let (store, url) = makeStore()
        defer { cleanup(url) }

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"
        store.renameSession(id: session.id, to: "Batty")

        session.title = "Misc"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == "Batty")
    }
}
