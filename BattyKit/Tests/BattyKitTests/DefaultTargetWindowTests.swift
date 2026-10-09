// DefaultTargetWindowTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

/// Tests for `AppStateStore.defaultTargetWindow()` (#0439): the single
/// resolver every no-target Window fallback delegates to. Fixtures are
/// deliberately non-default and, wherever the tier under test could
/// otherwise coincide with a lower tier's answer (e.g. the most-recently-key
/// window also happening to be the newest-registered one), an extra window
/// is added specifically to break that coincidence — a regression to any
/// single-tier fallback (`windows.first`, "newest registered", or "currently
/// key" alone) must fail these tests, not pass by accident (per the
/// #0310/#0396 "non-default fixture" lesson).
///
/// `keyWindowRuntime()` reads `NSApplication.shared.keyWindow`, which (per
/// `MultiWindowStoreTests`' documented finding) can't be driven from this
/// unit-test host, so every test below exercises tiers 2–4 of the policy —
/// the tiers that matter for the #0439 bug, which is specifically about the
/// no-currently-key-window case (Batty inactive, or no window ever made
/// key).
@MainActor
struct DefaultTargetWindowTests {

    // MARK: - Tier ordering

    /// Four windows, oldest to newest: A, B, C, D. B then C become key, in
    /// that order (C most recent). All four stay registered. The newest
    /// registered window is D and the oldest is A — neither is the expected
    /// answer, so this can't pass by falling back to either.
    @Test func defaultTargetWindowPrefersMostRecentlyKeyOverNewestRegistered() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.windowRuntime(for: WindowID())
        let c = store.windowRuntime(for: WindowID())
        let d = store.windowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        let nsC = NSWindow()
        let nsD = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        store.registerNSWindow(nsC, for: c.id)
        store.registerNSWindow(nsD, for: d.id)
        defer {
            store.unregisterNSWindow(nsA)
            store.unregisterNSWindow(nsB)
            store.unregisterNSWindow(nsC)
            store.unregisterNSWindow(nsD)
        }

        store.noteContentWindowBecameKey(b.id)
        store.noteContentWindowBecameKey(c.id)

