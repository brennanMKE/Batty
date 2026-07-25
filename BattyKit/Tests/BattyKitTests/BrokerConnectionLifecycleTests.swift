// BrokerConnectionLifecycleTests.swift

import Testing
@testable import BattyKit

/// Covers the pure interruption-vs-invalidation dispatch (#0272 item 1) —
/// no `NSXPCConnection` involved, since the whole point of
/// `BrokerConnectionLifecycle` is that this decision doesn't need one.
struct BrokerConnectionLifecycleTests {

    @Test func interruptionMapsToRetryOverExistingConnection() {
        #expect(BrokerConnectionLifecycle.response(for: .interruption) == .retryOverExistingConnection)
    }

    @Test func invalidationMapsToRebuildConnection() {
        #expect(BrokerConnectionLifecycle.response(for: .invalidation) == .rebuildConnection)
    }

    @Test func theTwoSignalsMapToDistinctResponses() {
        // The regression this whole child exists to prevent: conflating the
        // two into one action. Asserting distinctness directly, not just
        // each mapping individually, catches a future edit that collapses
        // both cases in the switch to the same response.
        #expect(BrokerConnectionLifecycle.response(for: .interruption) != BrokerConnectionLifecycle.response(for: .invalidation))
    }
}
