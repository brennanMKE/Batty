// BattyTabChip.swift

import SwiftUI

/// Tab chip used inside `SlidingTabBar`. Mirrors `DefaultTabChip`'s
/// look (unseen dot, active highlight, hover-or-active close button)
/// but **does not** use `.fixedSize(horizontal: true)` on the title
/// text, so the chip respects an outer `.frame(maxWidth:)` constraint.
/// Middle-truncation kicks in inside the chip when the parent's
/// allocated width is narrower than the natural text width.
public struct BattyTabChip: View {

    private let title: String
    private let isActive: Bool
    private let isPaneFocused: Bool
    private let hasUnseen: Bool
    private let onClose: (() -> Void)?
    private let startupWaiting: StartupCommandWaiting?
    private let onRunStartupCommand: (() -> Void)?
    private let onDismissStartupCommand: (() -> Void)?

    @Environment(\.themeChrome) private var themeChrome
    @State private var isHovered: Bool = false

    private var showsUnseenDot: Bool { hasUnseen && !isActive }

    private var showsActiveAccent: Bool { isActive && isPaneFocused }

    public init(
        title: String,
        isActive: Bool,
        isPaneFocused: Bool = true,
        hasUnseen: Bool = false,
        onClose: (() -> Void)? = nil,
        startupWaiting: StartupCommandWaiting? = nil,
        onRunStartupCommand: (() -> Void)? = nil,
        onDismissStartupCommand: (() -> Void)? = nil
    ) {
        self.title = title
        self.isActive = isActive
        self.isPaneFocused = isPaneFocused
        self.hasUnseen = hasUnseen
        self.onClose = onClose
        self.startupWaiting = startupWaiting
        self.onRunStartupCommand = onRunStartupCommand
        self.onDismissStartupCommand = onDismissStartupCommand
    }

    static let startupWaitingHelp = "Startup command not run \u{2014} the shell didn\u{2019}t report it was ready"

    /// A menu rather than a popover or sheet: it shows the pending command
    /// without opening a window or moving first responder off the terminal.
    @ViewBuilder
    private func startupWaitingIndicator(_ waiting: StartupCommandWaiting) -> some View {
        Menu {
            Text(waiting.command)
            Divider()
            Button("Run Now") { onRunStartupCommand?() }
            Button("Dismiss") { onDismissStartupCommand?() }
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.orange)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Self.startupWaitingHelp)
        .accessibilityLabel(Self.startupWaitingHelp)
        .accessibilityIdentifier("tab-startup-waiting")
    }

    private var accentColor: Color { themeChrome?.accent ?? Color.accentColor }
    private var primaryColor: Color { themeChrome?.chromeForeground ?? Color.primary }
    private var secondaryColor: Color { themeChrome?.chromeMutedForeground ?? Color.secondary }

    private var chipFill: Color {
        if showsActiveAccent {
            return accentColor.opacity(0.18)
        }
        if isActive {
            return themeChrome?.tabActiveFill ?? Color.gray.opacity(0.22)
        }
        return themeChrome?.tabInactiveFill ?? Color.gray.opacity(0.12)
    }

    private var chipStroke: Color {
        if showsActiveAccent {
            return accentColor
        }
        if isActive {
            return themeChrome?.tabActiveStroke ?? Color.gray.opacity(0.45)
        }
        return themeChrome?.tabInactiveStroke ?? Color.gray.opacity(0.25)
    }

    public var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if showsUnseenDot {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 6, height: 6)
                } else {
                    Color.clear.frame(width: 6, height: 6)
                }
            }

            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(primaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let startupWaiting {
                startupWaitingIndicator(startupWaiting)
            }

            if let onClose {
                ZStack {
                    if isHovered || isActive {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(secondaryColor)
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 14, height: 14)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(chipFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(chipStroke, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
