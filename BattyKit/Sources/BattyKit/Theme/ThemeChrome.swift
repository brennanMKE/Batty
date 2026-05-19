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

    // Convenience accessors. Chrome views read these directly and fall
    // back to their non-themed default when nil.

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

    /// Derives a chrome palette from a Ghostty theme's color slots.
    /// `theme == nil` produces `.default` (everything `nil` → system).
    public init(theme: GhosttyThemeDefinition?) {
        guard let theme,
              let bg = RGBColor(hex: theme.background),
              let fg = RGBColor(hex: theme.foreground) else {
            self = .default
            return
        }

        // Accent picks cursor first (closest analogue to "highlight"),
        // then ANSI 4 (blue, the conventional accent in most themes),
        // then ANSI 6 (cyan) as a last resort. We avoid red/green/yellow —
        // they map to errors/success/warning in terminal-land and would
        // read as semantic noise in the chrome.
        let accentRGB = ChromePalette.pickAccent(theme: theme, foreground: fg, background: bg)

        // The tab bar / sidebar background sits *near* the window
        // background but should be subtly different so the chrome reads
        // as separated from the terminal canvas. Tint by ~6% of the
        // foreground/background contrast, in whichever direction reads
        // best (lighten on dark themes, darken on light themes).
        let chromeBG = bg.shifted(toward: fg, by: 0.06)

        // A muted chrome foreground for secondary text (timestamps,
        // captions). Blend 60% foreground + 40% background. Falls
        // somewhere between primary and the chrome background so it
        // stays legible without competing with primary labels.
        let mutedFG = fg.blended(with: bg, ratio: 0.4)

        // Divider sits over the chrome — a stroke of foreground at low
        // alpha is the cheapest legible choice across both dark and
        // light themes.
        let divider = fg.withAlpha(0.18)

        // Tab chip backgrounds. Active = chromeBG shifted one more step
        // toward foreground so the active chip pops; inactive = same
        // chromeBG so chips visually nest in the bar.
        let tabActive = chromeBG.shifted(toward: fg, by: 0.08)
        let tabInactive = chromeBG.shifted(toward: fg, by: 0.02)
        let tabActiveStroke = ChromePalette.preferLegible(
            primary: accentRGB,
            alternate: fg.withAlpha(0.5),
            against: tabActive
        )
        let tabInactiveStroke = fg.withAlpha(0.18)

        // Sidebar selection tint uses the accent at low alpha so a
        // selected row pops without overwhelming the chrome.
        let sidebarSelection = accentRGB.withAlpha(0.28)

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
        self.sidebarSelectionTint = sidebarSelection.swiftUIColor
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

    /// Returns whichever of `primary` or `alternate` has the greater
    /// luminance contrast against `against`. Used so the active-tab
    /// stroke stays visible when the chosen accent and the active-tab
    /// fill happen to land at similar luminance (e.g. a beige accent
    /// over a beige tab on a light theme).
    static func preferLegible(primary: RGBColor, alternate: RGBColor, against: RGBColor) -> RGBColor {
        primary.contrast(against: against) >= alternate.contrast(against: against)
            ? primary
            : alternate
    }

    /// Picks the most useful accent slot from a theme. Cursor first
    /// because that's the theme author's explicit "highlight" choice;
    /// ANSI 4 (blue) next because most themes carry a saturated, mid-tone
    /// blue that reads as an accent against either light or dark
    /// backgrounds; ANSI 6 (cyan) third as a final fallback. We avoid
    /// red (1) / green (2) / yellow (3) — those carry semantic meaning
    /// in terminal output and would conflict with the chrome.
    /// If no candidate has enough contrast against the background, we
    /// still return the cursor color (or first available) so the user
    /// sees *some* themed accent rather than a fallback to system blue.
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

    /// Mix two colors by `ratio` (0 = self, 1 = other), ignoring alpha.
    func blended(with other: RGBColor, ratio: Double) -> RGBColor {
        let t = max(0, min(1, ratio))
        return RGBColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha
        )
    }

    /// Returns a copy moved a small distance toward `other`. Used to
    /// derive chrome backgrounds that sit *near* the window background
    /// but are subtly differentiated.
    func shifted(toward other: RGBColor, by amount: Double) -> RGBColor {
        blended(with: other, ratio: amount)
    }

    func withAlpha(_ newAlpha: Double) -> RGBColor {
        RGBColor(red: red, green: green, blue: blue, alpha: newAlpha)
    }

    /// Relative luminance per WCAG 2.x. Used for contrast checks when
    /// deciding between candidate chrome colors.
    var relativeLuminance: Double {
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = channel(red)
        let g = channel(green)
        let b = channel(blue)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// WCAG contrast ratio between `self` and `other`. 1.0 = identical,
    /// 21.0 = black on white. Chrome wants ≥ 3.0 for large text, ≥ 4.5
    /// for body text; for accents we accept ≥ 1.5 as "visible at all".
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
