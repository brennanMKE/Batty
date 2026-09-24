// MultiWindowStoreTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

/// Tests for the multi-window `AppStateStore` additions in #0237:
/// lazy `windowRuntime(for:)` creation, NSWindow registry, and new-window
/// session seeding.
@MainActor
struct MultiWindowStoreTests {

    // MARK: - windowRuntime(for:) lazy creation

    @Test func windowRuntimeForInitialWindowIDReturnsExistingRuntime() {
        let store = AppStateStore()
        let initialID = store.windows[0].id
        let resolved = store.windowRuntime(for: initialID)
        #expect(resolved === store.windows[0])
        #expect(store.windows.count == 1)
    }

    @Test func windowRuntimeForNewIDCreatesNewRuntime() {
        let store = AppStateStore()
        let newID = WindowID()
        let runtime = store.windowRuntime(for: newID)
        #expect(store.windows.count == 2)
        #expect(runtime.id == newID)
    }

    @Test func windowRuntimeForNewIDSeedsOneSession() {
        let store = AppStateStore()
        let newID = WindowID()
        let runtime = store.windowRuntime(for: newID)
        #expect(runtime.sessions.count == 1)
        #expect(runtime.selectedSessionID != nil)
    }

    @Test func windowRuntimeCreationIsIdempotent() {
        let store = AppStateStore()
        let newID = WindowID()
        let first = store.windowRuntime(for: newID)
        let second = store.windowRuntime(for: newID)
        #expect(first === second)
        #expect(store.windows.count == 2)
    }

    @Test func windowRuntimeForNewIDHasDefaultSessionTitle() {
        let store = AppStateStore()
        let runtime = store.windowRuntime(for: WindowID())
        let title = runtime.sessions.first?.title ?? ""
        #expect(AppStateStore.isDefaultSessionTitle(title),
                "New window's first session should have a default title, got: \(title)")
    }

    // MARK: - NSWindow registry

    @Test func registerNSWindowMapsWindowToID() {
        let store = AppStateStore()
        let nsWindow = NSWindow()
        let windowID = WindowID()
        store.registerNSWindow(nsWindow, for: windowID)
        // keyWindowIsContentWindow and keyWindowRuntime depend on NSApp.keyWindow
        // which is not controllable in unit tests; test the registry directly
        // through the public unregister path.
        store.unregisterNSWindow(nsWindow)
        // After unregistering, a second registration should work cleanly.
        store.registerNSWindow(nsWindow, for: windowID)
        store.unregisterNSWindow(nsWindow)
    }

    @Test func unregisterNSWindowRemovesMapping() {
        let store = AppStateStore()
        let nsWindow = NSWindow()
        let windowID = WindowID()
        store.registerNSWindow(nsWindow, for: windowID)
        store.unregisterNSWindow(nsWindow)
        // After unregistering, registering a different ID should succeed (no
        // stale entry that could cause a collision).
        let otherID = WindowID()
        store.registerNSWindow(nsWindow, for: otherID)
        store.unregisterNSWindow(nsWindow)
    }

    // MARK: - anyContentWindowRuntime fallback ordering (#0437)

    /// `keyWindowRuntime()` reads `NSApplication.shared.keyWindow`, which
    /// (per `CrossWindowBehaviorTests`' documented finding) can't be
    /// controlled from this unit-test host, so `anyContentWindowRuntime()`
    /// always falls through to its registered-window fallback here — the
    /// same path a `batty <path>` invocation takes whenever Batty isn't the
    /// frontmost app and so has no key window at all.
    /// Round 1 review found the 2-window version of this test vacuous: with
    /// only two entries, `Dictionary`'s (unspecified) iteration order
    /// happened to match insertion order on every host run observed, so a
    /// regression back to `nsWindowMap.values.first` still passed. Registering
    /// dozens of windows per trial, across several independently seeded
    /// stores, makes an accidental match astronomically unlikely — the old
    /// code would have to keep landing on the exact newest-of-many entry by
    /// chance, repeatedly, across every trial.
    @Test func anyContentWindowRuntimePrefersMostRecentlyCreatedRegisteredWindow() {
        let windowCount = 24
        for trial in 0..<5 {
            let store = AppStateStore()
            var entries: [(runtime: WindowRuntime, nsWindow: NSWindow)] = []
            for _ in 0..<windowCount {
                let runtime = store.windowRuntime(for: WindowID())
                let nsWindow = NSWindow()
                store.registerNSWindow(nsWindow, for: runtime.id)
                entries.append((runtime, nsWindow))
            }

            let newest = entries[entries.count - 1]
            #expect(store.anyContentWindowRuntime() === newest.runtime,
                    "trial \(trial): should resolve the most recently created of \(windowCount) registered windows, not whichever entry nsWindowMap (a Dictionary) happens to enumerate first")

            // After unregistering the newest, the *next*-newest still-registered
            // window must be resolved — not just "some" window, and not the
            // newly-unregistered one still lingering in `windows`.
            store.unregisterNSWindow(newest.nsWindow)
            let nextNewest = entries[entries.count - 2]
            #expect(store.anyContentWindowRuntime() === nextNewest.runtime,
                    "trial \(trial): after unregistering the newest window, the next-newest still-registered window should be resolved")

            for entry in entries where entry.nsWindow !== newest.nsWindow {
                store.unregisterNSWindow(entry.nsWindow)
            }
        }
    }

    @Test func anyContentWindowRuntimeSkipsUnregisteredNewerWindow() {
        let store = AppStateStore()
        let w1 = store.windows[0]
        let nsWindow1 = NSWindow()
        store.registerNSWindow(nsWindow1, for: w1.id)

        // w2 exists in `windows` (e.g. mid-launch, before its NSWindow is
        // known) but is not yet registered — must not be preferred over the
        // registered w1 just because it's newer.
        _ = store.windowRuntime(for: WindowID())

        let resolved = store.anyContentWindowRuntime()
        #expect(resolved === w1,
                "an unregistered newer window must not be preferred over an older but registered one")

        store.unregisterNSWindow(nsWindow1)
    }

    // MARK: - New-window isolation

    @Test func twoWindowRuntimesHaveIndependentSessions() {
        let store = AppStateStore()
        let w1 = store.windows[0]
        let w2 = store.windowRuntime(for: WindowID())
        w1.addSession()
        #expect(w1.sessions.count == 2)
        #expect(w2.sessions.count == 1, "Second window's session count should be unaffected")
    }

    @Test func twoWindowRuntimesHaveIndependentSelection() {
        let store = AppStateStore()
        let w1 = store.windows[0]
        let w2 = store.windowRuntime(for: WindowID())
        let s2 = w2.addSession()
        w2.selectedSessionID = s2.id
        // w1's selection is unchanged
        #expect(w1.selectedSessionID != s2.id || w1.sessions.isEmpty)
    }
}
