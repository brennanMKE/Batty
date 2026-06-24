// BattyURLHandlerRoutingTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

/// Tests for the #0251 fix: `batty <path>` session routing targets the correct
/// `WindowRuntime` and the working directory is preserved to the session's tab.
///
/// These tests exercise the store-level logic headlessly (no real NSWindow, no
/// live ghostty surface). The live GUI round-trip (batty <path> → selected
/// session at the path in the front window) requires user sign-off.
@MainActor
struct BattyURLHandlerRoutingTests {

    // MARK: - initialWindowID (#0251 phantom-runtime fix)

    /// `initialWindowID` must return the ID of `windows[0]` — the runtime seeded
    /// in `AppStateStore.init`. `BattyApp.defaultValue` returns this so the first
    /// SwiftUI content window reuses the existing runtime instead of creating a
    /// phantom second one.
    @Test func initialWindowIDMatchesWindowsZeroID() {
        let store = AppStateStore()
        #expect(store.initialWindowID == store.windows[0].id)
    }

    /// Creating a second `WindowRuntime` must not change `initialWindowID`.
    @Test func initialWindowIDIsStableAfterAdditionalWindowRuntimes() {
        let store = AppStateStore()
        let originalID = store.initialWindowID
        _ = store.windowRuntime(for: WindowID())
        #expect(store.initialWindowID == originalID)
        #expect(store.windows.count == 2)
    }

    // MARK: - anyContentWindowRuntime (#0251 URL-handler fallback)

    /// With no NSWindow registered, `anyContentWindowRuntime()` returns nil —
    /// the unit-test context where `addSession` falls back to `windows[0]`.
    @Test func anyContentWindowRuntimeIsNilWithoutRegisteredNSWindow() {
        let store = AppStateStore()
        // No registerNSWindow call — unit-test context.
        #expect(store.anyContentWindowRuntime() == nil)
    }

    /// With exactly one registered NSWindow, `anyContentWindowRuntime()` returns
    /// the runtime for that window. This simulates the URL-handler path when a
    /// window is live but the NSApplication key-window state is unavailable.
    @Test func anyContentWindowRuntimeReturnsRegisteredWindowRuntime() {
        let store = AppStateStore()
        let windowID = store.windows[0].id
        let nsWindow = NSWindow()
        store.registerNSWindow(nsWindow, for: windowID)
        defer { store.unregisterNSWindow(nsWindow) }
        let resolved = store.anyContentWindowRuntime()
        #expect(resolved?.id == windowID)
    }

    // MARK: - addSession(workingDirectory:) targets windows[0] in unit-test context

    /// In a headless unit test (no NSWindow registered), `addSession` falls back
    /// to `windows[0]`. After the #0251 fix, `windows[0]` IS the runtime for the
    /// first on-screen window (because `BattyApp.defaultValue` now returns
    /// `initialWindowID`), so this path is correct in the app and continues to
    /// work in tests.
    @Test func addSessionWithCWDTargetsWindowsZeroInHeadlessContext() {
        let store = AppStateStore()
        let sessionCountBefore = store.windows[0].sessions.count
        store.addSession(workingDirectory: "/usr")
        #expect(store.windows[0].sessions.count == sessionCountBefore + 1)
    }

    /// `addSession` must select the new session immediately. The URL handler
    /// relies on this so the incoming session is visible without a manual click.
    @Test func addSessionWithCWDSelectsNewSession() {
        let store = AppStateStore()
        let newSession = store.addSession(workingDirectory: "/usr")
        #expect(store.windows[0].selectedSessionID == newSession.id)
    }

    // MARK: - Working directory reaches the tab (#0251 Suspect 2)

    /// The working directory passed to `addSession` must survive to the new
    /// session's first tab's `terminal.configuration.workingDirectory`. This is
    /// the value that `TerminalHostStore.terminalView(for:windowID:)` copies to
    /// `view.configuration` before `addSubview` (the spawn point).
    @Test func addSessionWithCWDPreservesWorkingDirectoryOnFirstTab() {
        let store = AppStateStore()
        let path = "/Users/test/Developer/MyProject"
        let session = store.addSession(workingDirectory: path)
        let firstTab = session.tree.root.firstLeafPane.tabs[0]
        #expect(firstTab.terminal.configuration.workingDirectory == path)
    }

    /// An empty working directory must not be forwarded to the tab (avoids
    /// passing empty string to libghostty which could override the shell default).
    @Test func addSessionWithEmptyCWDDoesNotSetWorkingDirectory() {
        let store = AppStateStore()
        let session = store.addSession(workingDirectory: "")
        let firstTab = session.tree.root.firstLeafPane.tabs[0]
        // Empty explicit CWD is guarded out, and a fresh store has no source
        // session to inherit from, so the tab must carry no working directory.
        let cwd = firstTab.terminal.configuration.workingDirectory
        #expect(cwd == nil)
    }

    // MARK: - addSession routes to registered window, not phantom

    /// With one registered NSWindow, `addSession` must land in the registered
    /// window's runtime, not in a different runtime. This is the core regression
    /// check for #0251: before the fix, sessions landed in `windows[0]` even
    /// when the visible window had a different `WindowRuntime`.
    @Test func addSessionLandsInRegisteredWindowRuntime() {
        let store = AppStateStore()
        let windowID = store.windows[0].id
        let nsWindow = NSWindow()
        store.registerNSWindow(nsWindow, for: windowID)
        defer { store.unregisterNSWindow(nsWindow) }
        let sessionsBefore = store.windows[0].sessions.count
        store.addSession(workingDirectory: "/usr")
        #expect(store.windows[0].sessions.count == sessionsBefore + 1,
                "Session must land in the registered window's runtime")
    }

    /// When the URL handler adds a session, the session must be selected in its
    /// owning runtime. Selection drives what the user sees in the sidebar and
    /// the detail view.
    @Test func addSessionViaURLHandlerSelectsNewSessionInItsRuntime() {
        let store = AppStateStore()
        let path = "/usr/local"
        guard let url = SessionURLBuilder.buildURL(absolutePath: path) else {
            Issue.record("buildURL returned nil for \(path)")
            return
        }
        let sessionsBefore = store.windows[0].sessions.count
        BattyURLHandler.handle(url, store: store)
        #expect(store.windows[0].sessions.count == sessionsBefore + 1)
        let newSession = store.windows[0].sessions.last
        #expect(store.windows[0].selectedSessionID == newSession?.id,
                "New session created by batty:// URL must be selected")
    }

    /// The session created by `BattyURLHandler.handle` must carry the requested
    /// working directory on its first tab's configuration.
    @Test func urlHandlerNewSessionHasRequestedWorkingDirectory() {
        let store = AppStateStore()
        let path = "/usr/local"
        guard let url = SessionURLBuilder.buildURL(absolutePath: path) else {
            Issue.record("buildURL returned nil for \(path)")
            return
        }
        BattyURLHandler.handle(url, store: store)
        let session = store.windows[0].sessions.last
        let firstTab = session?.tree.root.firstLeafPane.tabs[0]
        #expect(firstTab?.terminal.configuration.workingDirectory == path,
                "Session created by batty:// URL must have the requested path on its first tab")
    }
}
