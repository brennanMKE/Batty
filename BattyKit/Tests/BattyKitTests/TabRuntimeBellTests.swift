// TabRuntimeBellTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct TabRuntimeBellTests {

    @Test func recordBellTickCarriesDeltaIntoCounters() {
        let tab = TabRuntime()
        tab.terminal.terminalDidRingBell()
        tab.recordBellTickIfNeeded()
        #expect(tab.bellCount == 1)
        #expect(tab.unseenBellCount == 1)
        #expect(tab.lastBellAt != nil)
        #expect(tab.lastBellMessage == nil)
    }

    @Test func recordBellTickIsIdempotentBetweenTicks() {
        let tab = TabRuntime()
        tab.terminal.terminalDidRingBell()
        tab.recordBellTickIfNeeded()
        tab.recordBellTickIfNeeded()
        #expect(tab.bellCount == 1)
        #expect(tab.unseenBellCount == 1)
    }

    @Test func recordBellTickHandlesBurstDelta() {
        let tab = TabRuntime()
        for _ in 0..<5 { tab.terminal.terminalDidRingBell() }
        tab.recordBellTickIfNeeded()
        #expect(tab.bellCount == 5)
        #expect(tab.unseenBellCount == 5)
    }

    @Test func recordDesktopNotificationFormatsTitleAndBody() {
        let tab = TabRuntime()
        tab.terminal.terminalDidRequestDesktopNotification(
            title: "Build", body: "Succeeded"
        )
        tab.recordDesktopNotificationIfNeeded()
        #expect(tab.lastBellMessage == "Build: Succeeded")
        #expect(tab.bellCount == 1)
        #expect(tab.unseenBellCount == 1)
    }

    @Test func recordDesktopNotificationFallsBackWhenTitleMissing() {
        let tab = TabRuntime()
        tab.terminal.terminalDidRequestDesktopNotification(
            title: "", body: "hello"
        )
        tab.recordDesktopNotificationIfNeeded()
        #expect(tab.lastBellMessage == "hello")
    }

    @Test func recordDesktopNotificationIsIdempotentForSameTimestamp() {
        let tab = TabRuntime()
        tab.terminal.terminalDidRequestDesktopNotification(
            title: "", body: "hello"
        )
        tab.recordDesktopNotificationIfNeeded()
        tab.recordDesktopNotificationIfNeeded()
        #expect(tab.bellCount == 1)
    }

    @Test func markBellsSeenClearsUnseenOnly() {
        let tab = TabRuntime()
        for _ in 0..<3 { tab.terminal.terminalDidRingBell() }
        tab.recordBellTickIfNeeded()
        #expect(tab.bellCount == 3)
        #expect(tab.unseenBellCount == 3)
        tab.markBellsSeen()
        #expect(tab.bellCount == 3)
        #expect(tab.unseenBellCount == 0)
    }
}
