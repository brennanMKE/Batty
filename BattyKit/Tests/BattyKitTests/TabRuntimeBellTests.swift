// TabRuntimeBellTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct TabRuntimeBellTests {

    @Test func recordBellTickReturnsDeltaAndUpdatesMirror() async {
        let tab = TabRuntime()
        tab.terminal.terminalDidRingBell()
        await awaitTerminalStatePublish { tab.terminal.bellCount > 0 }
        let delta = tab.recordBellTickIfNeeded()
        #expect(delta == 1)
        #expect(tab.bellCount == 1)
        #expect(tab.lastBellAt != nil)
        #expect(tab.lastBellMessage == nil)
    }

    /// `publishSoon` captures `Date()` at the instant the bell rang, before
    /// deferring the write — not at the instant the deferred publish drains
    /// (`TerminalViewState+Delegate.swift`'s `terminalDidRingBell`). The
    /// artificial delay makes those two instants provably different, so a
    /// mirror write that captured "now" at drain time instead of forwarding
    /// `terminal.lastBellAt` would show up as inequality here.
    @Test func recordBellTickCapturesTheRingInstantNotTheDrainInstant() async {
        let tab = TabRuntime()
        tab.terminal.terminalDidRingBell()
        await awaitTerminalStatePublish { tab.terminal.bellCount > 0 }
        _ = tab.recordBellTickIfNeeded()
        #expect(tab.lastBellAt == tab.terminal.lastBellAt)
    }

    @Test func recordBellTickIsIdempotentBetweenTicks() async {
        let tab = TabRuntime()
        tab.terminal.terminalDidRingBell()
        await awaitTerminalStatePublish { tab.terminal.bellCount > 0 }
        _ = tab.recordBellTickIfNeeded()
        let secondDelta = tab.recordBellTickIfNeeded()
        #expect(secondDelta == 0)
        #expect(tab.bellCount == 1)
    }

    @Test func recordBellTickHandlesBurstDelta() async {
        let tab = TabRuntime()
        for _ in 0..<5 { tab.terminal.terminalDidRingBell() }
        await awaitTerminalStatePublish { tab.terminal.bellCount >= 5 }
        let delta = tab.recordBellTickIfNeeded()
        #expect(delta == 5)
        #expect(tab.bellCount == 5)
    }

    @Test func recordDesktopNotificationFormatsTitleAndBody() async {
        let tab = TabRuntime()
        tab.terminal.terminalDidRequestDesktopNotification(
            title: "Build", body: "Succeeded"
        )
        await awaitTerminalStatePublish { tab.terminal.lastDesktopNotificationAt != nil }
        let recorded = tab.recordDesktopNotificationIfNeeded()
        #expect(recorded == true)
        #expect(tab.lastBellMessage == "Build: Succeeded")
        #expect(tab.bellCount == 1)
    }

    /// Same instant-capture property as
    /// `recordBellTickCapturesTheRingInstantNotTheDrainInstant`, for the
    /// notification path's `let at = Date()` in
    /// `terminalDidRequestDesktopNotification`.
    @Test func recordDesktopNotificationCapturesTheRequestInstantNotTheDrainInstant() async {
        let tab = TabRuntime()
        tab.terminal.terminalDidRequestDesktopNotification(
            title: "Build", body: "Succeeded"
        )
        await awaitTerminalStatePublish { tab.terminal.lastDesktopNotificationAt != nil }
        _ = tab.recordDesktopNotificationIfNeeded()
        #expect(tab.lastBellAt == tab.terminal.lastDesktopNotificationAt)
    }

    @Test func recordDesktopNotificationFallsBackWhenTitleMissing() async {
        let tab = TabRuntime()
        tab.terminal.terminalDidRequestDesktopNotification(
            title: "", body: "hello"
        )
        await awaitTerminalStatePublish { tab.terminal.lastDesktopNotificationAt != nil }
        _ = tab.recordDesktopNotificationIfNeeded()
        #expect(tab.lastBellMessage == "hello")
    }

    @Test func recordDesktopNotificationIsIdempotentForSameTimestamp() async {
        let tab = TabRuntime()
        tab.terminal.terminalDidRequestDesktopNotification(
            title: "", body: "hello"
        )
        await awaitTerminalStatePublish { tab.terminal.lastDesktopNotificationAt != nil }
        let first = tab.recordDesktopNotificationIfNeeded()
        let second = tab.recordDesktopNotificationIfNeeded()
        #expect(first == true)
        #expect(second == false)
        #expect(tab.bellCount == 1)
    }

    @Test func markBellsSeenClearsUnseenOnly() {
        let tab = TabRuntime(
            bellCount: 3,
            unseenBellCount: 3,
            lastBellAt: Date()
        )
        #expect(tab.bellCount == 3)
        #expect(tab.unseenBellCount == 3)
        tab.markBellsSeen()
        #expect(tab.bellCount == 3)
        #expect(tab.unseenBellCount == 0)
    }
}
