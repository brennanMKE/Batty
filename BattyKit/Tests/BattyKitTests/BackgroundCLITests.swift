// BackgroundCLITests.swift

import ArgumentParser
import BattyXPCCore
import Foundation
import Testing
@testable import batty

struct BackgroundCLITests {
    @Test func theTreeContainsBackgroundList() throws {
        let noun = try #require(BattyCLI.configuration.subcommands.first { $0.configuration.commandName == "background" })
        #expect(noun.configuration.subcommands.map { $0.configuration.commandName } == ["list"])
        #expect(CapabilitiesCommand.verbs().contains { $0.name == "background list" })
    }

    @Test func listParsesSetAndJSON() throws {
        let command = try BackgroundListCommand.parse(["--set", "Deep Space", "--json"])
        #expect(command.set == "Deep Space" && command.json)
    }

    @Test func tableShowsSetTitleIDAndDownloaded() {
        let table = BackgroundListCommand.table([
            BackgroundListEntry(set: "Deep Space", title: "Nebula", id: "https://example.invalid/n.png", source: .hosted, fullURL: "https://example.invalid/n.png", downloaded: true),
            BackgroundListEntry(set: "My Images", title: "cat.png", id: "abc123", source: .myImages, downloaded: true, digest: "abc123"),
        ])
        let lines = table.split(separator: "\n").map(String.init)
        #expect(lines[0].hasPrefix("SET") && lines[0].contains("TITLE") && lines[0].contains("ID") && lines[0].hasSuffix("DOWNLOADED"))
        #expect(lines[1].contains("Deep Space") && lines[1].contains("Nebula") && lines[1].contains("https://example.invalid/n.png") && lines[1].hasSuffix("yes"))
        #expect(lines[2].contains("abc123"))
        #expect(BackgroundListCommand.table([]) == "No background images.")
    }
}
