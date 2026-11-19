// AgentGlobalInstructionsPromptTests.swift

import BattyCLICore
import Foundation
import Testing

nonisolated struct AgentGlobalInstructionsPromptTests {
    private static let paths = ["~/.claude/CLAUDE.md", "~/.codex/AGENTS.md", "~/.config/opencode/AGENTS.md"]

    @Test func promptNamesEveryGlobalInstructionsFile() {
        for path in Self.paths {
            #expect(AgentGlobalInstructionsPrompt.text.contains(path))
        }
        #expect(AgentGlobalInstructionsPrompt.text.contains("User Rules"))
        #expect(AgentGlobalInstructionsPrompt.destinations.map(\.path) == Self.paths)
    }

    @Test func noteStartsWithTheHeadingAndTheEnvCheck() {
        let note = AgentGlobalInstructionsPrompt.note
        #expect(note.hasPrefix("## Batty\n\nAt the start of a session, run `env | grep '^BATTY'`."))
        for key in ["BATTY_SESSION_ID", "BATTY_TAB_ID", "BATTY_PANE_ID"] {
            #expect(note.contains(key))
        }
    }

    @Test func noteEndsWithTheIgnoreLine() {
        #expect(AgentGlobalInstructionsPrompt.note.hasSuffix("If those variables are not set, you are not in Batty; ignore this section."))
    }

    @Test func noteCarriesEverySharedRuleLine() {
        let lines = AgentGlobalInstructionsPrompt.note.components(separatedBy: "\n")
        for rule in AgentContextNote.ruleLines(cliName: "batty") {
            #expect(lines.contains(rule))
        }
    }

    @Test func noteNamesBothCLIs() {
        let note = AgentGlobalInstructionsPrompt.note
        #expect(note.contains("`batty-beta`"))
        #expect(note.contains("`batty mcp`"))
        #expect(!note.contains("batty-beta capabilities"))
    }

    @Test func noteHasExactlyOneHeading() {
        let note = AgentGlobalInstructionsPrompt.note
        let headings = note.components(separatedBy: "\n").filter { $0.hasPrefix("#") }
        #expect(headings == ["## Batty"])
        #expect(!note.contains("```"))
    }

    @Test func promptEmbedsTheNoteInAFence() {
        let text = AgentGlobalInstructionsPrompt.text
        #expect(text.contains("```markdown\n" + AgentGlobalInstructionsPrompt.note + "\n```"))
        #expect(text.contains("replace that whole section"))
        #expect(text.contains("do not add a second one"))
    }

    @Test(arguments: [".claude/skills/batty-cli/SKILL.md", "docs/batty-cli-agent-workflows.md"])
    func documentsCarryThePrompt(relativePath: String) throws {
        // #filePath: .../BattyKit/Tests/BattyKitTests/AgentGlobalInstructionsPromptTests.swift
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath, directoryHint: .notDirectory)
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains(AgentGlobalInstructionsPrompt.text))
    }
}
