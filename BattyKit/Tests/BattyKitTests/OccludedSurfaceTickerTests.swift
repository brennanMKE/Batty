// OccludedSurfaceTickerTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Coverage for ``OccludedSurfaceTicker`` in isolation — the mechanics of
/// tracking a target set and firing ``onTick`` for it, independent of
/// `TerminalHostStore` and of any real libghostty surface. `start()`/`stop()`
/// are never exercised here (mirrors `FootprintMonitor`'s test suite):
/// production wires the real interval-driven loop; tests drive
/// ``OccludedSurfaceTicker/tickOnce()`` directly.
@MainActor
struct OccludedSurfaceTickerTests {

    @Test func newTickerHasNoTargets() {
        let ticker = OccludedSurfaceTicker()
        #expect(ticker.targets.isEmpty)
    }

    @Test func setTargetsUpdatesTheTrackedSet() {
        let ticker = OccludedSurfaceTicker()
        let a = UUID()
        let b = UUID()

        ticker.setTargets([a, b])

        #expect(ticker.targets == [a, b])
    }

    @Test func setTargetsToEmptyClearsTheTrackedSet() {
        let ticker = OccludedSurfaceTicker()
        ticker.setTargets([UUID()])

        ticker.setTargets([])

        #expect(ticker.targets.isEmpty)
    }

    /// One `tickOnce()` fires `onTick` exactly once per tracked id — not
    /// zero, not twice. This is the "no double-ticking" guarantee at the
    /// ticker level: a `Set` can't hold a duplicate, and a single fire
    /// walks it exactly once.
    @Test func tickOnceFiresOnTickExactlyOncePerTarget() {
        let ticker = OccludedSurfaceTicker()
        let a = UUID()
        let b = UUID()
        ticker.setTargets([a, b])
        var fired: [UUID] = []
        ticker.onTick = { fired.append($0) }

        ticker.tickOnce()

        #expect(fired.sorted { $0.uuidString < $1.uuidString } == [a, b].sorted { $0.uuidString < $1.uuidString })
        #expect(fired.count == 2)
    }

    @Test func tickOnceFiresNothingWhenTargetsIsEmpty() {
        let ticker = OccludedSurfaceTicker()
        var fired = 0
        ticker.onTick = { _ in fired += 1 }

        ticker.tickOnce()

        #expect(fired == 0)
    }

    /// A tab dropped from the set (e.g. it became visible, or its view was
    /// released) stops being ticked on the very next cycle — no stale
    /// membership lingers.
    @Test func tickOnceOnlyFiresForCurrentlyTrackedTargets() {
        let ticker = OccludedSurfaceTicker()
        let a = UUID()
        let b = UUID()
        ticker.setTargets([a, b])
        ticker.setTargets([a]) // b is no longer occluded
        var fired: [UUID] = []
        ticker.onTick = { fired.append($0) }

        ticker.tickOnce()

        #expect(fired == [a])
    }

    /// Repeated ticks re-fire for every still-tracked target — this is the
    /// polling contract, not a one-shot.
    @Test func repeatedTickOnceCallsFireEachTime() {
        let ticker = OccludedSurfaceTicker()
        let a = UUID()
        ticker.setTargets([a])
        var fireCount = 0
        ticker.onTick = { _ in fireCount += 1 }

        ticker.tickOnce()
        ticker.tickOnce()
        ticker.tickOnce()

        #expect(fireCount == 3)
    }
}
