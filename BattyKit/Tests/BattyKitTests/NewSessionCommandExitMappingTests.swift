// NewSessionCommandExitMappingTests.swift

import ArgumentParser
import BattyXPCCore
import Foundation
import Testing
@testable import batty

/// Covers two things #0415 made testable without calling `run()`:
///
/// 1. `NewSessionCommand.notFoundExitCode` — the exit `2` vs exit `3` choice
///    on a `!endpointEverSeen` timeout (#0380 round 3 review, N8), previously
///    only reachable by driving `run()` end to end against a real broker.
/// 2. `--no-wait` parsing, including its `--json` conflict (#0380 round 3
///    review, N7) — `NewSessionCommand.run()` itself is not made
///    unit-testable end to end here (its `--no-wait` path calls `openURL`,
///    which spawns a real, unseamed `/usr/bin/open` process — #0414), so
///    these tests stop at the parsed command, never at `run()`.
struct NewSessionCommandExitMappingTests {

    // MARK: - notFoundExitCode

    /// Pins the real `XPCExitCode` values this mapping depends on, so a
    /// future renumbering fails here rather than silently changing which
    /// exit code agents see.
    @Test func exitCodesUnderTestHaveTheExpectedValues() {
        #expect(XPCExitCode.brokerUnreachable == 2)
        #expect(XPCExitCode.appUnavailable == 3)
    }

    @Test func lastFetchWasBrokerUnreachableMapsToBrokerUnreachable() {
        #expect(NewSessionCommand.notFoundExitCode(lastFetchWasBrokerUnreachable: true) == XPCExitCode.brokerUnreachable)
    }

    @Test func lastFetchWasNotBrokerUnreachableMapsToAppUnavailable() {
        #expect(NewSessionCommand.notFoundExitCode(lastFetchWasBrokerUnreachable: false) == XPCExitCode.appUnavailable)
    }

    /// End-to-end through the same collaborators `run()`'s `.notRunningYet`
    /// arm wires together — `ColdLaunchEndpointResolver` feeding
    /// `pollForNewSession` feeding `notFoundExitCode` — with a persistently
    /// unreachable broker. Exercises the wiring, not just the pure mapping
    /// function in isolation.
    @Test func persistentlyUnreachableBrokerTimesOutToExitCodeTwo() {
        let resolver = NewSessionCommand.ColdLaunchEndpointResolver(timeout: 1.0, fetchEndpoint: { _ in .unreachable })

        let outcome = NewSessionCommand.pollForNewSession(
            path: "/tmp/NewSessionCommandExitMappingTests",
            snapshot: TopologyPayload(pid: 0, windows: []),
            maxAttempts: 3,
            interval: 0,
            resolveEndpoint: resolver.resolve
        )

        guard case .timedOut(let endpointEverSeen, _) = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            return
        }
        #expect(endpointEverSeen == false)
        #expect(NewSessionCommand.notFoundExitCode(lastFetchWasBrokerUnreachable: resolver.lastFetchWasBrokerUnreachable) == XPCExitCode.brokerUnreachable)
    }

    /// Same wiring, but the broker answers "no endpoint" on every attempt
    /// instead of never answering at all — must map to exit `3`, not `2`.
    @Test func persistentNoEndpointRegisteredTimesOutToExitCodeThree() {
        let resolver = NewSessionCommand.ColdLaunchEndpointResolver(timeout: 1.0, fetchEndpoint: { _ in .endpoint(nil) })

        let outcome = NewSessionCommand.pollForNewSession(
            path: "/tmp/NewSessionCommandExitMappingTests",
            snapshot: TopologyPayload(pid: 0, windows: []),
            maxAttempts: 3,
            interval: 0,
            resolveEndpoint: resolver.resolve
        )

        guard case .timedOut(let endpointEverSeen, _) = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            return
        }
        #expect(endpointEverSeen == false)
        #expect(NewSessionCommand.notFoundExitCode(lastFetchWasBrokerUnreachable: resolver.lastFetchWasBrokerUnreachable) == XPCExitCode.appUnavailable)
    }

    // MARK: - --no-wait

    @Test func noWaitFlagParsesIndependentlyOfJSON() throws {
        let command = try NewSessionCommand.parse(["--no-wait"])
        #expect(command.noWait == true)
        #expect(command.json == false)
    }

    /// #0380 round 3 review (N7): `--json` has no effect with `--no-wait`,
    /// since `run()`'s `noWait` branch returns before `json` is ever
    /// consulted — rejected up front by `validate()` rather than silently
    /// printing nothing. `ParsableArguments.parse(_:)` calls `validate()`
    /// internally, so parsing both flags together is enough to observe this
    /// without calling `run()`.
    @Test func jsonAndNoWaitTogetherFailValidation() {
        #expect(throws: (any Error).self) {
            _ = try NewSessionCommand.parse(["--json", "--no-wait"])
        }
    }
}
