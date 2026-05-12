// TerminalHostInstaller.swift

import AppKit
import SwiftUI

/// Background NSView that, on first window attachment, installs the
/// long-lived ``TerminalHostView`` into the window's `contentView`. This
/// is the one place where SwiftUI is allowed to drive AppKit-side
/// initialization of the host; once installed, the host is never moved,
/// removed, or re-parented. SwiftUI freely tears down and re-creates
/// this representable — `makeNSView` is cheap, and `viewDidMoveToWindow`
/// on the inner installer view is idempotent (subsequent calls find the
/// host already attached and return immediately).
struct TerminalHostInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> InstallerView {
        InstallerView(frame: .zero)
    }

    func updateNSView(_ nsView: InstallerView, context: Context) {
        // Window may be assigned after makeNSView returns. Re-checking
        // here is harmless thanks to TerminalHostStore.attachHost's
        // idempotency.
        if let window = nsView.window {
            TerminalHostStore.shared.attachHost(to: window)
        }
    }

    final class InstallerView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                TerminalHostStore.shared.attachHost(to: window)
            }
        }
    }
}
