// WindowIDRegistrarTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

/// #0437: `WindowIDRegistrar` used to defer registration via
/// `DispatchQueue.main.async` from `updateNSView`, leaving a gap — at least
/// one main-queue turn wide — during which a newly-opened window could
/// already be `NSApp.keyWindow` while still absent from `nsWindowMap`. The
/// fix moves registration into `RegistrarNSView.viewDidMoveToWindow`, an
/// AppKit callback that fires as the view is inserted into a window's view
/// hierarchy.
///
/// These tests drive the real `RegistrarNSView` class against a real
/// `NSWindow` — not `AppStateStore.registerNSWindow` directly — so a
/// regression back to the deferred-async shape is caught. They assert
/// immediately after `addSubview`, with no `await`, sleep, or run-loop spin
/// in between: AGENTS.md's "Asynchronous tests" rule bars waiting for async
/// work to finish, and here that is also the point — a `DispatchQueue.main
/// .async`-based implementation could not pass an assertion made before any
/// run loop turn has occurred.
///
/// Each test constructs its own fresh `AppStateStore()` and passes it to
/// `RegistrarNSView` directly (round 2 review: the store is now a required
/// parameter, not a `.shared` default — #0359's "no silent default" rule),
/// so these tests need no cross-test isolation reasoning about the
/// process-wide singleton at all.
@MainActor
struct WindowIDRegistrarTests {

    private func makeWindowWithContentView() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        return window
    }

    @Test func viewDidMoveToWindowRegistersSynchronouslyWithNoRunLoopTurn() {
        let store = AppStateStore()
        let windowID = WindowID()
        let window = makeWindowWithContentView()
        let registrar = RegistrarNSView(windowID: windowID, store: store)

        window.contentView?.addSubview(registrar)

        #expect(store.registeredContentWindowCount == 1,
                "adding the registrar view to a real window's content view should register it immediately, before any run-loop turn")

        store.unregisterNSWindow(window)
        #expect(store.registeredContentWindowCount == 0)
    }

    @Test func viewDidMoveToWindowRegistrationIsIdempotentAcrossRepeatedInsertion() {
        let store = AppStateStore()
        let windowID = WindowID()
        let window = makeWindowWithContentView()
        let registrar = RegistrarNSView(windowID: windowID, store: store)

        window.contentView?.addSubview(registrar)
        // Re-parenting within the same window's view tree fires
        // viewDidMoveToWindow again (still the same window) — must not
        // double-count the registration.
        registrar.removeFromSuperview()
        window.contentView?.addSubview(registrar)

        #expect(store.registeredContentWindowCount == 1,
                "re-inserting the same view into the same window must not create a second registry entry")

        store.unregisterNSWindow(window)
    }

    /// The "never retried" half of #0437's bug: the pre-fix
    /// `DispatchQueue.main.async` block checked `nsView.window` exactly
    /// once and gave up silently if it was still `nil` — if the view's
    /// hierarchy wasn't yet attached to a window at that moment, the window
    /// was never registered, full stop. This test builds exactly that
    /// detached-hierarchy shape (a registrar inside a plain container view
    /// with no window) and confirms nothing is registered — then attaches
    /// the *container*, never touching the registrar directly, and confirms
    /// registration happens anyway. That's `viewDidMoveToWindow`'s actual
    /// guarantee: AppKit calls it on every view in a subtree when an
    /// ancestor's window changes, so there is no "gave up and never
    /// retried" state to reach once a view exists anywhere in a hierarchy
    /// that could later be attached.
    @Test func viewDidMoveToWindowRegistersOnceADetachedHierarchyIsLaterAttachedToAWindow() {
        let store = AppStateStore()
        let windowID = WindowID()
        let registrar = RegistrarNSView(windowID: windowID, store: store)
        let container = NSView(frame: .zero)
        container.addSubview(registrar)

        #expect(store.registeredContentWindowCount == 0,
                "a registrar inside a window-less hierarchy must not be registered yet")

        let window = makeWindowWithContentView()
        window.contentView?.addSubview(container)

        #expect(store.registeredContentWindowCount == 1,
                "attaching the container to a window must register the registrar, even though the registrar itself was never touched directly")

        store.unregisterNSWindow(window)
    }
}
