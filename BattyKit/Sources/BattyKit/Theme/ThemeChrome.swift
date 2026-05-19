// ThemeChrome.swift

import Observation
import SwiftUI

/// Single source of truth for the chrome palette derived from the active
/// `.ghostty` theme. SwiftUI chrome views (sidebar, tab bar, dividers,
/// pane border) read these colors via the environment so a theme switch
/// repaints the chrome live, in lockstep with the libghostty surface
/// repaint.
///
/// Every color is optional. `nil` means "fall back to the standard macOS
/// adaptive chrome" — that's the default state when no theme is selected
/// or the theme file doesn't expose the needed slot. Chrome views translate
/// `nil` into their pre-theming default (`.windowBackgroundColor`,
/// `.accentColor`, `Color.gray.opacity(...)`, etc.).
@Observable
@MainActor
public final class ThemeChrome {
    public private(set) var palette: ChromePalette

    public init(palette: ChromePalette = .default) {
        self.palette = palette
    }

    /// Recomputes the palette from a Ghostty theme. Pass `nil` to revert
    /// to the system default chrome.
    public func update(from theme: GhosttyThemeDefinition?) {
        palette = ChromePalette(theme: theme)
    }

    public var windowBackground: Color? { palette.windowBackground }
    public var chromeBackground: Color? { palette.chromeBackground }
    public var chromeForeground: Color? { palette.chromeForeground }
    public var chromeMutedForeground: Color? { palette.chromeMutedForeground }
    public var accent: Color? { palette.accent }
    public var divider: Color? { palette.divider }
    public var focusBorder: Color? { palette.accent }
    public var tabActiveFill: Color? { palette.tabActiveFill }
    public var tabInactiveFill: Color? { palette.tabInactiveFill }
    public var tabActiveStroke: Color? { palette.tabActiveStroke }
    public var tabInactiveStroke: Color? { palette.tabInactiveStroke }
    public var sidebarSelectionTint: Color? { palette.sidebarSelectionTint }
}

public struct ChromePalette: Sendable, Equatable {
    public let windowBackground: Color?
    public let chromeBackground: Color?
    public let chromeForeground: Color?
    public let chromeMutedForeground: Color?
    public let accent: Color?
    public let divider: Color?
    public let tabActiveFill: Color?
    public let tabInactiveFill: Color?
    public let tabActiveStroke: Color?
    public let tabInactiveStroke: Color?
    public let sidebarSelectionTint: Color?

    public static let `default` = ChromePalette(
        windowBackground: nil,
        chromeBackground: nil,
        chromeForeground: nil,
        chromeMutedForeground: nil,
        accent: nil,
        divider: nil,
        tabActiveFill: nil,
        tabInactiveFill: nil,
        tabActiveStroke: nil,
        tabInactiveStroke: nil,
        sidebarSelectionTint: nil
    )

    public init(theme: GhosttyThemeDefinition?) {
        guard let theme,
              let bg = RGBColor(hex: theme.background),
              let fg = RGBColor(hex: theme.foreground) else {
            self = .default
            return
        }

        let accentRGB = ChromePalette.pickAccent(theme: theme, foreground: fg, background: bg)
        let chromeBG = bg.shifted(toward: fg, by: 0.06)
        let mutedFG = fg.blended(with: bg, ratio: 0.4)
        let divider = fg.withAlpha(0.18)
        let tabActive = chromeBG.shifted(toward: fg, by: 0.08)
        let tabInactive = chromeBG.shifted(toward: fg, by: 0.02)
        let tabActiveStroke = ChromePalette.preferLegible(
            primary: accentRGB,
            alternate: fg.withAlpha(0.5),
            against: tabActive
        )
        let tabInactiveStroke = fg.withAlpha(0.18)

        self.windowBackground = bg.swiftUIColor
        self.chromeBackground = chromeBG.swiftUIColor
        self.chromeForeground = fg.swiftUIColor
        self.chromeMutedForeground = mutedFG.swiftUIColor
        self.accent = accentRGB.swiftUIColor
        self.divider = divider.swiftUIColor
        self.tabActiveFill = tabActive.swiftUIColor
        self.tabInactiveFill = tabInactive.swiftUIColor
        self.tabActiveStroke = tabActiveStroke.swiftUIColor
        self.tabInactiveStroke = tabInactiveStroke.swiftUIColor
        self.sidebarSelectionTint = fg.withAlpha(0.12).swiftUIColor
    }

