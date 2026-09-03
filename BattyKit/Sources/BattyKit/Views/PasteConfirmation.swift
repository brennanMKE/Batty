// PasteConfirmation.swift

import AppKit
import SwiftUI

extension Notification.Name {
    public static let battyRequestPaste = Notification.Name("co.sstools.Batty.requestPaste")
}

public struct PendingPaste: Identifiable {
    public let id = UUID()
    public let text: String
    public let lineCount: Int

    public init(text: String) {
        self.text = text
        self.lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

public struct PasteConfirmationSheet: View {
    let paste: PendingPaste
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    public init(
        paste: PendingPaste,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.paste = paste
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste \(paste.lineCount) lines?")
                .font(.headline)
            ScrollView {
                Text(previewText)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 240)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.escape)
                Button("Paste") { onConfirm(paste.text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var previewText: String {
        let lines = paste.text.split(separator: "\n", omittingEmptySubsequences: false)
        let limit = 10
        if lines.count <= limit {
            return paste.text
        }
        return lines.prefix(limit).joined(separator: "\n") + "\n…(\(lines.count - limit) more lines)"
    }
}

@MainActor
public enum PasteDispatcher {
    public static func handlePasteRequest(store: AppStateStore?) {
        // Resolving through `store.focusedTerminalTab` directly (#0332 N3)
        // rather than a local passthrough — the passthrough existed only
        // to be re-inlined and re-drift from `ExitDispatcher`'s copy the
        // way it already had once; calling the shared property at both
        // sites makes that drift unwritable rather than merely undetected.
        guard let store, let tab = store.focusedTerminalTab else {
            forwardStandardPaste()
            return
        }
        if isEditingTextField {
            forwardStandardPaste()
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return
        }
        let strictness = SettingsPreference.resolvedPasteStrictness()
        if strictness.shouldConfirm(text) {
            let pending = PendingPaste(text: text)
            NotificationCenter.default.post(
                name: .battyRequestPaste,
                object: nil,
                userInfo: ["paste": pending]
            )
        } else {
            tab.terminal.send(text)
        }
    }

    public static func confirm(_ paste: PendingPaste, in store: AppStateStore?) {
        guard let tab = store?.focusedTerminalTab else { return }
        tab.terminal.send(paste.text)
    }

    private static var isEditingTextField: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView { return true }
        if let textField = responder as? NSTextField, textField.isEditable { return true }
        return false
    }

    /// Injectable seam (#0332 N2), not `private`: `handlePasteRequest`'s
    /// early-return branch (no focused Terminal pane, or the responder
    /// chain is already editing a text field) must fall back to the
    /// standard AppKit paste action rather than silently dropping the
    /// paste. A test asserting only "`.battyRequestPaste` was not posted"
    /// cannot distinguish that fallback firing from the whole method
    /// merely no-oping — swapping this in for a recording closure lets a
    /// test assert the fallback actually ran.
    static var forwardStandardPaste: () -> Void = {
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
    }
}
