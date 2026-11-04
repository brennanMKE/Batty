// ClosedWindowRuntimeTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

/// SwiftUI can re-evaluate views for a window after `removeWindow`. A closed
/// id must stay closed: a revived runtime carries a Session, which fails the
/// quit guard and leaves the app running with no windows (#0546).
@MainActor
struct ClosedWindowRuntimeTests {
    private func makeStore() -> AppStateStore {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-closed-window-\(UUID().uuidString)")
        let store = AppStateStore(
            nameCache: SessionNameCache(fileURL: base.appendingPathComponent("cache.json")),
            projectsFileURL: base.appendingPathComponent("projects.json")
        )
        store.terminateHandler = {}
        return store
    }

    @Test func runtimeForPresentedWindowIsNilForARemovedWindow() {
        let store = makeStore()
        let closed = store.windows[0].id
        store.removeWindow(id: closed)

        #expect(store.runtimeForPresentedWindow(closed) == nil)
        #expect(store.windows.isEmpty)
    }

    @Test func runtimeForPresentedWindowCreatesForANeverSeenID() throws {
        let store = makeStore()
        let id = WindowID()

        let runtime = try #require(store.runtimeForPresentedWindow(id))

        #expect(runtime.id == id)
        #expect(store.windows.count == 2)
    }

    @Test func runtimeForPresentedWindowReturnsTheLiveRuntime() {
        let store = makeStore()
        let live = store.windows[0]

        #expect(store.runtimeForPresentedWindow(live.id) === live)
        #expect(store.windows.count == 1)
    }

    @Test func existingWindowRuntimeNeverCreates() {
        let store = makeStore()
        let live = store.windows[0]

        #expect(store.existingWindowRuntime(for: live.id) === live)
        #expect(store.existingWindowRuntime(for: WindowID()) == nil)
        #expect(store.windows.count == 1)
    }

    @Test func rootWindowViewInitDoesNotReviveARemovedWindow() {
        let store = makeStore()
        let closed = store.windows[0].id
        store.removeWindow(id: closed)

        _ = RootWindowView(windowID: closed, store: store)

        #expect(store.windows.isEmpty)
    }

    @Test func closingOneOfTwoWindowsLeavesNoPhantomAfterARebuild() {
        let store = makeStore()
        let survivor = store.windows[0]
        let closed = store.openWindowRuntime(for: WindowID()).id
        store.removeWindow(id: closed)

        _ = RootWindowView(windowID: closed, store: store)

        #expect(store.windows.map(\.id) == [survivor.id])
    }

    @Test func windowDelegateWillCloseForARemovedWindowCreatesNoRuntime() {
        let store = makeStore()
        let survivor = store.windows[0]
        let closed = store.openWindowRuntime(for: WindowID()).id
        let delegate = WindowDelegate(windowID: closed, store: store)
        store.removeWindow(id: closed)

        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        #expect(store.windows.map(\.id) == [survivor.id])
    }

    @Test func windowDelegateShouldCloseForARemovedWindowAllowsTheClose() {
        let store = makeStore()
        let survivor = store.windows[0]
        let closed = store.openWindowRuntime(for: WindowID()).id
        let delegate = WindowDelegate(windowID: closed, store: store)
        store.removeWindow(id: closed)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false

        #expect(delegate.windowShouldClose(window))
        #expect(store.windows.map(\.id) == [survivor.id])
    }

    @Test func newWindowIDAfterTheLastWindowClosedIsNotTheClosedID() throws {
        let store = makeStore()
        let closed = store.windows[0].id
        store.removeWindow(id: closed)

        let id = store.windowIDForNewWindow()

        #expect(id != closed)
        let runtime = try #require(store.runtimeForPresentedWindow(id))
        #expect(runtime.id == id)
        #expect(store.windows.count == 1)
    }
}
