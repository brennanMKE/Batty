// CommandPaletteFilterTests.swift

import Foundation
import Testing
@testable import BattyKit

struct CommandPaletteFilterTests {

    private func makeCommands(_ titles: [String]) -> [PaletteCommand] {
        titles.map { title in
            PaletteCommand(id: "test:\(title)", title: title, keyHint: nil, action: {})
        }
    }

    // MARK: empty / passthrough

    @Test func emptyQueryReturnsAllInInputOrder() {
        let commands = makeCommands(["New Session", "Close Tab", "Split Vertically"])
        let filtered = CommandPaletteFilter.apply(query: "", to: commands)
        #expect(filtered.map(\.title) == ["New Session", "Close Tab", "Split Vertically"])
    }

    @Test func unmatchedQueryReturnsEmpty() {
        let commands = makeCommands(["New Session", "Close Tab", "Split Vertically"])
        let filtered = CommandPaletteFilter.apply(query: "xyz", to: commands)
        #expect(filtered.isEmpty)
    }

    // MARK: the reproduction — Theme: Re

    @Test func themeReQueryNarrowsToRebecca() {
        let commands = makeCommands([
            "Theme: Mocha",
            "Theme: Rebecca",
            "Theme: Solarized Dark",
            "Theme: Solarized Light",
            "Theme: Red Velvet",
        ])
        let filtered = CommandPaletteFilter.apply(query: "Theme: Re", to: commands)
        let titles = Set(filtered.map(\.title))
        #expect(titles.contains("Theme: Rebecca"))
        #expect(titles.contains("Theme: Red Velvet"))
        #expect(!titles.contains("Theme: Mocha"))
    }

    @Test func themeRebeccaQueryNarrowsToOnlyRebecca() {
        let commands = makeCommands([
            "Theme: Mocha",
            "Theme: Rebecca",
            "Theme: Solarized Dark",
        ])
        let filtered = CommandPaletteFilter.apply(query: "Rebecca", to: commands)
        #expect(filtered.map(\.title) == ["Theme: Rebecca"])
    }

    // MARK: case insensitivity

    @Test func upperCaseQueryMatchesLowerCaseTitle() {
        let commands = makeCommands(["new session", "close tab"])
        let filtered = CommandPaletteFilter.apply(query: "NEW", to: commands)
        #expect(filtered.map(\.title) == ["new session"])
    }

    @Test func mixedCaseQueryMatchesMixedCaseTitle() {
        let commands = makeCommands(["New Session", "Close Tab"])
        let filtered = CommandPaletteFilter.apply(query: "nEw sEs", to: commands)
        #expect(filtered.map(\.title) == ["New Session"])
    }

    // MARK: subsequence match

    @Test func subsequenceMatchHits() {
        let commands = makeCommands(["Split Horizontally", "Split Vertically", "Close Tab"])
        // "splt" is a scattered subsequence of both Split entries
        let filtered = CommandPaletteFilter.apply(query: "splt", to: commands)
        let titles = Set(filtered.map(\.title))
        #expect(titles == Set(["Split Horizontally", "Split Vertically"]))
    }

    // MARK: substring contiguity ranking

    @Test func contiguousMatchRanksAboveScattered() {
        let commands = makeCommands(["Bartleby Ire", "Bird"])
        let filtered = CommandPaletteFilter.apply(query: "bir", to: commands)
        #expect(filtered.first?.title == "Bird")
    }

    @Test func prefixMatchRanksAboveInterior() {
        let commands = makeCommands(["Theme: Mockingbird", "Bird"])
        let filtered = CommandPaletteFilter.apply(query: "Bird", to: commands)
        #expect(filtered.first?.title == "Bird")
    }

    // MARK: identity stability

    @Test func commandIdsAreStableAcrossFilterCalls() {
        let commands = makeCommands(["New Session", "Close Tab"])
        let firstIds = commands.map(\.id)
        let secondIds = commands.map(\.id)
        #expect(firstIds == secondIds)
    }

    @Test func filteredCommandIdsMatchSourceIds() {
        let commands = makeCommands(["New Session", "Close Tab"])
        let filtered = CommandPaletteFilter.apply(query: "new", to: commands)
        #expect(filtered.first?.id == "test:New Session")
    }
}
