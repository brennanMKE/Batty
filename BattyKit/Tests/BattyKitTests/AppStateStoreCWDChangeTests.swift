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

    @Test func userRenameSetsTitleOverrideAndPinsAgainstFurtherCDChanges() {
        let (store, url) = makeStore()
        defer { cleanup(url) }

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"
        store.renameSession(id: session.id, to: "Frontend")
        #expect(session.titleOverride == true)
        #expect(session.title == "Frontend")

        store.nameCache.record(path: "/Users/test/Other", name: "OtherName")
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Other"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == "Frontend")
        #expect(session.titleOverride == true)
    }

    // MARK: - #0213 single-pane live-update behavior

    @Test func leavingProjectDirResetsTitleToDefault() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Batty", name: "Batty")

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        #expect(session.title == "Batty")

        anchorTab.terminal.configuration.workingDirectory = "/Users/test/no-project-here"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == "Session 1")
        #expect(session.titleOverride == false)
    }

    @Test func movingBetweenCachedProjectsUpdatesTitle() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Alpha", name: "Alpha")
        store.nameCache.record(path: "/Users/test/Developer/Beta", name: "Beta")

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Alpha"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        #expect(session.title == "Alpha")

        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Beta"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == "Beta")
    }

    @Test func splittingSessionFreezesAutoNamingAtCurrentTitle() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Alpha", name: "Alpha")
        store.nameCache.record(path: "/Users/test/Developer/Beta", name: "Beta")

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Alpha"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        #expect(session.title == "Alpha")

        session.tree.splitFocusedPane(direction: .horizontal)
        #expect(session.tree.allPanes.count == 2)

        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Beta"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == "Alpha")
    }

    @Test func userRenameIsNotClobberedWhenLeavingProjectDir() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Batty", name: "Batty")

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"
        store.renameSession(id: session.id, to: "Frontend")
        #expect(session.titleOverride == true)

        anchorTab.terminal.configuration.workingDirectory = "/Users/test/somewhere-else"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == "Frontend")
    }

    // Repro for the reported release blocker: a session created via addSession
    // (not the launch session) inherits the current cwd and its name, but must
    // still reset when the user cd's it elsewhere.
    @Test func newlyCreatedSessionResetsNameAfterLeavingInheritedProjectDir() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Batty", name: "Batty")

        // Launch session sits in the Batty project dir and is named for it.
        let sessionA = store.sessions[0]
        let anchorA = sessionA.tree.root.firstLeafPane.tabs[0]
        anchorA.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"
        store.handleWorkingDirectoryChange(forTabID: anchorA.id)
        #expect(sessionA.title == "Batty")

        // Create a new session while in Batty — it inherits the cwd and name.
        let sessionB = store.addSession()
        let anchorB = sessionB.tree.root.firstLeafPane.tabs[0]
        #expect(sessionB.title == "Batty")

        // User cd's the new session to a non-project folder: name must drop "Batty".
        anchorB.terminal.configuration.workingDirectory = "/Users/test/no-project-here"
        store.handleWorkingDirectoryChange(forTabID: anchorB.id)

        #expect(sessionB.title == "Session 2")
    }

    @Test func resolveAutoTitleReturnsCacheHitWhenPresent() {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-resolve-\(UUID().uuidString)")
            .appendingPathComponent("session-name-cache.json")
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let cache = SessionNameCache(fileURL: cacheURL, debounce: .zero)
        cache.record(path: "/Users/test/Developer/Cached", name: "CachedName")

        let title = AppStateStore.resolveAutoTitle(
            forCWD: "/Users/test/Developer/Cached",
            sessionIndex: 4,
            cache: cache,
            resolver: ProjectNameResolver.shared
        )

        #expect(title == "CachedName")
    }

    @Test func resolveAutoTitleFallsBackToDefaultSessionN() {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-resolve-\(UUID().uuidString)")
            .appendingPathComponent("session-name-cache.json")
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let cache = SessionNameCache(fileURL: cacheURL, debounce: .zero)

        let title = AppStateStore.resolveAutoTitle(
            forCWD: "/var/empty/no-project-here",
            sessionIndex: 2,
            cache: cache,
            resolver: ProjectNameResolver.shared
        )

        #expect(title == "Session 3")
    }
}
