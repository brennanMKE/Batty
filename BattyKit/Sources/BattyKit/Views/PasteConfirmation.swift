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
        guard let store, let tab = focusedTerminalTab(in: store) else {
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
        guard let tab = store.flatMap(focusedTerminalTab) else { return }
        tab.terminal.send(paste.text)
    }

    private static func focusedTerminalTab(in store: AppStateStore) -> TabRuntime? {
        // Resolve against the key content window, not the windows[0] shim, so
        // paste targets the terminal the user is actually looking at (#0244).
        // No window (#0316) resolves to nil like any other "nothing focused"
        // case, rather than trapping.
        store.keyWindowOrFirstRegistered()?.selectedSession?.focusedPane.activeTab
    }

    private static var isEditingTextField: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView { return true }
        if let textField = responder as? NSTextField, textField.isEditable { return true }
        return false
    }

    private static func forwardStandardPaste() {
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
    }
}
