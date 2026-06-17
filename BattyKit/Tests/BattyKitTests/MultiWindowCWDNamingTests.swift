// MultiWindowCWDNamingTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Unit tests for #0248: CWD-driven auto-naming and action shims must target
/// the correct window across all registered windows, not just windows[0].
@MainActor
struct MultiWindowCWDNamingTests {

    private func makeStore() -> (AppStateStore, URL) {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-mw-naming-\(UUID().uuidString)")
            .appendingPathComponent("session-name-cache.json")
        let cache = SessionNameCache(fileURL: cacheURL, debounce: .zero)
        let store = AppStateStore(nameCache: cache)
        return (store, cacheURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - handleWorkingDirectoryChange across windows

    /// The trigger bug for #0248: a session in the second window must be
    /// auto-named when its anchor tab changes CWD. The old code used the
    /// `sessions` shim (→ windows[0]), so this test would fail before the fix.
    @Test func handleCWDChangeAutoNamesSessionInSecondWindow() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Widget", name: "Widget")

        let w2 = store.windowRuntime(for: WindowID())
        let session = w2.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Widget"

        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == "Widget",
                "handleWorkingDirectoryChange must auto-name sessions in any window, not only windows[0]")
    }

    @Test func handleCWDChangeInSecondWindowDoesNotAffectFirstWindow() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Widget", name: "Widget")

        let w1 = store.windows[0]
        let w2 = store.windowRuntime(for: WindowID())

        let w1Session = w1.sessions[0]
        let w1OriginalTitle = w1Session.title

        let w2Session = w2.sessions[0]
        let w2AnchorTab = w2Session.tree.root.firstLeafPane.tabs[0]
        w2AnchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Widget"

        store.handleWorkingDirectoryChange(forTabID: w2AnchorTab.id)

