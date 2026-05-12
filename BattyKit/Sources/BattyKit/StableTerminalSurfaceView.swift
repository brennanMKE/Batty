// StableTerminalSurfaceView.swift

import AppKit
import GhosttyTerminal
import SwiftUI

/// Wrapper around libghostty's `AppTerminalView` that keeps the underlying
/// NSView (and its PTY/surface) alive across SwiftUI view-tree rebuilds.
///
/// SwiftUI freely tears down and re-mounts `NSViewRepresentable`s when
/// parent state changes. Letting libghostty's `TerminalSurfaceView` sit
/// directly in a `ForEach` therefore destroys the PTY on every tab switch
/// or pane focus change (see issue #0072).
///
/// Instead, the long-lived `AppTerminalView` is owned by ``TabRuntime``.
/// `makeNSView` returns a cheap container; `updateNSView` re-parents the
/// tab's existing `AppTerminalView` into that container, creating one on
/// first use. SwiftUI can tear down the container whenever it likes — the
/// terminal view stays retained by the tab and is re-attached on the next
/// mount. `AppTerminalView.viewDidMoveToWindow` is already coded to skip
/// surface rebuild when one already exists, so re-parenting is cheap.
public struct StableTerminalSurfaceView: NSViewRepresentable {
    private let tab: TabRuntime

    public init(tab: TabRuntime) {
        self.tab = tab
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
        attachTerminalView(to: container)
        return container
    }

    public func updateNSView(_ container: NSView, context: Context) {
        attachTerminalView(to: container)
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

    private func attachTerminalView(to container: NSView) {
        let terminalView: AppTerminalView
        if let existing = tab.terminalNSView {
            terminalView = existing
        } else {
            terminalView = AppTerminalView(frame: .zero)
            terminalView.delegate = tab.terminal
            terminalView.controller = tab.terminal.controller
            terminalView.configuration = tab.terminal.configuration
            tab.terminalNSView = terminalView
        }

        guard terminalView.superview !== container else { return }
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
}
