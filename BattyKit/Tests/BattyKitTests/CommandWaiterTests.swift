// CommandWaiterTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct CommandWaiterTests {
    private let timeout: Duration = .seconds(600)

    private func start(_ tab: FakeCommandWaitTab, clock: TestClock) async -> Task<CommandWaitOutcome, Never> {
        let task = Task { @MainActor in
            await CommandWaiter.run("make test", on: tab, timeout: timeout, clock: clock)
        }
        await tab.waitUntilArmed()
        return task
    }

    @Test func exitCodeComesFromTheFirstFinishAfterTyping() async {
        let tab = FakeCommandWaitTab()
        let task = await start(tab, clock: TestClock())
        #expect(tab.armed == "make test")
        tab.fireWillType()
        tab.fireFinished(3, 1_500_000_000)
        #expect(await task.value == .exited(exitCode: 3, durationNanos: 1_500_000_000))
    }

    @Test func finishBeforeTypingIsIgnored() async {
        let tab = FakeCommandWaitTab()
        let task = await start(tab, clock: TestClock())
        tab.fireFinished(9, 1)
        tab.fireWillType()
        tab.fireFinished(0, 2)
        #expect(await task.value == .exited(exitCode: 0, durationNanos: 2))
    }

    @Test func laterFinishesAreIgnored() async {
        let tab = FakeCommandWaitTab()
        let task = await start(tab, clock: TestClock())
        tab.fireWillType()
        tab.fireFinished(1, 5)
        tab.fireFinished(2, 6)
        #expect(await task.value == .exited(exitCode: 1, durationNanos: 5))
    }

    @Test func timeoutAfterTypingReportsTimedOut() async {
        let tab = FakeCommandWaitTab()
        let clock = TestClock()
        let task = await start(tab, clock: clock)
        tab.fireWillType()
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: timeout)
        #expect(await task.value == .timedOut)
    }

    @Test func timeoutBeforeTypingReportsShellNotReady() async {
        let tab = FakeCommandWaitTab()
        let clock = TestClock()
        let task = await start(tab, clock: clock)
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: timeout)
        #expect(await task.value == .shellNotReady)
    }

    @Test func closingTheTabEndsTheWait() async {
        let tab = FakeCommandWaitTab()
        let task = await start(tab, clock: TestClock())
        tab.fireWillType()
        tab.fireClosed()
        #expect(await task.value == .tabClosed)
    }

    @Test func abandonedDeliveryReportsNotStarted() async {
        let tab = FakeCommandWaitTab()
        let task = await start(tab, clock: TestClock())
        tab.fireAbandoned()
        #expect(await task.value == .notStarted)
    }

    @Test func refusedInputReportsNotStarted() async {
        let tab = FakeCommandWaitTab()
        let task = await start(tab, clock: TestClock())
        tab.fireWillType()
        tab.fireRefused()
        #expect(await task.value == .notStarted)
    }

    @Test func cancellationEndsTheWaitAndLeavesTheTabAlone() async {
        let tab = FakeCommandWaitTab()
        let clock = TestClock()
        let task = await start(tab, clock: clock)
        tab.fireWillType()
        #expect(await clock.waitForSleepers(1))
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(tab.armCount == 1)
        #expect(tab.finishedObserverCount == 0)
        #expect(tab.closedObserverCount == 0)
        #expect(await clock.advance(by: timeout) == 0)
    }

    @Test func observersAreRemovedAfterEveryOutcome() async {
        let drivers: [(FakeCommandWaitTab) -> Void] = [
            { $0.fireWillType(); $0.fireFinished(0, 0) },
            { $0.fireClosed() },
            { $0.fireAbandoned() },
            { $0.fireWillType(); $0.fireRefused() },
        ]
        for drive in drivers {
            let tab = FakeCommandWaitTab()
            let task = await start(tab, clock: TestClock())
            #expect(tab.finishedObserverCount == 1)
            #expect(tab.closedObserverCount == 1)
            drive(tab)
            _ = await task.value
            #expect(tab.finishedObserverCount == 0)
            #expect(tab.closedObserverCount == 0)
        }
    }
}
