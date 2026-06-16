// WindowIDRegistrar.swift

import AppKit
import SwiftUI

/// Registers the NSWindow ↔ WindowID association in `AppStateStore` once the
/// hosting NSWindow is known. Used by each content window's SwiftUI tree so
/// `BattyShortcuts` can identify the key window's `WindowRuntime` without
/// relying on window-title or identifier heuristics.
///
/// Follows the same `NSViewRepresentable` pattern as `WindowChromeApplier`:
/// `updateNSView` defers the write off the SwiftUI update pass via
/// `DispatchQueue.main.async` — the registration call is an AppKit side-effect
/// that must not run synchronously inside the layout pass (observation rules,
/// `docs/swiftui-observation-rules.md` AppKit interop section).
public struct WindowIDRegistrar: NSViewRepresentable {
    public let windowID: WindowID

    public init(windowID: WindowID) {
        self.windowID = windowID
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        let id = windowID
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            AppStateStore.shared.registerNSWindow(window, for: id)
        }
    }
}
