// KeyboardShortcutRecorder.swift

import SwiftUI

/// A focusable, click-to-record keyboard shortcut field for the Settings pane.
///
/// Idle: shows the formatted current binding (`⌘⇧→`) inside a bordered button.
/// Recording: focused state shows `"Press a shortcut…"` with a tinted ring;
/// the next non-modifier `keyDown` is converted to a `ShortcutBinding` and
/// written back through `binding`. Esc cancels recording (does not clear the
/// binding).
struct KeyboardShortcutRecorder: NSViewRepresentable {
    @Binding var binding: ShortcutBinding

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.binding = binding
        view.onCommit = { newBinding in
            Task { @MainActor in
                self.binding = newBinding
            }
        }
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.binding = binding
        nsView.needsDisplay = true
    }

    /// Fixed control height keeps `Form` rows aligned.
    static var preferredHeight: CGFloat { 24 }
}
