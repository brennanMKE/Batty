// FakeCommandWaitTab.swift

import Foundation
@testable import BattyKit

@MainActor
final class FakeCommandWaitTab: CommandWaitTab {
    private(set) var armed: String?
    private(set) var armCount = 0
    private var events: ((StartupCommandDeliveryEvent) -> Void)?
    private var finishedObservers: [UUID: (Int?, UInt64) -> Void] = [:]
    private var closedObservers: [UUID: () -> Void] = [:]
    private var armedWaiters: [CheckedContinuation<Void, Never>] = []

    var finishedObserverCount: Int { finishedObservers.count }
    var closedObserverCount: Int { closedObservers.count }

    func armCommand(_ line: String, events: @escaping (StartupCommandDeliveryEvent) -> Void) {
        armed = line
        armCount += 1
        self.events = events
        let waiters = armedWaiters
        armedWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Returns once ``armCommand(_:events:)`` has run.
    func waitUntilArmed() async {
        if armed != nil { return }
        await withCheckedContinuation { armedWaiters.append($0) }
    }

    func addCommandFinishedEventObserver(_ observer: @escaping (Int?, UInt64) -> Void) -> UUID {
        let id = UUID()
        finishedObservers[id] = observer
        return id
    }

    func removeCommandFinishedObserver(_ id: UUID) {
        finishedObservers.removeValue(forKey: id)
    }

    func addClosedObserver(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        closedObservers[id] = handler
        return id
    }

    func removeClosedObserver(_ id: UUID) {
        closedObservers.removeValue(forKey: id)
    }

    func fireWillType() { events?(.willType) }
    func fireRefused() { events?(.refused) }
    func fireAbandoned() { events?(.abandoned) }

    func fireFinished(_ exitCode: Int?, _ durationNanos: UInt64) {
        for observer in Array(finishedObservers.values) { observer(exitCode, durationNanos) }
    }

    func fireClosed() {
        for handler in Array(closedObservers.values) { handler() }
    }
}
