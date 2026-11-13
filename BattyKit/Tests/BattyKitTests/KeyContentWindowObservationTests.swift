// KeyContentWindowObservationTests.swift

import AppKit
import Foundation
import Observation
import Testing
@testable import BattyKit

private nonisolated final class ChangeFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
struct KeyContentWindowObservationTests {

    @Test func closeItemEnablementFollowsTheKeyContentWindow() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.openWindowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        defer {
            store.unregisterNSWindow(nsA)
            store.unregisterNSWindow(nsB)
        }
        b.selectedSessionID = nil
        #expect(a.selectedSession != nil)
        #expect(b.selectedSession == nil)

        store.contentWindowBecameKey(a.id)
        #expect(store.closeItemIsEnabled)

        let flag = ChangeFlag()
        withObservationTracking { _ = store.closeItemIsEnabled } onChange: { flag.fired = true }
        store.contentWindowBecameKey(b.id)

        #expect(flag.fired)
        #expect(!store.closeItemIsEnabled)
    }

    @Test func openProjectIDsNotifiesWhenAWindowWithAProjectSessionCloses() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.openWindowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        defer { store.unregisterNSWindow(nsA) }
        let projectID = UUID()
        b.addSession().projectID = projectID
        #expect(store.openProjectIDs.contains(projectID))

        let flag = ChangeFlag()
        withObservationTracking { _ = store.openProjectIDs } onChange: { flag.fired = true }
        store.unregisterNSWindow(nsB)
        store.removeWindow(id: b.id)

        #expect(flag.fired)
        #expect(!store.openProjectIDs.contains(projectID))
    }

    @Test func keyWindowChangeNotifiesKeyContentWindowReaders() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.openWindowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        defer {
            store.unregisterNSWindow(nsA)
            store.unregisterNSWindow(nsB)
        }
        store.contentWindowBecameKey(a.id)
        #expect(store.keyContentWindow === a)

        let flag = ChangeFlag()
        withObservationTracking { _ = store.keyContentWindow } onChange: { flag.fired = true }
        store.contentWindowBecameKey(b.id)

        #expect(flag.fired)
        #expect(store.keyContentWindow === b)
        #expect(store.keyContentWindowID == b.id)
    }

    @Test func sameWindowBecomingKeyAgainDoesNotNotify() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.openWindowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        defer {
            store.unregisterNSWindow(nsA)
            store.unregisterNSWindow(nsB)
        }
        store.contentWindowBecameKey(b.id)

        let flag = ChangeFlag()
        withObservationTracking { _ = store.keyContentWindow } onChange: { flag.fired = true }
        store.contentWindowBecameKey(b.id)

        #expect(!flag.fired)
        #expect(store.keyContentWindowID == b.id)
    }

    /// C is the newest registered window, so the newest-registered fallback
    /// can't produce B by accident.
    @Test func closingTheKeyWindowFallsBackToThePreviouslyKeyWindowAndNotifies() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.openWindowRuntime(for: WindowID())
        let c = store.openWindowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        let nsC = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        store.registerNSWindow(nsC, for: c.id)
        defer {
            store.unregisterNSWindow(nsB)
            store.unregisterNSWindow(nsC)
        }
        store.contentWindowBecameKey(b.id)
        store.contentWindowBecameKey(a.id)

        let flag = ChangeFlag()
        withObservationTracking { _ = store.keyContentWindow } onChange: { flag.fired = true }
        store.unregisterNSWindow(nsA)
        store.removeWindow(id: a.id)

        #expect(flag.fired)
        #expect(store.keyContentWindowID == b.id)
        #expect(store.keyContentWindow === b)
    }

    @Test func closingANonKeyWindowDoesNotChangeTheKeyContentWindow() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.openWindowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        defer { store.unregisterNSWindow(nsA) }
        store.contentWindowBecameKey(a.id)

        let flag = ChangeFlag()
        withObservationTracking { _ = store.keyContentWindowID } onChange: { flag.fired = true }
        store.unregisterNSWindow(nsB)
        store.removeWindow(id: b.id)

        #expect(!flag.fired)
        #expect(store.keyContentWindowID == a.id)
    }

    @Test func closingTheLastContentWindowClearsKeyContentWindow() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let nsA = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.contentWindowBecameKey(a.id)
        #expect(store.keyContentWindowID == a.id)

        store.unregisterNSWindow(nsA)
        store.removeWindow(id: a.id)

        #expect(store.keyContentWindowID == nil)
        #expect(store.keyContentWindow == nil)
    }

    @Test func didBecomeKeyNotificationForAContentWindowUpdatesKeyContentWindow() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.openWindowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        defer {
            store.unregisterNSWindow(nsA)
            store.unregisterNSWindow(nsB)
        }
        store.contentWindowBecameKey(a.id)

        let flag = ChangeFlag()
        withObservationTracking { _ = store.keyContentWindow } onChange: { flag.fired = true }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nsB)

        #expect(flag.fired)
        #expect(store.keyContentWindowID == b.id)
    }

    /// The unregistered titled window stands in for Settings, Help or the
    /// Project Editor.
    @Test func auxiliaryWindowBecomingKeyDoesNotChangeKeyContentWindow() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.openWindowRuntime(for: WindowID())
        let nsA = NSWindow()
        let nsB = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.registerNSWindow(nsB, for: b.id)
        defer {
            store.unregisterNSWindow(nsA)
            store.unregisterNSWindow(nsB)
        }
        store.contentWindowBecameKey(a.id)
        let auxiliary = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)

        let flag = ChangeFlag()
        withObservationTracking { _ = store.keyContentWindow } onChange: { flag.fired = true }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: auxiliary)

        #expect(!flag.fired)
        #expect(store.keyContentWindowID == a.id)
        #expect(store.keyContentWindow === a)
    }

    @Test func registeringAWindowDoesNotWriteKeyContentWindow() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let nsA = NSWindow()
        store.registerNSWindow(nsA, for: a.id)
        store.contentWindowBecameKey(a.id)
        defer { store.unregisterNSWindow(nsA) }

        let flag = ChangeFlag()
        withObservationTracking { _ = store.keyContentWindowID } onChange: { flag.fired = true }
        let b = store.openWindowRuntime(for: WindowID())
        let nsB = NSWindow()
        store.registerNSWindow(nsB, for: b.id)
        defer { store.unregisterNSWindow(nsB) }

        #expect(!flag.fired)
        #expect(store.keyContentWindowID == a.id)
    }

    @Test func keyContentWindowFallsBackToDefaultTargetWindowBeforeAnyWindowIsKey() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let a = store.windows[0]
        let b = store.openWindowRuntime(for: WindowID())
        let c = store.openWindowRuntime(for: WindowID())
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

        #expect(store.keyContentWindowID == nil)
        #expect(store.keyContentWindow === c)
    }
}
