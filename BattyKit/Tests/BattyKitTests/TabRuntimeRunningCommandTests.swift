// TabRuntimeRunningCommandTests.swift

import Foundation
import Observation
import Testing
@testable import BattyKit

private nonisolated final class RunningCommandChangeFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
struct TabRuntimeRunningCommandTests {

    @Test func knownTitleSetsDisplayNameBeforeThePublishLands() async {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("claude")
        #expect(tab.terminal.title == "")
        #expect(tab.runningCommandDisplayName == "Claude Code")
        await awaitTerminalStatePublish { tab.terminal.title == "claude" }
        #expect(tab.runningCommandDisplayName == "Claude Code")
    }

    @Test func titleWithArgumentsSetsDisplayName() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("aider --model gpt-4")
        #expect(tab.runningCommandDisplayName == "Aider")
    }

    @Test func zshTruncatedTitleSetsDisplayName() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("...>claude --resume very-long-session-id-here")
        #expect(tab.runningCommandDisplayName == "Claude Code")
    }

    @Test func promptTitleDoesNotClearDisplayName() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("claude")
        #expect(tab.runningCommandDisplayName == "Claude Code")
        tab.terminalDelegate.terminalDidChangeTitle("brennan@host:~/Developer/Batty")
        #expect(tab.runningCommandDisplayName == "Claude Code")
    }

    @Test func unknownTitleDoesNotClearDisplayName() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("claude")
        tab.terminalDelegate.terminalDidChangeTitle("Some Inner Claude State")
        #expect(tab.runningCommandDisplayName == "Claude Code")
    }

    @Test func secondKnownTitleReplacesTheFirst() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("claude")
        tab.terminalDelegate.terminalDidChangeTitle("aider")
        #expect(tab.runningCommandDisplayName == "Aider")
    }

    @Test func displayNameTitleIsRecognizedVerbatim() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("Claude Code")
        #expect(tab.runningCommandDisplayName == "Claude Code")
    }

    @Test func commandFinishedClearsDisplayNameSynchronously() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("claude")
        #expect(tab.runningCommandDisplayName == "Claude Code")
        tab.terminalDelegate.terminalDidFinishCommand(exitCode: 0, durationNanos: 1_000)
        #expect(tab.runningCommandDisplayName == nil)
    }

    @Test func commandFinishedClearsAgainWithTheSameDuration() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("claude")
        tab.terminalDelegate.terminalDidFinishCommand(exitCode: 0, durationNanos: 1_000)
        #expect(tab.runningCommandDisplayName == nil)
        tab.terminalDelegate.terminalDidChangeTitle("claude")
        #expect(tab.runningCommandDisplayName == "Claude Code")
        tab.terminalDelegate.terminalDidFinishCommand(exitCode: 0, durationNanos: 1_000)
        #expect(tab.runningCommandDisplayName == nil)
    }

    @Test func commandFinishedDoesNotChangeTheTitleMirror() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("vim - notes.txt")
        tab.terminalDelegate.terminalDidFinishCommand(exitCode: 0, durationNanos: 1_000)
        #expect(tab.terminalTitle == "vim - notes.txt")
        #expect(TabTitleFormatter.chipTitle(for: tab) == "vim - notes.txt")
    }

    /// `receiveTitleChange` writes the derived name unconditionally and
    /// relies on the `@Observable` setter skipping an equal `Equatable`
    /// write. This fails if that toolchain behaviour changes.
    @Test func sameDisplayNameFromANewTitleDoesNotRenotify() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("claude")
        let changed = RunningCommandChangeFlag()
        withObservationTracking { _ = tab.runningCommandDisplayName } onChange: { changed.fired = true }
        tab.terminalDelegate.terminalDidChangeTitle("claude --resume abc")
        #expect(!changed.fired)
        #expect(tab.runningCommandDisplayName == "Claude Code")
        #expect(tab.terminalTitle == "claude --resume abc")
    }
}
