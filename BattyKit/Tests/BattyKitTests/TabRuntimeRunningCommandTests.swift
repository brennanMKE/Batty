// TabRuntimeRunningCommandTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct TabRuntimeRunningCommandTests {

    @Test func refreshSetsDisplayNameForKnownTitle() async {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("claude")
        await awaitTerminalStatePublish { tab.terminal.title == "claude" }
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")
    }

    @Test func refreshHandlesCommandWithArgs() async {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("aider --model gpt-4")
        await awaitTerminalStatePublish { tab.terminal.title == "aider --model gpt-4" }
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Aider")
    }

    @Test func refreshHandlesZshTruncatedTitle() async {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("...>claude --resume very-long-session-id-here")
        await awaitTerminalStatePublish { tab.terminal.title == "...>claude --resume very-long-session-id-here" }
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")
    }

    @Test func refreshDoesNotClearOnPromptForm() async {
        // TUIs (claude, vim, ssh) routinely mutate OSC 2 mid-session to
        // a non-registry value. The title-driven path must NOT clear on
        // a miss — clearing is the command-finished path's job.
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("claude")
        await awaitTerminalStatePublish { tab.terminal.title == "claude" }
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")
        tab.terminal.terminalDidChangeTitle("brennan@host:~/Developer/Batty")
        await awaitTerminalStatePublish { tab.terminal.title == "brennan@host:~/Developer/Batty" }
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")
    }

    @Test func refreshDoesNotClearOnUnknownTitle() async {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("claude")
        await awaitTerminalStatePublish { tab.terminal.title == "claude" }
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")
        tab.terminal.terminalDidChangeTitle("Some Inner Claude State")
        await awaitTerminalStatePublish { tab.terminal.title == "Some Inner Claude State" }
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")
    }

    @Test func refreshFlipsBetweenKnownTUIs() async {
        // If one TUI's title is replaced by another known TUI's title
        // (rare but possible — chained tools), the latest one wins.
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("claude")
        await awaitTerminalStatePublish { tab.terminal.title == "claude" }
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")
        tab.terminal.terminalDidChangeTitle("aider")
        await awaitTerminalStatePublish { tab.terminal.title == "aider" }
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Aider")
    }

    @Test func refreshRecognizesDisplayNameVerbatim() async {
        // A TUI might set its own OSC 2 title to its product name.
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("Claude Code")
        await awaitTerminalStatePublish { tab.terminal.title == "Claude Code" }
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")
    }

    @Test func commandFinishedClearsRunningName() async {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("claude")
        await awaitTerminalStatePublish { tab.terminal.title == "claude" }
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")

        // Simulate libghostty's OSC 133 D callback: command-finished sets
        // `lastCommandDurationNanos` to a non-nil value.
        tab.terminal.terminalDidFinishCommand(exitCode: 0, durationNanos: 1_000)
        await awaitTerminalStatePublish { tab.terminal.lastCommandDurationNanos != nil }
        let cleared = tab.recordCommandFinishedIfNeeded()
        #expect(cleared == true)
        #expect(tab.runningCommandDisplayName == nil)
    }

    @Test func commandFinishedIsIdempotent() async {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("claude")
        await awaitTerminalStatePublish { tab.terminal.title == "claude" }
        tab.refreshRunningCommandFromTitle()
        tab.terminal.terminalDidFinishCommand(exitCode: 0, durationNanos: 1_000)
        await awaitTerminalStatePublish { tab.terminal.lastCommandDurationNanos != nil }
        let first = tab.recordCommandFinishedIfNeeded()
        let second = tab.recordCommandFinishedIfNeeded()
        #expect(first == true)
        #expect(second == false)
    }

    @Test func refreshDoesNotOverwriteWhenDerivedMatches() async {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("claude")
        await awaitTerminalStatePublish { tab.terminal.title == "claude" }
        tab.refreshRunningCommandFromTitle()
        let first = tab.runningCommandDisplayName
        tab.refreshRunningCommandFromTitle()
        let second = tab.runningCommandDisplayName
        #expect(first == second)
        #expect(second == "Claude Code")
    }
}
