// AppStateStoreCWDChangeTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
final class AppStateStoreCWDChangeTests {
    /// A `UserDefaults` suite private to one test invocation, isolated from
    /// `.standard` — every concurrent `./build.sh unit` run on the machine
    /// shares `.standard` through one `cfprefsd` (#0426). These tests never
    /// pin the naming toggles, so they rely on the untouched-suite default
    /// matching `.standard`'s untouched default: both read the keys absent
    /// and fall through to `true`.
    private let testDefaults = TestDefaults()

    @MainActor deinit { testDefaults.tearDown() }

    private func makeStore() -> (AppStateStore, URL) {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-cwd-change-\(UUID().uuidString)")
            .appendingPathComponent("session-name-cache.json")
        let cache = SessionNameCache(fileURL: cacheURL, debounce: .zero)
        let store = AppStateStore(nameCache: cache, preferences: testDefaults.defaults)
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
        let pane = session.focusedPaneAnyKind
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
        let sessionB = store.addSession()!
        let anchorB = sessionB.tree.root.firstLeafPane.tabs[0]
        #expect(sessionB.title == "Batty")

        // User cd's the new session to a non-project folder: name must drop "Batty".
        anchorB.terminal.configuration.workingDirectory = "/Users/test/no-project-here"
        store.handleWorkingDirectoryChange(forTabID: anchorB.id)

        #expect(sessionB.title == "Session 2")
    }

    /// A session created with an explicit title is pinned (titleOverride) so
    /// the now-reliable cwd auto-naming (#0227) can't clobber it. Without this,
    /// createSession("Beta") was overwritten the moment the surface reported a
    /// cwd, which broke the multi-session UI tests.
    @Test func explicitlyTitledSessionIsNotClobberedByCDChange() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Batty", name: "Batty")

        let session = store.addSession(title: "Beta")!
        #expect(session.titleOverride == true)

        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == "Beta")
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

    // MARK: - #0436: pwd-callback ordering

    /// Documents the underlying platform hazard, using the real
    /// `TerminalDelegateProxy`/`TerminalViewState` types (not fakes, and not
    /// going through any Batty wiring): at the pinned libghostty-spm
    /// revision (`a2565ccf`), `TerminalViewState.terminalDidChangeWorkingDirectory`
    /// wraps its write in `publishSoon`, which resolves to
    /// `terminalRunOnMainNextTurn` — an unconditional `DispatchQueue.main.async`
    /// (its own doc comment: "never inline, even when the caller is already
    /// on the main thread") — so a consumer that re-reads
    /// `terminal.workingDirectory` synchronously inside
    /// `onWorkingDirectoryChange` still observes the previous directory, not
    /// the one just reported. This is why the production installer below
    /// uses the callback's `path` argument instead of re-reading the
    /// property.
    @Test func pwdCallbackFiresBeforeTheDeferredTerminalPropertyWriteLands() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]

        var callbackFired = false
        var observedDuringCallback: String?
        anchorTab.terminalDelegate.onWorkingDirectoryChange = { _ in
            callbackFired = true
            observedDuringCallback = anchorTab.terminal.workingDirectory
        }

        anchorTab.terminalDelegate.terminalDidChangeWorkingDirectory("/Users/test/BattyCdProbe")

        #expect(callbackFired)
        #expect(observedDuringCallback == nil, "the deferred write hasn't landed yet when the callback fires")
    }

    /// Drives the actual production entry points `PaneView` installs —
    /// `AppStateStore.wireWorkingDirectoryReporting(for:)` (the installer)
    /// and, through it, `applyReportedWorkingDirectory(_:to:)` — rather than
    /// a test-local closure that could silently diverge from what `PaneView`
    /// really wires (the round-1 review finding: a hand-rolled test closure
    /// let every mutation of the production wiring pass). The first `cd`
    /// into a project directory must rename the session on that same
    /// report, not one report later. `SessionCwdRenameTests` in the Tart VM
    /// covers this end-to-end; this is the host-side unit coverage.
    @Test func cdRenamesSessionOnTheSameReportNotOneReportLater() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/BattyCdProbe", name: "BattyCdProbe")

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/home"

        store.wireWorkingDirectoryReporting(for: anchorTab)
        anchorTab.terminalDelegate.terminalDidChangeWorkingDirectory("/Users/test/BattyCdProbe")

        #expect(
            session.title == "BattyCdProbe",
            "the first cd should rename the session on the same report, not one report later"
        )
        #expect(anchorTab.workingDirectory == "/Users/test/BattyCdProbe")
    }

    /// A resolvable-but-different anchor tab (a second session, e.g.) must
    /// not be renamed by another tab's pwd report — the installer wires
    /// each tab's own callback to that tab's own id, and
    /// `applyReportedWorkingDirectory(_:to:)` acts on the `tab` it's given,
    /// never on whichever tab happens to be first.
    @Test func wiredCallbackOnlyRenamesItsOwnSession() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/BattyCdProbe", name: "BattyCdProbe")

        let sessionA = store.sessions[0]
        let anchorA = sessionA.tree.root.firstLeafPane.tabs[0]
        let sessionB = store.addSession()!
        let anchorB = sessionB.tree.root.firstLeafPane.tabs[0]

        store.wireWorkingDirectoryReporting(for: anchorA)
        store.wireWorkingDirectoryReporting(for: anchorB)
        anchorA.terminalDelegate.terminalDidChangeWorkingDirectory("/Users/test/BattyCdProbe")

        #expect(sessionA.title == "BattyCdProbe")
        #expect(sessionB.title != "BattyCdProbe")
    }
}
