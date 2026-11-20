// AgentMCPConfigSnippetsSiteTests.swift

import Foundation
import Testing
import BattyCLICore

nonisolated struct AgentMCPConfigSnippetsSiteTests {
    private static func snippetsURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "website/docs/snippets", directoryHint: .isDirectory)
    }

    @Test func committedSnippetsMatchTheRenderer() throws {
        for file in try AgentMCPConfigSnippets.siteFiles() {
            let committed = try? Data(contentsOf: Self.snippetsURL().appending(path: file.name))
            #expect(committed == Data(file.contents.utf8), "website/docs/snippets/\(file.name) is stale: run tools/build-agent-snippets.sh")
        }
    }

    @Test func snippetsFolderHoldsOnlyGeneratedFiles() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.snippetsURL().path(percentEncoded: false))
        #expect(Set(names) == Set(try AgentMCPConfigSnippets.siteFiles().map(\.name)), "run tools/build-agent-snippets.sh")
    }
}
