// ThemeChromeTests.swift

import Foundation
import GhosttyTheme
import Testing
@testable import BattyKit

@MainActor
struct ThemeChromeTests {

    @Test func defaultPaletteIsAllNil() {
        let palette = ChromePalette.default
        #expect(palette.windowBackground == nil)
        #expect(palette.chromeBackground == nil)
        #expect(palette.chromeForeground == nil)
        #expect(palette.accent == nil)
        #expect(palette.divider == nil)
        #expect(palette.sidebarSelectionTint == nil)
    }

    @Test func nilThemeProducesDefaultPalette() {
        let palette = ChromePalette(theme: nil)
        #expect(palette == .default)
    }

    @Test func darkThemeProducesNonNilPalette() {
        let theme = GhosttyThemeDefinition(
            name: "test-dark",
            background: "#1a1b26",
            foreground: "#c0caf5",
            cursorColor: "#7aa2f7",
            palette: [4: "7aa2f7", 6: "7dcfff"]
        )
        let palette = ChromePalette(theme: theme)
        #expect(palette.windowBackground != nil)
        #expect(palette.chromeBackground != nil)
        #expect(palette.chromeForeground != nil)
        #expect(palette.accent != nil)
        #expect(palette.divider != nil)
        #expect(palette.tabActiveFill != nil)
    }

    @Test func sidebarSelectionTintIsThemedAndSubtle() {
        // Per #0135 round 5: the slot derives from foreground at 12% alpha
        // — a subtle adaptive overlay that reads as a slight lightening
        // on dark themes and a slight darkening on light themes, without
        // picking up the theme accent (the round-1 derivation of accent
        // at 28% alpha read as a glaring block in vivid themes).
        let theme = GhosttyThemeDefinition(
            name: "olive",
            background: "#1a1b26",
            foreground: "#c0caf5",
            cursorColor: "#a3b431",
            palette: [4: "7aa2f7", 6: "7dcfff"]
        )
        let palette = ChromePalette(theme: theme)
        #expect(palette.sidebarSelectionTint != nil)
    }

    @Test func malformedBackgroundFallsBackToDefault() {
        let theme = GhosttyThemeDefinition(
            name: "broken",
            background: "not-a-hex",
            foreground: "#ffffff"
        )
        let palette = ChromePalette(theme: theme)
        #expect(palette == .default)
    }

    @Test func accentPicksCursorWhenAvailable() {
        let theme = GhosttyThemeDefinition(
            name: "with-cursor",
            background: "#000000",
            foreground: "#ffffff",
            cursorColor: "#ff00ff"
        )
        let fg = RGBColor(hex: theme.foreground)!
        let bg = RGBColor(hex: theme.background)!
        let accent = ChromePalette.pickAccent(theme: theme, foreground: fg, background: bg)
        #expect(accent == RGBColor(hex: "#ff00ff"))
    }

    @Test func accentFallsBackToAnsiBlueWhenNoCursor() {
        let theme = GhosttyThemeDefinition(
            name: "no-cursor",
            background: "#ffffff",
            foreground: "#000000",
            palette: [4: "0000ff"]
        )
        let fg = RGBColor(hex: theme.foreground)!
        let bg = RGBColor(hex: theme.background)!
        let accent = ChromePalette.pickAccent(theme: theme, foreground: fg, background: bg)
        #expect(accent == RGBColor(hex: "#0000ff"))
    }

    @Test func accentFallsBackToForegroundWhenNoCandidates() {
        let theme = GhosttyThemeDefinition(
            name: "bare",
            background: "#000000",
            foreground: "#abcdef"
        )
        let fg = RGBColor(hex: theme.foreground)!
        let bg = RGBColor(hex: theme.background)!
        let accent = ChromePalette.pickAccent(theme: theme, foreground: fg, background: bg)
        #expect(accent == fg)
    }

    @Test func legibilityPickerChoosesHigherContrastCandidate() {
        // Background is mid-gray; primary candidate is similar gray
        // (low contrast), alternate is white (high contrast). The
        // alternate should win.
        let bg = RGBColor(hex: "#808080")!
        let lowContrast = RGBColor(hex: "#888888")!
        let highContrast = RGBColor(hex: "#ffffff")!
        let pick = ChromePalette.preferLegible(
            primary: lowContrast,
            alternate: highContrast,
            against: bg
        )
        #expect(pick == highContrast)
    }

    @Test func luminanceForBlackIsZero() {
        let black = RGBColor(red: 0, green: 0, blue: 0)
        #expect(black.relativeLuminance == 0)
    }

    @Test func luminanceForWhiteIsOne() {
        let white = RGBColor(red: 1, green: 1, blue: 1)
        #expect(abs(white.relativeLuminance - 1.0) < 0.0001)
    }

    @Test func contrastIsSymmetric() {
        let a = RGBColor(hex: "#101010")!
        let b = RGBColor(hex: "#f0f0f0")!
        let cAB = a.contrast(against: b)
        let cBA = b.contrast(against: a)
        #expect(abs(cAB - cBA) < 0.0001)
    }

    @Test func blendingInterpolatesChannels() {
        let a = RGBColor(red: 0, green: 0, blue: 0)
        let b = RGBColor(red: 1, green: 1, blue: 1)
        let mid = a.blended(with: b, ratio: 0.5)
        #expect(abs(mid.red - 0.5) < 0.0001)
        #expect(abs(mid.green - 0.5) < 0.0001)
        #expect(abs(mid.blue - 0.5) < 0.0001)
    }

    @Test func updateFromNilRevertsToDefault() {
        let chrome = ThemeChrome()
        let theme = GhosttyThemeDefinition(
            name: "x",
            background: "#1a1b26",
            foreground: "#c0caf5"
        )
        chrome.update(from: theme)
        #expect(chrome.palette != .default)
        chrome.update(from: nil)
        #expect(chrome.palette == .default)
    }
}
