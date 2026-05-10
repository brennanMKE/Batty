// TabRuntimeBellTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct TabRuntimeBellTests {

    @Test func recordBellTickReturnsDeltaAndUpdatesMirror() {
        let tab = TabRuntime()
        tab.terminal.terminalDidRingBell()
        let delta = tab.recordBellTickIfNeeded()
        #expect(delta == 1)
        #expect(tab.bellCount == 1)
        #expect(tab.lastBellAt != nil)
        #expect(tab.lastBellMessage == nil)
    }

    @Test func recordBellTickIsIdempotentBetweenTicks() {
        let tab = TabRuntime()
        tab.terminal.terminalDidRingBell()
        _ = tab.recordBellTickIfNeeded()
        let secondDelta = tab.recordBellTickIfNeeded()
        #expect(secondDelta == 0)
        #expect(tab.bellCount == 1)
    }

    @Test func recordBellTickHandlesBurstDelta() {
        let tab = TabRuntime()
        for _ in 0..<5 { tab.terminal.terminalDidRingBell() }
        let delta = tab.recordBellTickIfNeeded()
        #expect(delta == 5)
        #expect(tab.bellCount == 5)
    }

    @Test func recordDesktopNotificationFormatsTitleAndBody() {
        let tab = TabRuntime()
        tab.terminal.terminalDidRequestDesktopNotification(
            title: "Build", body: "Succeeded"
        )
        let recorded = tab.recordDesktopNotificationIfNeeded()
        #expect(recorded == true)
        #expect(tab.lastBellMessage == "Build: Succeeded")
        #expect(tab.bellCount == 1)
    }

    @Test func recordDesktopNotificationFallsBackWhenTitleMissing() {
        let tab = TabRuntime()
        tab.terminal.terminalDidRequestDesktopNotification(
            title: "", body: "hello"
        )
        _ = tab.recordDesktopNotificationIfNeeded()
        #expect(tab.lastBellMessage == "hello")
    }

    @Test func recordDesktopNotificationIsIdempotentForSameTimestamp() {
        let tab = TabRuntime()
        tab.terminal.terminalDidRequestDesktopNotification(
            title: "", body: "hello"
        )
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
