// TabRuntimeCommandFinishedObserverTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct TabRuntimeCommandFinishedObserverTests {
    @Test func observersReceiveTheExitCode() {
        let tab = TabRuntime()
        var first: [Int?] = []
        var second: [Int?] = []
        tab.addCommandFinishedObserver { first.append($0) }
        tab.addCommandFinishedObserver { second.append($0) }
        tab.terminalDelegate.onCommandFinished?(3, 0)
        tab.terminalDelegate.onCommandFinished?(nil, 0)
        #expect(first == [3, nil])
        #expect(second == [3, nil])
    }

    @Test func eventObserverReceivesExitCodeAndDuration() {
        let tab = TabRuntime()
        var events: [(Int?, UInt64)] = []
        tab.addCommandFinishedEventObserver { events.append(($0, $1)) }
        tab.terminalDelegate.onCommandFinished?(2, 1_500_000_000)
        #expect(events.count == 1)
        #expect(events.first?.0 == 2)
        #expect(events.first?.1 == 1_500_000_000)
    }

    @Test func removedObserverIsNotCalled() {
        let tab = TabRuntime()
        var calls = 0
        let id = tab.addCommandFinishedObserver { _ in calls += 1 }
        tab.removeCommandFinishedObserver(id)
        tab.terminalDelegate.onCommandFinished?(0, 0)
        #expect(calls == 0)
    }

    @Test func runningCommandDisplayNameStillClears() {
        let tab = TabRuntime()
        tab.runningCommandDisplayName = "go"
        tab.addCommandFinishedObserver { _ in }
        tab.terminalDelegate.onCommandFinished?(0, 0)
        #expect(tab.runningCommandDisplayName == nil)
    }
}
