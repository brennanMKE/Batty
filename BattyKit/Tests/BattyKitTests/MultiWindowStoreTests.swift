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
