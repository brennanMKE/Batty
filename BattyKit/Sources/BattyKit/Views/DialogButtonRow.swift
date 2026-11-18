// DialogButtonRow.swift

import SwiftUI

struct DialogButton {
    var title: LocalizedStringKey
    var identifier: String?
    var role: ButtonRole?
    var isEnabled: Bool
    var action: () -> Void

    init(
        _ title: LocalizedStringKey,
        identifier: String? = nil,
        role: ButtonRole? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.identifier = identifier
        self.role = role
        self.isEnabled = isEnabled
        self.action = action
    }

    static func cancel(identifier: String? = nil, action: @escaping () -> Void) -> DialogButton {
        DialogButton("Cancel", identifier: identifier, role: .cancel, action: action)
    }
}

nonisolated enum DialogButtonRowLayout {
    enum Slot: Equatable, Sendable {
        case alternative
        case cancel
        case confirm
    }

    enum Key: Equatable, Sendable {
        case none
        case cancelAction
        case defaultAction
    }

    struct Placement: Equatable, Sendable {
        let slot: Slot
        let key: Key
    }

    /// Leading to trailing: the alternative, then Cancel, then the confirm
    /// button, so the confirm button is always rightmost.
    static func placements(
        hasAlternative: Bool,
        hasCancel: Bool,
        hasConfirm: Bool,
        confirmIsDefault: Bool
    ) -> [Placement] {
        var placements: [Placement] = []
        if hasAlternative { placements.append(Placement(slot: .alternative, key: .none)) }
        if hasCancel { placements.append(Placement(slot: .cancel, key: .cancelAction)) }
        if hasConfirm {
            placements.append(Placement(slot: .confirm, key: confirmIsDefault ? .defaultAction : .none))
        }
        return placements
    }
}

struct DialogButtonRow<Leading: View>: View {
    enum Style {
        /// No padding: the row sits inside a sheet that pads its content.
        case inline
        /// The row is its own bar under a `Divider`.
        case bar
    }

    private let confirm: DialogButton?
    private let cancel: DialogButton?
    private let alternative: DialogButton?
    private let confirmIsDefault: Bool
    private let style: Style
    private let leading: Leading

    init(
        confirm: DialogButton?,
        cancel: DialogButton?,
        alternative: DialogButton? = nil,
        confirmIsDefault: Bool = true,
        style: Style = .inline,
        @ViewBuilder leading: () -> Leading
    ) {
        self.confirm = confirm
        self.cancel = cancel
        self.alternative = alternative
        self.confirmIsDefault = confirmIsDefault
        self.style = style
        self.leading = leading()
    }

    var body: some View {
        HStack(spacing: 12) {
            leading
            Spacer(minLength: 0)
            ForEach(Array(placements.enumerated()), id: \.offset) { _, placement in
                if let button = button(for: placement.slot) {
                    view(for: button, key: placement.key)
                }
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, style == .bar ? 20 : 0)
        .padding(.vertical, style == .bar ? 12 : 0)
    }

    private var placements: [DialogButtonRowLayout.Placement] {
        DialogButtonRowLayout.placements(
            hasAlternative: alternative != nil,
            hasCancel: cancel != nil,
            hasConfirm: confirm != nil,
            confirmIsDefault: confirmIsDefault
        )
    }

    private func button(for slot: DialogButtonRowLayout.Slot) -> DialogButton? {
        switch slot {
        case .alternative: alternative
        case .cancel: cancel
        case .confirm: confirm
        }
    }

    @ViewBuilder
    private func view(for button: DialogButton, key: DialogButtonRowLayout.Key) -> some View {
        let base = Button(button.title, role: button.role, action: button.action)
            .disabled(!button.isEnabled)
            .dialogButtonIdentifier(button.identifier)
        switch key {
        case .none: base
        case .cancelAction: base.keyboardShortcut(.cancelAction)
        case .defaultAction: base.keyboardShortcut(.defaultAction)
        }
    }
}

extension DialogButtonRow where Leading == EmptyView {
    init(
        confirm: DialogButton?,
        cancel: DialogButton?,
        alternative: DialogButton? = nil,
        confirmIsDefault: Bool = true,
        style: Style = .inline
    ) {
        self.init(
            confirm: confirm,
            cancel: cancel,
            alternative: alternative,
            confirmIsDefault: confirmIsDefault,
            style: style,
            leading: { EmptyView() }
        )
    }
}

private extension View {
    @ViewBuilder
    func dialogButtonIdentifier(_ identifier: String?) -> some View {
        if let identifier { accessibilityIdentifier(identifier) } else { self }
    }
}
