// TUIAppRegistryTests.swift

import Foundation
import Testing
@testable import BattyKit

struct TUIAppRegistryTests {

    @Test func returnsDisplayNameForKnownCommand() {
        #expect(TUIAppRegistry.displayName(for: "claude") == "Claude Code")
    }

    @Test func stripsFullPathToBasename() {
        #expect(TUIAppRegistry.displayName(for: "/opt/homebrew/bin/claude") == "Claude Code")
        #expect(TUIAppRegistry.displayName(for: "/usr/local/bin/aider") == "Aider")
    }

    @Test func lookupIsCaseInsensitive() {
        #expect(TUIAppRegistry.displayName(for: "CLAUDE") == "Claude Code")
        #expect(TUIAppRegistry.displayName(for: "Claude") == "Claude Code")
        #expect(TUIAppRegistry.displayName(for: "/usr/bin/CLAUDE") == "Claude Code")
    }

    @Test func aliasesShareDisplayName() {
        // `pdx` and `plandex` both resolve to "Plandex".
        #expect(TUIAppRegistry.displayName(for: "plandex") == "Plandex")
        #expect(TUIAppRegistry.displayName(for: "pdx") == "Plandex")
    }

    @Test func unknownCommandsReturnNil() {
        #expect(TUIAppRegistry.displayName(for: "ls") == nil)
        #expect(TUIAppRegistry.displayName(for: "/usr/bin/ls") == nil)
        #expect(TUIAppRegistry.displayName(for: "") == nil)
    }

    @Test func hyphenatedCommandsResolve() {
        // cursor-agent has a hyphen — verify lookup handles it.
        #expect(TUIAppRegistry.displayName(for: "cursor-agent") == "Cursor CLI")
        #expect(TUIAppRegistry.displayName(for: "/usr/local/bin/cursor-agent") == "Cursor CLI")
    }

    @Test func frontierAgentsAreSeeded() {
        // Spot-check the user's canonical list.
        #expect(TUIAppRegistry.displayName(for: "codex") == "Codex")
        #expect(TUIAppRegistry.displayName(for: "opencode") == "OpenCode")
        #expect(TUIAppRegistry.displayName(for: "gemini") == "Gemini CLI")
        #expect(TUIAppRegistry.displayName(for: "copilot") == "GitHub Copilot CLI")
        #expect(TUIAppRegistry.displayName(for: "q") == "Amazon Q Developer")
    }
}
