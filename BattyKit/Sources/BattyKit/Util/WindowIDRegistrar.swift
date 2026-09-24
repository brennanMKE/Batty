// WindowIDRegistrar.swift

import AppKit
import SwiftUI

/// Registers the NSWindow ↔ WindowID association in `AppStateStore` once the
/// hosting NSWindow is known. Used by each content window's SwiftUI tree so
/// `BattyShortcuts` can identify the key window's `WindowRuntime` without
/// relying on window-title or identifier heuristics.
///
/// Registration happens synchronously from `RegistrarNSView.viewDidMoveToWindow`
/// (#0437) rather than being deferred via `DispatchQueue.main.async`: the async
/// hop left a gap — at least one main-queue turn wide — during which a
/// newly-opened window could already be `NSApp.keyWindow` while still absent
/// from `nsWindowMap`, dropping Cmd-B and misrouting every other key-window
/// shortcut, menu command, and no-target CLI verb to the previous window.
///
/// `store` is a required parameter, not a `.shared` default (#0359's "no
/// silent default" rule) — `RootWindowView` passes the same `store` it hands
/// to `WindowDelegate.unregisterNSWindow`, so a test (or a future multi-store
/// caller) can inject its own store instead of always touching the
/// process-wide singleton.
public struct WindowIDRegistrar: NSViewRepresentable {
    public let windowID: WindowID
    public let store: AppStateStore

    public init(windowID: WindowID, store: AppStateStore) {
        self.windowID = windowID
        self.store = store
    }

    public func makeNSView(context: Context) -> NSView {
        RegistrarNSView(windowID: windowID, store: store)
    }

    /// Also handles `windowID` changing on an already-mounted view (not
    /// currently reachable in production — each content window's `windowID`
    /// is fixed for its `RootWindowView`'s lifetime — but SwiftUI could in
    /// principle reuse this representable's identity across a `windowID`
    /// change, and re-registering here costs nothing: it only writes the
    /// `@ObservationIgnored` `nsWindowMap`, not observed state).
    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let registrar = nsView as? RegistrarNSView, registrar.windowID != windowID else { return }
        registrar.windowID = windowID
        if let window = registrar.window {
            store.registerNSWindow(window, for: windowID)
        }
    }
}

/// The `NSView` subclass backing `WindowIDRegistrar`. Registers itself with
/// `AppStateStore` from `viewDidMoveToWindow`.
///
/// **Why this write is safe here, even though `viewDidMoveToWindow` can fire
/// while SwiftUI's own update machinery is attaching this view to its
/// window** (i.e. potentially mid-update, not necessarily outside it): the
/// write touches only `AppStateStore.nsWindowMap`, which is
/// `@ObservationIgnored` and so notifies no observer and can't feed back
/// into the update it might be running inside, and it calls no
/// constraint-dirtying or responder-changing AppKit API (no
/// `makeFirstResponder`, no `addSubview`, no window operation) — the actual
/// things `docs/swiftui-observation-rules.md`'s AppKit-interop rule forbids
/// from a SwiftUI-driven callback. What makes registration here safe is
/// *what* it writes, not a guarantee about *when* `viewDidMoveToWindow` runs
/// relative to SwiftUI's update pass.
///
/// `viewDidMoveToWindow` fires again whenever `window` changes, including the
/// nil→non-nil transition if this view is first added to an off-window
/// hierarchy, so registration isn't lost to that ordering either.
/// `registerNSWindow` is idempotent, so re-firing is harmless.
///
/// Not `private`: `WindowIDRegistrarTests` (`@testable import BattyKit`)
/// constructs this directly and inserts it into a real `NSWindow`, so the
/// test exercises the actual registration path instead of re-typing it.
final class RegistrarNSView: NSView {
    var windowID: WindowID
    private let store: AppStateStore

    init(windowID: WindowID, store: AppStateStore) {
        self.windowID = windowID
        self.store = store
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        store.registerNSWindow(window, for: windowID)
    }
}
