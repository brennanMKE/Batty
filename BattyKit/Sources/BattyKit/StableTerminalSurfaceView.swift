// StableTerminalSurfaceView.swift

import AppKit
import GhosttyTerminal
import OSLog
import SwiftUI

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "StableTerminalSurfaceView")

/// Wrapper around libghostty's `AppTerminalView` that keeps the underlying
/// NSView (and its PTY/surface) alive across SwiftUI view-tree rebuilds.
///
/// SwiftUI freely tears down and re-mounts `NSViewRepresentable`s when
/// parent state changes. Letting libghostty's `TerminalSurfaceView` sit
/// directly in a `ForEach` therefore destroys the PTY on every tab switch
/// or pane focus change (see issue #0072).
///
/// Instead, the long-lived `AppTerminalView` is owned by ``TabRuntime``.
/// `makeNSView` returns a cheap container and eagerly attaches the tab's
/// `AppTerminalView` (creating one on first use); `updateNSView` defensively
/// re-checks the attachment on every SwiftUI update so the NSView is always
/// hosted by *some* container in the window's view hierarchy. SwiftUI can
/// tear down the container whenever it likes — the terminal view stays
/// retained by the tab and is re-attached on the next mount.
/// `AppTerminalView.viewDidMoveToWindow` is already coded to skip surface
/// rebuild when one already exists, so re-parenting is cheap.
public struct StableTerminalSurfaceView: NSViewRepresentable {
    private let tab: TabRuntime

    public init(tab: TabRuntime) {
        self.tab = tab
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
        attachIfNeeded(to: container)
        return container
    }

    public func updateNSView(_ container: NSView, context: Context) {
        attachIfNeeded(to: container)
        guard let terminalView = tab.terminalNSView else { return }
        if terminalView.delegate !== tab.terminal {
            terminalView.delegate = tab.terminal
        }
        if terminalView.controller !== tab.terminal.controller {
            terminalView.controller = tab.terminal.controller
        }
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // Intentionally empty. The terminal NSView is retained by the
        // TabRuntime; removing it from the container's subviews would
        // detach from its window and is unnecessary — the container is
        // about to be released, which removes its subviews implicitly.
        // libghostty's `viewDidMoveToWindow(nil)` only stops the display
        // link and clears focus; it does not free the surface.
    }

    /// Guarantees two invariants after it returns:
    ///   1. `tab.terminalNSView` is non-nil.
    ///   2. That NSView is a subview of `container`, pinned to all four edges.
    ///
    /// Called from both `makeNSView` (so the first mount never returns an
    /// empty container even if SwiftUI skips the initial `updateNSView`) and
    /// from `updateNSView` (so any subsequent rebuild re-parents an orphaned
    /// or cross-container NSView back into the current container).
    private func attachIfNeeded(to container: NSView) {
        let terminalView = ensureTerminalView()

        if terminalView.superview === container {
            return
        }

        if terminalView.superview == nil {
            logger.debug("re-attaching orphaned AppTerminalView to container")
        }

        terminalView.removeFromSuperview()
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: container.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func ensureTerminalView() -> AppTerminalView {
        if let existing = tab.terminalNSView {
            return existing
        }
        let terminalView = AppTerminalView(frame: .zero)
        terminalView.delegate = tab.terminal
        terminalView.controller = tab.terminal.controller
        terminalView.configuration = tab.terminal.configuration
        tab.terminalNSView = terminalView
        return terminalView
    }
}
