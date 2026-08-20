// SessionColor.swift

import SwiftUI

/// Fixed 10-color palette used to give every Session a stable, automatically
/// assigned identity color, shown by tinting its Sidebar row's
/// `rectangle.split.3x1` symbol. `WindowRuntime`'s least-used round-robin
/// assigner walks cases in this declaration order; `SessionRuntime` stores
/// only the raw index (`colorIndex: Int`), never this enum, so the palette
/// can change shape later without touching stored state. See
/// `issues/0335.md` for the Radix-scale-9 hue rationale and the
/// colorblind-safe adjacency spacing.
public enum SessionColor: Int, CaseIterable, Sendable {
    case blue
    case orange
    case green
    case pink
    case teal
    case red
    case violet
    case amber
    case cyan
    case brown

    private var hex: String {
        switch self {
        case .blue: "#3E63DD"
        case .orange: "#F76B15"
        case .green: "#30A46C"
        case .pink: "#D6409F"
        case .teal: "#12A594"
        case .red: "#E5484D"
        case .violet: "#8E4EC6"
        case .amber: "#FFB224"
        case .cyan: "#00A2C7"
        case .brown: "#AD7F58"
        }
    }

    /// Tint for the Session row's symbol — full palette strength, not a
    /// reduced-opacity or hierarchical variant (#0335 open question).
    public var color: Color {
        (RGBColor(hex: hex) ?? RGBColor(red: 0.5, green: 0.5, blue: 0.5)).swiftUIColor
    }

    /// Accessible / user-facing name, for VoiceOver labels on a future
    /// color picker (#0336) and any other UI surface that names the color.
    public var displayName: String {
        switch self {
        case .blue: String(localized: "Blue", comment: "Session color name")
        case .orange: String(localized: "Orange", comment: "Session color name")
        case .green: String(localized: "Green", comment: "Session color name")
        case .pink: String(localized: "Pink", comment: "Session color name")
        case .teal: String(localized: "Teal", comment: "Session color name")
        case .red: String(localized: "Red", comment: "Session color name")
        case .violet: String(localized: "Violet", comment: "Session color name")
        case .amber: String(localized: "Amber", comment: "Session color name")
        case .cyan: String(localized: "Cyan", comment: "Session color name")
        case .brown: String(localized: "Brown", comment: "Session color name")
        }
    }
}
