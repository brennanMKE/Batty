// ThemeCard.swift

import SwiftUI

struct ThemeCard: View {
    let theme: GhosttyThemeDefinition
    let isSelected: Bool
    let isPinned: Bool
    let onTogglePin: () -> Void

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
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
    }
}
