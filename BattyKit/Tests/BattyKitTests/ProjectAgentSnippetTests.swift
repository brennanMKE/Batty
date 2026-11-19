// ProjectAgentSnippetTests.swift

import BattyCLICore
import Foundation
import Testing

nonisolated struct ProjectAgentSnippetTests {
    private func directory(_ files: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "batty-0647-snippet-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(to: directory.appending(path: name))
        }
        return directory
    }

    @Test func prefersAgentsMDWhenClaudeMDImportsIt() throws {
        let dir = try directory(["AGENTS.md": "# A\n", "CLAUDE.md": "@AGENTS.md\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ProjectAgentSnippet.targetFile(in: dir).lastPathComponent == "AGENTS.md")
    }

    @Test func prefersAgentsMDWhenItIsTheOnlyFile() throws {
        let dir = try directory(["AGENTS.md": "# A\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ProjectAgentSnippet.targetFile(in: dir).lastPathComponent == "AGENTS.md")
    }

    @Test func usesClaudeMDWhenItDoesNotImportAgentsMD() throws {
        let dir = try directory(["AGENTS.md": "# A\n", "CLAUDE.md": "# C\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ProjectAgentSnippet.targetFile(in: dir).lastPathComponent == "CLAUDE.md")
    }

    @Test func usesClaudeMDWhenItIsTheOnlyFile() throws {
        let dir = try directory(["CLAUDE.md": "# C\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ProjectAgentSnippet.targetFile(in: dir).lastPathComponent == "CLAUDE.md")
    }

    @Test func createsAgentsMDWhenNeitherExists() throws {
        let dir = try directory([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ProjectAgentSnippet.targetFile(in: dir).lastPathComponent == "AGENTS.md")
        #expect(try ProjectAgentSnippet.apply(to: nil) == ProjectAgentSnippet.block + "\n")
    }

    @Test func insertsTheMarkedBlockOnce() throws {
        let result = try ProjectAgentSnippet.apply(to: "# Project\n")
        #expect(result == "# Project\n\n" + ProjectAgentSnippet.block + "\n")
        #expect(result.ranges(of: ProjectAgentSnippet.beginMarker).count == 1)
    }

    @Test func rerunReplacesTheBlockInsteadOfDuplicating() throws {
        let once = try ProjectAgentSnippet.apply(to: "# Project\n")
        let twice = try ProjectAgentSnippet.apply(to: once)
        #expect(twice == once)
        let stale = once.replacingOccurrences(of: "batty notify", with: "old text")
        #expect(try ProjectAgentSnippet.apply(to: stale) == once)
    }

    @Test func textOutsideTheMarkersIsPreservedByteForByte() throws {
        let before = "# Rules\r\n\nKeep  two  spaces.\t\n\n"
        let after = "\n\n## After\nTrailing text with no newline"
        let existing = before + ProjectAgentSnippet.beginMarker + "\nold body\n" + ProjectAgentSnippet.endMarker + after
        let result = try ProjectAgentSnippet.apply(to: existing)
        #expect(result == before + ProjectAgentSnippet.block + after)
    }

    @Test func unmatchedMarkerIsRefused() {
        #expect(throws: ProjectAgentSnippet.SnippetError.unmatchedMarker) {
            try ProjectAgentSnippet.apply(to: "x\n" + ProjectAgentSnippet.beginMarker + "\nno end\n")
        }
        #expect(throws: ProjectAgentSnippet.SnippetError.unmatchedMarker) {
            try ProjectAgentSnippet.apply(to: ProjectAgentSnippet.endMarker + "\n" + ProjectAgentSnippet.beginMarker)
        }
    }

    @Test func nonTTYWithoutYesIsRefused() {
        #expect(ProjectAgentSnippet.confirmationRequired(isTTY: false, yes: false, dryRun: false) == .refuse)
        #expect(ProjectAgentSnippet.confirmationRequired(isTTY: false, yes: true, dryRun: false) == .write)
        #expect(ProjectAgentSnippet.confirmationRequired(isTTY: true, yes: false, dryRun: false) == .prompt)
    }

    @Test func dryRunNeverWrites() {
        #expect(ProjectAgentSnippet.confirmationRequired(isTTY: true, yes: true, dryRun: true) == .preview)
        #expect(ProjectAgentSnippet.confirmationRequired(isTTY: false, yes: false, dryRun: true) == .preview)
    }

    @Test func blockCarriesTheSharedRuleLines() {
        for line in AgentContextNote.ruleLines(cliName: "batty") {
            #expect(ProjectAgentSnippet.block.contains(line))
        }
        #expect(ProjectAgentSnippet.block.hasPrefix(ProjectAgentSnippet.beginMarker))
        #expect(ProjectAgentSnippet.block.hasSuffix(ProjectAgentSnippet.endMarker))
    }
}
