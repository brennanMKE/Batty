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

    // MARK: displayNameFromTitle — OSC 2 title parsing

    @Test func titleMatchesBareCommandName() {
        // omz's preexec sets OSC 2 title to the truncated command line.
        // For a short command, the title is just the command name.
        #expect(TUIAppRegistry.displayNameFromTitle("claude") == "Claude Code")
        #expect(TUIAppRegistry.displayNameFromTitle("vim") == nil) // not in registry
        #expect(TUIAppRegistry.displayNameFromTitle("aider") == "Aider")
    }

    @Test func titleMatchesCommandWithArgs() {
        // omz's preexec embeds the full command line (truncated to 100 chars).
        // The first whitespace-separated token is the command basename.
        #expect(TUIAppRegistry.displayNameFromTitle("claude --resume abc") == "Claude Code")
        #expect(TUIAppRegistry.displayNameFromTitle("aider --model gpt-4") == "Aider")
        #expect(TUIAppRegistry.displayNameFromTitle("cursor-agent --foo bar") == "Cursor CLI")
    }

    @Test func titleStripsZshTruncationMarker() {
        // zsh's "%100>...>" prompt-expansion prefix appears when the command
        // line exceeded 100 characters and zsh truncated it.
        #expect(TUIAppRegistry.displayNameFromTitle("...>claude --very-long-args") == "Claude Code")
    }

    @Test func titleMatchesDisplayNameVerbatim() {
        // A TUI may set its own OSC 2 title to its product name. Recognize
        // the canonical display name directly, case-insensitively.
        #expect(TUIAppRegistry.displayNameFromTitle("Claude Code") == "Claude Code")
        #expect(TUIAppRegistry.displayNameFromTitle("claude code") == "Claude Code")
        #expect(TUIAppRegistry.displayNameFromTitle("CLAUDE CODE") == "Claude Code")
    }

    @Test func titleRejectsPromptForm() {
        // omz's precmd resets the title to "%n@%m:%~" after a command exits.
        // We must not match these as commands.
        #expect(TUIAppRegistry.displayNameFromTitle("brennan@host:~/Developer/Batty") == nil)
        #expect(TUIAppRegistry.displayNameFromTitle("user@machine:/var/log") == nil)
    }

    @Test func titleRejectsPathLikeFirstToken() {
        // Paths shouldn't be interpreted as commands.
        #expect(TUIAppRegistry.displayNameFromTitle("~/Developer") == nil)
        #expect(TUIAppRegistry.displayNameFromTitle("/usr/local/bin/something") == nil)
    }

    @Test func titleReturnsNilForEmptyOrUnknown() {
        #expect(TUIAppRegistry.displayNameFromTitle("") == nil)
        #expect(TUIAppRegistry.displayNameFromTitle("   ") == nil)
        #expect(TUIAppRegistry.displayNameFromTitle("ls -la") == nil)
        #expect(TUIAppRegistry.displayNameFromTitle("unknown-binary --flag") == nil)
    }
}
