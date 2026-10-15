// SystemMetricsColorsTests.swift

import GhosttyTheme
import SwiftUI
import Testing
@testable import BattyKit

@MainActor
struct SystemMetricsColorsTests {
    private let dark = GhosttyThemeDefinition(
        name: "test-dark-green",
        background: "#0b2a1c",
        foreground: "#d6f5e3",
        cursorColor: "#3ddc84",
        palette: [4: "2e8bff", 6: "20c9c9"]
    )
    private let light = GhosttyThemeDefinition(
        name: "test-light-sand",
        background: "#f6efe0",
        foreground: "#3b2f1a",
        cursorColor: "#b5651d",
        palette: [4: "1f5fbf", 6: "1a8a8a"]
    )

    @Test func noThemeKeepsSystemLook() {
        for palette in [nil, ChromePalette.default] {
            let colors = SystemMetricsColors(palette: palette)
            #expect(colors.tableBackground == nil)
            #expect(colors.separator == nil)
            #expect(colors.foreground == nil)
            #expect(colors.mutedForeground == nil)
            #expect(colors.border == SystemMetricsColors.systemBorder)
            #expect(colors.accent == Color.accentColor)
        }
    }

    @Test func darkThemeUsesPaletteSlots() {
        let palette = ChromePalette(theme: dark)
        let colors = SystemMetricsColors(palette: palette)
        #expect(colors.tableBackground == palette.chromeBackground)
        #expect(colors.separator == palette.divider)
        #expect(colors.border == palette.divider)
        #expect(colors.foreground == palette.chromeForeground)
        #expect(colors.mutedForeground == palette.chromeMutedForeground)
        #expect(colors.accent == palette.accent)
        #expect(colors.tableBackground != nil)
        #expect(colors.accent != Color.accentColor)
        #expect(colors.border != SystemMetricsColors.systemBorder)
    }

    @Test func lightThemeDiffersFromDarkTheme() {
        let darkColors = SystemMetricsColors(palette: ChromePalette(theme: dark))
        let lightPalette = ChromePalette(theme: light)
        let lightColors = SystemMetricsColors(palette: lightPalette)
        #expect(lightColors.tableBackground == lightPalette.chromeBackground)
        #expect(lightColors.foreground == lightPalette.chromeForeground)
        #expect(lightColors.accent == lightPalette.accent)
        #expect(lightColors.tableBackground != darkColors.tableBackground)
        #expect(lightColors.foreground != darkColors.foreground)
        #expect(lightColors.separator != darkColors.separator)
    }
}
