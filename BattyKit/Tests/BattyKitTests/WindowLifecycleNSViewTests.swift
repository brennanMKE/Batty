// WindowLifecycleNSViewTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

/// `WindowLifecycleNSView` installs the window delegate and
/// `closeWindowCallback` synchronously from `viewDidMoveToWindow`, with no
/// main-queue hop. Each test asserts right after `addSubview`, before any
/// run-loop turn, so a deferred implementation cannot pass.
@MainActor
struct WindowLifecycleNSViewTests {

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        return window
    }

    @Test func lifecycleViewInstallsWindowDelegateWhenMovedToWindow() {
        let store = AppStateStore()
        let window = makeWindow()
        let view = WindowLifecycleNSView(windowID: store.windows[0].id, store: store)
        #expect(window.delegate == nil)

        window.contentView?.addSubview(view)

        #expect(window.delegate === view.windowDelegate)
        #expect(window.delegate is WindowDelegate)
    }

    @Test func lifecycleViewWiresCloseWindowCallbackWhenMovedToWindow() {
        let store = AppStateStore()
        let runtime = store.windows[0]
        runtime.closeWindowCallback = nil
        let window = makeWindow()
        let view = WindowLifecycleNSView(windowID: runtime.id, store: store)

        window.contentView?.addSubview(view)

        #expect(runtime.closeWindowCallback != nil)
    }

    @Test func lifecycleViewKeepsExistingCloseWindowCallback() {
        let store = AppStateStore()
        let runtime = store.windows[0]
        var sentinelRan = false
        runtime.closeWindowCallback = { sentinelRan = true }
        let window = makeWindow()
        let view = WindowLifecycleNSView(windowID: runtime.id, store: store)

        window.contentView?.addSubview(view)
        runtime.closeWindowCallback?()

        #expect(sentinelRan)
    }

    @Test func reinsertingLifecycleViewKeepsTheSameDelegate() {
        let store = AppStateStore()
        let window = makeWindow()
        let view = WindowLifecycleNSView(windowID: store.windows[0].id, store: store)
        window.contentView?.addSubview(view)
        let first = window.delegate

        view.removeFromSuperview()
        window.contentView?.addSubview(view)

        #expect(window.delegate === first)
        #expect(window.delegate === view.windowDelegate)
    }

    /// A never-ordered-in window is not visible, so a view that read
    /// occlusion on attach would write `false`. Occlusion arrives only as a
    /// `WindowDelegate` event.
    @Test func lifecycleViewDoesNotReadOcclusionOnAttach() {
        let store = AppStateStore()
        let runtime = store.windows[0]
        let window = makeWindow()
        #expect(!window.occlusionState.contains(.visible), "fixture: the window must not be visible")
        #expect(TerminalHostStore.shared.isWindowOcclusionVisible(forWindowID: runtime.id))
        #expect(runtime.isWindowVisible)
        let view = WindowLifecycleNSView(windowID: runtime.id, store: store)

        window.contentView?.addSubview(view)

        #expect(TerminalHostStore.shared.isWindowOcclusionVisible(forWindowID: runtime.id))
        #expect(runtime.isWindowVisible)
    }
}