        #expect(store.defaultTargetWindow()?.id == c.id,
                "most recently key (C) must win over newest registered (D) and oldest (A)")
    }

    /// With no window ever key, the newest *registered* window wins — not
    /// the oldest.
    @Test func defaultTargetWindowFallsBackToNewestRegisteredWhenNoWindowHasEverBeenKey() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.windowRuntime(for: WindowID())
        let c = store.windowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        let nsC = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        store.registerNSWindow(nsC, for: c.id)
        defer {
            store.unregisterNSWindow(nsA)
            store.unregisterNSWindow(nsB)
            store.unregisterNSWindow(nsC)
        }

        #expect(store.defaultTargetWindow()?.id == c.id)
    }

    /// With nothing registered at all, `defaultTargetWindow()` still
    /// resolves `windows.first` (tier 4) — the headless/unit-test last
    /// resort `addSession` relies on directly.
    @Test func defaultTargetWindowFallsBackToWindowsFirstWhenNothingRegistered() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        _ = store.windowRuntime(for: WindowID())

        #expect(store.defaultTargetWindow()?.id == a.id)
    }

    // MARK: - Pruning on window close

    /// A, B, C, D created in that order. B then C are noted key (C most
    /// recent). C's window then closes via the real teardown pair
    /// (`unregisterNSWindow` + `removeWindow`, matching
    /// `WindowDelegate.windowWillClose`). The resolver must fall back to B —
    /// the previous most-recently-key window — not to D (the newest
    /// survivor, which a bug that stopped filtering candidates by
    /// registration would return) and not to A (the oldest).
    @Test func closingTheMostRecentlyKeyWindowFallsBackToThePreviousMostRecentlyKeyWindow() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.windowRuntime(for: WindowID())
        let c = store.windowRuntime(for: WindowID())
        let d = store.windowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        let nsC = NSWindow()
        let nsD = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        store.registerNSWindow(nsC, for: c.id)
        store.registerNSWindow(nsD, for: d.id)

        store.noteContentWindowBecameKey(b.id)
        store.noteContentWindowBecameKey(c.id)

        store.unregisterNSWindow(nsC)
        store.removeWindow(id: c.id)

        defer {
            store.unregisterNSWindow(nsA)
            store.unregisterNSWindow(nsB)
            store.unregisterNSWindow(nsD)
        }

        #expect(store.defaultTargetWindow()?.id == b.id,
                "must fall back to B (previous most-recently-key), not D (newest survivor) or A (oldest)")
    }

    /// Direct test of the pruning step itself, not just of resolution
    /// staying correct around it. `defaultTargetWindow()`'s tier 2 already
    /// filters every candidate through `registeredIDs.contains` and
    /// `windows.first(where:)`, so a stale, unpruned id is harmless to
    /// *resolution* regardless of whether `unregisterNSWindow`/
    /// `removeWindow` ever actually prune `recentlyKeyWindowIDs` — a test
    /// that only reads `defaultTargetWindow()`'s return value can't tell
    /// "pruned" apart from "merely filtered out at read time." This reads
    /// the tracked order's element count directly
    /// (`recentlyKeyWindowIDsCountForTesting`) to confirm the array itself
    /// shrinks, guarding against unbounded growth over a long-running
    /// session that keeps opening and closing windows.
    @Test func unregisterNSWindowAndRemoveWindowBothPruneTheTrackedOrder() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.windowRuntime(for: WindowID())
        let c = store.windowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        let nsC = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        store.registerNSWindow(nsC, for: c.id)

        store.noteContentWindowBecameKey(a.id)
        store.noteContentWindowBecameKey(b.id)
        store.noteContentWindowBecameKey(c.id)
        #expect(store.recentlyKeyWindowIDsCountForTesting == 3)

        store.unregisterNSWindow(nsC)
        #expect(store.recentlyKeyWindowIDsCountForTesting == 2,
                "unregisterNSWindow must prune the closed window's id")

        store.removeWindow(id: b.id)
        #expect(store.recentlyKeyWindowIDsCountForTesting == 1,
                "removeWindow must prune too, independent of unregisterNSWindow")

        defer { store.unregisterNSWindow(nsA) }
    }

    // MARK: - noteContentWindowBecameKey ordering

    /// Re-noting an already-tracked id moves it to the most-recent position
    /// rather than leaving the earlier position (and appending a duplicate)
    /// — otherwise a window that became key once, long ago, could still
    /// beat a window that became key more recently, if the older one
    /// happened to sort first for some unrelated reason.
    @Test func noteContentWindowBecameKeyMovesAnExistingIDToMostRecentRatherThanDuplicating() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.windowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        defer {
            store.unregisterNSWindow(nsA)
            store.unregisterNSWindow(nsB)
        }

        store.noteContentWindowBecameKey(a.id)
        store.noteContentWindowBecameKey(b.id)
        store.noteContentWindowBecameKey(a.id) // A becomes key again, after B.

        #expect(store.recentlyKeyWindowIDsCountForTesting == 2,
                "re-noting A must not append a duplicate")
        #expect(store.defaultTargetWindow()?.id == a.id,
                "re-noting A must move it to the most-recent position, not leave B as most recent")
    }

    // MARK: - NSWindow.didBecomeKeyNotification wiring

    /// Posts the real notification (not `noteContentWindowBecameKey`
    /// directly) against registered `NSWindow`s, proving the app-wide
    /// observer installed in `init` actually updates the order — not just
    /// the pure method it calls. A third window, C, is created after B and
    /// stays registered but is never posted as key, so it is the newest
    /// registered window throughout — if the observer wiring were broken
    /// and tier 2 never got fed, the resolver would fall through to C, not
    /// to A or B, making the distinction observable.
    @Test func didBecomeKeyNotificationUpdatesTheMostRecentlyKeyOrder() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.windowRuntime(for: WindowID())
        let c = store.windowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        let nsC = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        store.registerNSWindow(nsC, for: c.id)
        defer {
            store.unregisterNSWindow(nsA)
            store.unregisterNSWindow(nsB)
            store.unregisterNSWindow(nsC)
        }

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nsA)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nsB)

        #expect(store.defaultTargetWindow()?.id == b.id,
                "B was posted key most recently; C (newest registered, never posted key) must lose to it")

        store.unregisterNSWindow(nsB)
        #expect(store.defaultTargetWindow()?.id == a.id,
                "after B unregisters, must fall back to A (previous most-recently-key), not C (newest registered survivor)")
    }

    /// A `didBecomeKeyNotification` for an `NSWindow` this store never
    /// registered (e.g. Settings, Help, a panel) must not perturb the order
    /// — `handleWindowDidBecomeKey` filters through `nsWindowMap`.
    @Test func didBecomeKeyNotificationForAnUnregisteredWindowIsIgnored() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.windowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        defer {
            store.unregisterNSWindow(nsA)
            store.unregisterNSWindow(nsB)
        }

        let unrelated = NSWindow()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: unrelated)

        #expect(store.recentlyKeyWindowIDsCountForTesting == 0,
                "an unregistered window becoming key must not be tracked at all")
        // No window has been noted key through the tracked path, so the
        // resolver must still fall through to tier 3 (newest registered: B).
        #expect(store.defaultTargetWindow()?.id == b.id)
    }

    // MARK: - Every no-target payload path follows the same policy

    /// A, B, C created in that order; B is noted key (not C, the newest
    /// registered window — breaking the coincidence that would otherwise let
    /// tier 3 mask a broken tier 2). Every no-target resolution helper — the
    /// CLI/XPC fallbacks, the menu/command-palette fallback, and `addSession`
    /// (the URL-handler path) — must all resolve B, not A and not C. This is
    /// the #0439 defect made concrete: before the fix, these disagreed (the
    /// XPC/menu fallbacks resolved the oldest window, the URL-handler
    /// fallback resolved whichever window was newest-by-construction).
    @Test func everyNoTargetHelperResolvesTheMostRecentlyKeyWindow() throws {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.windowRuntime(for: WindowID())
        let c = store.windowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        let nsC = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        store.registerNSWindow(nsC, for: c.id)
        defer {
            store.unregisterNSWindow(nsA)
            store.unregisterNSWindow(nsB)
            store.unregisterNSWindow(nsC)
        }

        store.noteContentWindowBecameKey(a.id)
        store.noteContentWindowBecameKey(b.id)

        let bSession = try #require(b.selectedSession)
        let bPane = bSession.focusedPaneAnyKind

        #expect(store.defaultTargetWindow()?.id == b.id)
        #expect(store.keyWindowOrFirstRegistered()?.id == b.id)
        #expect(store.focusedSessionIDFallback() == bSession.id)
        #expect(store.focusedSessionIDFallback() != a.selectedSession?.id)
        #expect(store.focusedSessionIDFallback() != c.selectedSession?.id)
        #expect(store.focusedPaneIDFallback() == bPane.id)
        #expect(store.focusedTabIDFallback() == bPane.activeTabID)
        #expect(store.sessionInfoPayload(sessionID: nil)?.id == bSession.id)

        let sessionsBefore = b.sessions.count
        let newSession = store.addSession(workingDirectory: "/tmp")
        #expect(newSession != nil)
        #expect(b.sessions.count == sessionsBefore + 1,
                "addSession (the batty <path> URL-handler path) must land in B too")
    }
}
