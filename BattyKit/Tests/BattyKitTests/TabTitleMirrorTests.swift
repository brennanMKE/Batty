// TabTitleMirrorTests.swift

import Foundation
import Observation
import Testing
@testable import BattyKit

private nonisolated final class TitleChangeFlag: @unchecked Sendable {
    var fired = false
}

/// The OSC 2 title reaches `TabRuntime.terminalTitle` synchronously in the
/// delegate callback, with no view mounted (#0563).
@MainActor
struct TabTitleMirrorTests {

    @Test func titleCallbackUpdatesTheMirrorBeforeThePublishLands() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("vim - notes.txt")
        #expect(tab.terminal.title == "")
        #expect(tab.terminalTitle == "vim - notes.txt")
    }

    /// `receiveTitleChange` writes unconditionally and relies on the
    /// `@Observable` setter skipping an equal `Equatable` write. This fails
    /// if that toolchain behaviour changes.
    @Test func equalTitleDoesNotRenotifyTheMirror() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("htop")
        let same = TitleChangeFlag()
        withObservationTracking { _ = tab.terminalTitle } onChange: { same.fired = true }
        tab.terminalDelegate.terminalDidChangeTitle("htop")
        #expect(!same.fired)

        let moved = TitleChangeFlag()
        withObservationTracking { _ = tab.terminalTitle } onChange: { moved.fired = true }
        tab.terminalDelegate.terminalDidChangeTitle("top")
        #expect(moved.fired)
    }

    @Test func chipTitleFollowsANonRegistryTitleWithNoViewMounted() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("brennan@host:~/src/batty")
        #expect(TabTitleFormatter.chipTitle(for: tab) == "batty")
        tab.terminalDelegate.terminalDidChangeTitle("vim - notes.txt")
        #expect(TabTitleFormatter.chipTitle(for: tab) == "vim - notes.txt")
    }

    @Test func chipTitleObservationFiresOnTitleCallback() {
        let tab = TabRuntime()
        let changed = TitleChangeFlag()
        withObservationTracking { _ = TabTitleFormatter.chipTitle(for: tab) } onChange: { changed.fired = true }
        tab.terminalDelegate.terminalDidChangeTitle("htop")
        #expect(changed.fired)
    }

    @Test func chipTitleObservationFiresOnCommandFinished() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("claude")
        #expect(TabTitleFormatter.chipTitle(for: tab) == "Claude Code")
        let changed = TitleChangeFlag()
        withObservationTracking { _ = TabTitleFormatter.chipTitle(for: tab) } onChange: { changed.fired = true }
        tab.terminalDelegate.terminalDidFinishCommand(exitCode: 0, durationNanos: 1_000)
        #expect(changed.fired)
        #expect(TabTitleFormatter.chipTitle(for: tab) == "claude")
    }

    @Test func tabLabelReadsTheMirrorInsideTheCallbackTurn() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidChangeTitle("ssh prod-box")
        #expect(AppStateStore.tabLabel(for: tab, tabIndex: 3) == "ssh prod-box")
    }
}