    init(
        windowBackground: Color?,
        chromeBackground: Color?,
        chromeForeground: Color?,
        chromeMutedForeground: Color?,
        accent: Color?,
        divider: Color?,
        tabActiveFill: Color?,
        tabInactiveFill: Color?,
        tabActiveStroke: Color?,
        tabInactiveStroke: Color?,
        sidebarSelectionTint: Color?
    ) {
        self.windowBackground = windowBackground
        self.chromeBackground = chromeBackground
        self.chromeForeground = chromeForeground
        self.chromeMutedForeground = chromeMutedForeground
        self.accent = accent
        self.divider = divider
        self.tabActiveFill = tabActiveFill
        self.tabInactiveFill = tabInactiveFill
        self.tabActiveStroke = tabActiveStroke
        self.tabInactiveStroke = tabInactiveStroke
        self.sidebarSelectionTint = sidebarSelectionTint
    }

    static func preferLegible(primary: RGBColor, alternate: RGBColor, against: RGBColor) -> RGBColor {
        primary.contrast(against: against) >= alternate.contrast(against: against)
            ? primary
            : alternate
    }

    static func pickAccent(theme: GhosttyThemeDefinition, foreground: RGBColor, background: RGBColor) -> RGBColor {
        var candidates: [RGBColor] = []
        if let cursor = theme.cursorColor, let c = RGBColor(hex: cursor) {
            candidates.append(c)
        }
        if let p4 = theme.palette[4], let c = RGBColor(hex: p4) {
            candidates.append(c)
        }
        if let p6 = theme.palette[6], let c = RGBColor(hex: p6) {
            candidates.append(c)
        }
        if candidates.isEmpty {
            return foreground
        }
        let legible = candidates.first { $0.contrast(against: background) >= 1.5 }
        return legible ?? candidates[0]
    }
}

/// Minimal sRGB color value-type used for chrome-palette math. We don't
/// use SwiftUI `Color` directly because `Color` doesn't expose its
/// components in a usable form for blending / contrast checks.
struct RGBColor: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            s.removeFirst()
        } else if s.hasPrefix("0x") || s.hasPrefix("0X") {
            s.removeFirst(2)
        }
        guard s.count == 6 else { return nil }
        guard
            let r = UInt8(s.prefix(2), radix: 16),
            let g = UInt8(s.dropFirst(2).prefix(2), radix: 16),
            let b = UInt8(s.dropFirst(4).prefix(2), radix: 16)
        else { return nil }
        self.red = Double(r) / 255
        self.green = Double(g) / 255
        self.blue = Double(b) / 255
        self.alpha = 1
    }

    func blended(with other: RGBColor, ratio: Double) -> RGBColor {
        let t = max(0, min(1, ratio))
        return RGBColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha
        )
    }

    func shifted(toward other: RGBColor, by amount: Double) -> RGBColor {
        blended(with: other, ratio: amount)
    }

    func withAlpha(_ newAlpha: Double) -> RGBColor {
        RGBColor(red: red, green: green, blue: blue, alpha: newAlpha)
    }

    var relativeLuminance: Double {
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = channel(red)
        let g = channel(green)
        let b = channel(blue)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    func contrast(against other: RGBColor) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

private struct EnvironmentThemeChromeKey: EnvironmentKey {
    static let defaultValue: ThemeChrome? = nil
}

extension EnvironmentValues {
    public var themeChrome: ThemeChrome? {
        get { self[EnvironmentThemeChromeKey.self] }
        set { self[EnvironmentThemeChromeKey.self] = newValue }
    }
}
