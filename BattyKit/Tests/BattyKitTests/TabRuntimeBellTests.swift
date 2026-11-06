// TabRuntimeBellTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct TabRuntimeBellTests {

    @Test func ringingThroughTheDelegateCountsWithoutAStore() {
        let tab = TabRuntime(lastBellMessage: "stale")
        tab.terminalDelegate.terminalDidRingBell()
        #expect(tab.bellCount == 1)
        #expect(tab.lastBellAt != nil)
        #expect(tab.lastBellMessage == nil)
    }

    @Test func receiveRingBellStampsTheGivenInstant() {
        let tab = TabRuntime()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        tab.receiveRingBell(at: at)
        #expect(tab.lastBellAt == at)
    }

    @Test func eachRingCountsOnce() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidRingBell()
        tab.terminalDelegate.terminalDidRingBell()
        #expect(tab.bellCount == 2)
    }

    @Test func pendingBellsCoalesceUntilAnIntakeIsSet() {
        let tab = TabRuntime()
        let last = Date(timeIntervalSince1970: 1_700_000_500)
        for i in 0..<4 { tab.receiveRingBell(at: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))) }
        tab.receiveRingBell(at: last)
        var events: [BellIntakeEvent] = []
        tab.setBellIntake { _, event in events.append(event) }
        #expect(events == [.bel(count: 5, at: last)])
        #expect(tab.bellCount == 5)

        tab.setBellIntake { _, event in events.append(event) }
        #expect(events.count == 1, "a flushed buffer must not be delivered again")
    }

    @Test func pendingNotificationKeepsOnlyTheLatest() {
        let tab = TabRuntime()
        let second = Date(timeIntervalSince1970: 1_700_000_100)
        tab.receiveDesktopNotification(title: "first", body: "one", at: Date(timeIntervalSince1970: 1_700_000_000))
        tab.receiveDesktopNotification(title: "second", body: "two", at: second)
        var events: [BellIntakeEvent] = []
        tab.setBellIntake { _, event in events.append(event) }
        #expect(events == [.desktopNotification(message: "second: two", at: second)])
        #expect(tab.bellCount == 2)

        tab.setBellIntake { _, event in events.append(event) }
        #expect(events.count == 1, "a flushed notification must not be delivered again")
    }

    @Test func desktopNotificationFormatsTitleAndBody() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidRequestDesktopNotification(title: "Build", body: "Succeeded")
        #expect(tab.lastBellMessage == "Build: Succeeded")
        #expect(tab.bellCount == 1)
    }

    @Test func desktopNotificationFallsBackWhenTitleMissing() {
        let tab = TabRuntime()
        tab.terminalDelegate.terminalDidRequestDesktopNotification(title: "", body: "hello")
        #expect(tab.lastBellMessage == "hello")
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
