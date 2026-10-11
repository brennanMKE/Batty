// ThemeCard.swift

import SwiftUI

struct ThemeCard: View {
    let theme: GhosttyThemeDefinition
    /// This Theme is the one currently in effect (global appearance slot,
    /// or the Session's effective Theme for `SessionThemeSelectorView`) —
    /// drawn with the same outline `PaneView` uses for focus (`#0363`).
    let isActive: Bool
    /// This Theme is under the keyboard cursor. Distinct from `isActive`:
    /// once the user arrows away from the active Theme the two can sit on
    /// different cards, so they must never share a visual (`#0363`).
    let isCursor: Bool
    let isPinned: Bool
    let onTogglePin: () -> Void

    @Environment(\.themeChrome) private var themeChrome

    private var accentColor: Color {
        themeChrome?.accent ?? Color.accentColor
    }

    private var bgColor: Color {
        RGBColor(hex: theme.background)?.swiftUIColor ?? Color(nsColor: .windowBackgroundColor)
    }

    private var fgColor: Color {
        RGBColor(hex: theme.foreground)?.swiftUIColor ?? Color(nsColor: .labelColor)
    }

    private var chromeBGColor: Color {
        guard let bg = RGBColor(hex: theme.background),
              let fg = RGBColor(hex: theme.foreground)
        else { return Color(nsColor: .windowBackgroundColor) }
        return bg.shifted(toward: fg, by: 0.06).swiftUIColor
    }

    // ANSI indices 1–6: red, green, yellow, blue, magenta, cyan
    private var swatchColors: [Color] {
        (1...6).map { index in
            if let hex = theme.palette[index], let color = RGBColor(hex: hex) {
                return color.swiftUIColor
            }
            return Color.clear
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                bgColor
                HStack(spacing: 4) {
                    ForEach(Array(swatchColors.enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(color)
                            .frame(width: 10, height: 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 4) {
                Text(theme.name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(fgColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    onTogglePin()
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(fgColor)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(chromeBGColor)
        }
        .frame(width: 130, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            if isCursor {
                // Cursor badge, deliberately not a checkmark: a checkmark
                // reads as "selected/active", which `isActive`'s outline
                // already owns. `cursorarrow` reads as "the keyboard
                // cursor is here" instead (#0363).
                Image(systemName: "cursorarrow")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.primary)
                    .padding(4)
                    .background(.regularMaterial, in: Circle())
                    .padding(4)
            }
        }
        .activeOutline(isActive, cornerRadius: 8, color: accentColor)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theme-card.\(theme.name)")
    }
}
