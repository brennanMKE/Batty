// ThemeTests.swift

import Foundation
import Testing
@testable import BattyKit

struct ThemeTests {

    @Test func hexParsesSixCharForm() {
        let c = ThemeColor(hex: "#1a2b3c")
        #expect(c?.red == Double(0x1a) / 255.0)
        #expect(c?.green == Double(0x2b) / 255.0)
        #expect(c?.blue == Double(0x3c) / 255.0)
    }

    @Test func hexAcceptsLeading0xAndNoPrefix() {
        let a = ThemeColor(hex: "0xff0000")
        let b = ThemeColor(hex: "ff0000")
        let c = ThemeColor(hex: "#ff0000")
        #expect(a == b)
        #expect(b == c)
        #expect(a?.red == 1.0)
    }

    @Test func hexRejectsMalformed() {
        #expect(ThemeColor(hex: "#xyz") == nil)
        #expect(ThemeColor(hex: "#fff") == nil)
        #expect(ThemeColor(hex: "") == nil)
        #expect(ThemeColor(hex: "#1234567") == nil)
    }

    @Test func parserAcceptsCanonicalFixture() throws {
        let source = """
        # Sample theme
        background = #1a1b26
        foreground = #c0caf5
        cursor-color = #c0caf5
        selection-background = #283457
        selection-foreground = #c0caf5
        palette = 0=#15161e
        palette = 1=#f7768e
        palette = 2=#9ece6a
        palette = 3=#e0af68
        palette = 4=#7aa2f7
        palette = 5=#bb9af7
        palette = 6=#7dcfff
        palette = 7=#a9b1d6
        palette = 8=#414868
        palette = 9=#f7768e
        palette = 10=#9ece6a
        palette = 11=#e0af68
        palette = 12=#7aa2f7
        palette = 13=#bb9af7
        palette = 14=#7dcfff
        palette = 15=#c0caf5
        """
        let theme = try ThemeParser.parse(source, name: "tokyonight")
        #expect(theme.name == "tokyonight")
        #expect(theme.foreground == ThemeColor(hex: "#c0caf5"))
        #expect(theme.background == ThemeColor(hex: "#1a1b26"))
        #expect(theme.cursor == ThemeColor(hex: "#c0caf5"))
        #expect(theme.selectionBackground == ThemeColor(hex: "#283457"))
        #expect(theme.selectionForeground == ThemeColor(hex: "#c0caf5"))
        #expect(theme.palette.count == 16)
        #expect(theme.palette[0] == ThemeColor(hex: "#15161e"))
        #expect(theme.palette[15] == ThemeColor(hex: "#c0caf5"))
    }

    @Test func parserRejectsMissingBackground() {
        let source = """
        foreground = #ffffff
        palette = 0=#000000
        """
        #expect(throws: ThemeParseError.missingBackground) {
            _ = try ThemeParser.parse(source, name: "x")
        }
    }

    @Test func parserRejectsMissingPaletteEntry() {
        let source = """
        foreground = #ffffff
        background = #000000
        palette = 0=#000000
        palette = 1=#111111
        """
        #expect(throws: ThemeParseError.missingPaletteEntry(2)) {
            _ = try ThemeParser.parse(source, name: "x")
        }
    }

    @Test func parserSkipsBlankLinesAndComments() throws {
        let source = """
        # comment line one

        foreground = #ffffff
            # indented comment

        background = #000000
        \(paletteAllSame(hex: "#aaaaaa"))
        """
        let t = try ThemeParser.parse(source, name: "x")
        #expect(t.foreground == ThemeColor(hex: "#ffffff"))
        #expect(t.background == ThemeColor(hex: "#000000"))
    }

    @Test func builtInThemesAreValid() {
        let names = Set(ThemeStore.builtInThemes.map(\.name))
        #expect(names.contains("Batty Dark"))
        #expect(names.contains("Batty Light"))
        #expect(names.contains("Solarized Dark"))
        #expect(names.contains("Dracula"))
        for theme in ThemeStore.builtInThemes {
            #expect(theme.palette.count == 16, "theme \(theme.name) has \(theme.palette.count) palette entries")
        }
    }

    @Test func discoverAllReturnsBuiltInsWhenNoFilesExist() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("batty-theme-test-\(UUID().uuidString)")
        let themes = ThemeStore.discoverAll(homeDirectory: tmp)
        let names = Set(themes.map(\.name))
        #expect(names.contains("Batty Dark"))
        #expect(themes.count >= ThemeStore.builtInThemes.count)
    }

    private func paletteAllSame(hex: String) -> String {
        (0..<16).map { "palette = \($0)=\(hex)" }.joined(separator: "\n")
    }
}
