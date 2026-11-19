// PickerHintBar.swift

import SwiftUI

nonisolated enum PickerEscapeHint: Equatable, Sendable {
    case dismiss
    case clear

    var title: String {
        switch self {
        case .dismiss:
            String(localized: "Esc to dismiss", comment: "Keyboard picker footer: Escape closes without choosing")
        case .clear:
            String(localized: "Esc to clear", comment: "Keyboard picker footer: Escape clears the filter")
        }
    }
}

/// Footer bar shared by the keyboard pickers: the selection's context hint leading,
/// the key list trailing, and the Escape hint always last.
struct PickerHintBar<Leading: View, Keys: View>: View {
    private let escape: PickerEscapeHint
    private let leading: Leading
    private let keys: Keys

    init(
        escape: PickerEscapeHint = .dismiss,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder keys: () -> Keys
    ) {
        self.escape = escape
        self.leading = leading()
        self.keys = keys()
    }

    var body: some View {
        HStack(spacing: 18) {
            leading
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            // Fixed so the context hint truncates before any key does.
            HStack(spacing: 18) {
                keys
                Text(escape.title)
                    .accessibilityIdentifier("picker-hint.escape")
            }
            .fixedSize()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

extension PickerHintBar where Leading == EmptyView {
    init(escape: PickerEscapeHint = .dismiss, @ViewBuilder keys: () -> Keys) {
        self.init(escape: escape, leading: { EmptyView() }, keys: keys)
    }
}

extension PickerHintBar where Keys == EmptyView {
    init(escape: PickerEscapeHint = .dismiss, @ViewBuilder leading: () -> Leading) {
        self.init(escape: escape, leading: leading, keys: { EmptyView() })
    }
}

extension PickerHintBar where Leading == EmptyView, Keys == EmptyView {
    init(escape: PickerEscapeHint = .dismiss) {
        self.init(escape: escape, leading: { EmptyView() }, keys: { EmptyView() })
    }
}