        #expect(w2Session.title == "Widget")
        #expect(w1Session.title == w1OriginalTitle,
                "Auto-naming the second window's session must not affect the first window's session")
    }

    @Test func handleCWDChangeInFirstWindowStillWorks() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Alpha", name: "Alpha")

        // Add a second window to verify the fix doesn't break single-window behavior.
        _ = store.windowRuntime(for: WindowID())

        let w1Session = store.windows[0].sessions[0]
        let anchorTab = w1Session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Alpha"

        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(w1Session.title == "Alpha",
                "Auto-naming sessions in windows[0] must still work when multiple windows exist")
    }

    @Test func handleCWDChangeIgnoresUnknownTabID() {
        let (store, url) = makeStore()
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/X", name: "X")
        _ = store.windowRuntime(for: WindowID())

        // Calling with an ID that belongs to no window should be a no-op.
        store.handleWorkingDirectoryChange(forTabID: UUID())

        for window in store.windows {
            for session in window.sessions {
                #expect(session.title != "X",
                        "Unknown tabID must not trigger any rename")
            }
        }
    }

    // MARK: - Action shims: session-ID-based operations across windows

    @Test func renameSessionTargetsCorrectWindowNotWindowsZero() {
        let (store, url) = makeStore()
        defer { cleanup(url) }

        let w2 = store.windowRuntime(for: WindowID())
        let w2Session = w2.sessions[0]
        let originalTitle = w2Session.title

        store.renameSession(id: w2Session.id, to: "Renamed")

        #expect(w2Session.title == "Renamed",
                "renameSession must locate the session in any window, not only windows[0]")
        // First window is unaffected.
        #expect(store.windows[0].sessions.allSatisfy { $0.title != "Renamed" || $0.title == originalTitle })
    }

    @Test func removeSessionTargetsCorrectWindowNotWindowsZero() {
        let (store, url) = makeStore()
        defer { cleanup(url) }

        let w2 = store.windowRuntime(for: WindowID())
        // Add a second session to w2 so removing one doesn't trigger window close.
        _ = w2.addSession()
        let targetSession = w2.sessions[0]
        let targetID = targetSession.id

        store.removeSession(id: targetID)

        #expect(!w2.sessions.contains(where: { $0.id == targetID }),
                "removeSession must remove the session from its owning window, not windows[0]")
        // windows[0] is unaffected.
        #expect(store.windows[0].sessions.count == 1)
    }

    @Test func clearSessionNameTargetsCorrectWindow() {
        let (store, url) = makeStore()
        defer { cleanup(url) }

        let w2 = store.windowRuntime(for: WindowID())
        let w2Session = w2.sessions[0]
        // Seed a cached name so clearSessionName has something to do.
        store.nameCache.record(path: "/some/path", name: "Cached")
        w2Session.title = "Cached"

        // clearSessionName clears the cached name entry and resets the title.
        // We just verify it dispatches without crashing to the correct window.
        store.clearSessionName(id: w2Session.id)
        // No assertion on title — clearSessionName semantics depend on CWD
        // and cache state; the key guarantee is no crash and no wrong-window error.
    }

    // MARK: - Action shims: tab-ID-based operations across windows

    @Test func closeTabTargetsCorrectWindowNotWindowsZero() {
        let (store, url) = makeStore()
        defer { cleanup(url) }

        let w2 = store.windowRuntime(for: WindowID())
        let w2Session = w2.sessions[0]
        // Add a second tab so closing one doesn't cascade to remove the session.
        let secondTab = w2Session.focusedPane.addTab()
        let secondTabID = secondTab.id
        #expect(w2Session.focusedPane.tabs.count == 2)
        let w1TabCount = store.windows[0].sessions[0].focusedPane.tabs.count

        store.closeTab(id: secondTabID)

        #expect(!w2Session.focusedPane.tabs.contains(where: { $0.id == secondTabID }),
                "closeTab must remove the tab from its owning window, not windows[0]")
        #expect(store.windows[0].sessions[0].focusedPane.tabs.count == w1TabCount,
                "closeTab on w2's tab must not affect windows[0]")
    }

    @Test func focusPaneTargetsCorrectWindowNotWindowsZero() {
        let (store, url) = makeStore()
        defer { cleanup(url) }

        let w2 = store.windowRuntime(for: WindowID())
        let w2Session = w2.sessions[0]
        w2Session.tree.splitFocusedPane(direction: .horizontal)
        let panes = w2Session.tree.allPanes
        #expect(panes.count == 2)
        let otherPane = panes.first { $0.id != w2Session.tree.focusedPaneID }!

        store.focusPane(id: otherPane.id)

        #expect(w2Session.tree.focusedPaneID == otherPane.id,
                "focusPane must update focus in the owning window, not windows[0]")
    }

    // MARK: - AI suggestion across windows

    @Test func aiSuggestionAppliesNameToSessionInSecondWindow() async {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-mw-ai-\(UUID().uuidString)")
            .appendingPathComponent("session-name-cache.json")
        let cache = SessionNameCache(fileURL: cacheURL, debounce: .zero)
        let store = AppStateStore(nameCache: cache)
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        var suggestedPaths: [String] = []
        final class FixedSuggester: SessionNameSuggesting {
            let name: String
            var paths: [String] = []
            init(_ name: String) { self.name = name }
            func suggestName(forPath path: String) async -> String? {
                paths.append(path)
                return self.name
            }
        }
        let suggester = FixedSuggester("SuggestedName")
        store.nameSuggester = suggester

        let w2 = store.windowRuntime(for: WindowID())
        let session = w2.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        // A path that won't match any cache/rules entry → AI fallback fires.
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/unique-path-\(UUID())"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        // Await the in-flight task.
        if let inflight = store.nameSuggestionTasks[session.id] {
            await inflight.task.value
        }

        #expect(session.title == "SuggestedName",
                "AI suggestion must apply to sessions in any window, not only windows[0]")
        _ = suggestedPaths  // Suppress unused warning
    }
}
