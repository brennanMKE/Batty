// TabRuntimeRunningCommandTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct TabRuntimeRunningCommandTests {

    @Test func refreshSetsDisplayNameForKnownTitle() {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("claude")
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")
    }

    @Test func refreshHandlesCommandWithArgs() {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("aider --model gpt-4")
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Aider")
    }

    @Test func refreshHandlesZshTruncatedTitle() {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("...>claude --resume very-long-session-id-here")
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")
    }

    @Test func refreshClearsOnPromptForm() {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("claude")
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")
        tab.terminal.terminalDidChangeTitle("brennan@host:~/Developer/Batty")
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == nil)
    }

    @Test func refreshClearsOnUnknownCommand() {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("claude")
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")
        tab.terminal.terminalDidChangeTitle("ls -la")
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == nil)
    }

    @Test func refreshRecognizesDisplayNameVerbatim() {
        // A TUI might set its own OSC 2 title to its product name.
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("Claude Code")
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")
    }

    @Test func commandFinishedClearsRunningName() {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("claude")
        tab.refreshRunningCommandFromTitle()
        #expect(tab.runningCommandDisplayName == "Claude Code")

        // Simulate libghostty's OSC 133 D callback: command-finished sets
        // `lastCommandDurationNanos` to a non-nil value.
        tab.terminal.terminalDidFinishCommand(exitCode: 0, durationNanos: 1_000)
        let cleared = tab.recordCommandFinishedIfNeeded()
        #expect(cleared == true)
        #expect(tab.runningCommandDisplayName == nil)
    }

    @Test func commandFinishedIsIdempotent() {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("claude")
        tab.refreshRunningCommandFromTitle()
        tab.terminal.terminalDidFinishCommand(exitCode: 0, durationNanos: 1_000)
        let first = tab.recordCommandFinishedIfNeeded()
        let second = tab.recordCommandFinishedIfNeeded()
        #expect(first == true)
        #expect(second == false)
    }

    @Test func refreshDoesNotOverwriteWhenDerivedMatches() {
        let tab = TabRuntime()
        tab.terminal.terminalDidChangeTitle("claude")
        tab.refreshRunningCommandFromTitle()
        let first = tab.runningCommandDisplayName
        tab.refreshRunningCommandFromTitle()
        let second = tab.runningCommandDisplayName
        #expect(first == second)
        #expect(second == "Claude Code")
    }
}
