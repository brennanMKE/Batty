// NoEndpointRegisteredDecisionTests.swift

import Testing
@testable import BattyKit

/// Covers the CLI connect-dance branch #0361 fixes: what
/// `AppConnectDance.resolveEndpoint` should do when the broker is reachable
/// but has no registered app endpoint. No `NSRunningApplication` or XPC
/// involved — the whole point of `NoEndpointRegisteredDecision` is that this
/// decision doesn't need either.
struct NoEndpointRegisteredDecisionTests {

    @Test func noRunningAppLaunchesAndPolls() {
        // "App not running": the regression-free case, unchanged from
        // before #0361 — nothing is running, so launching is safe.
        #expect(NoEndpointRegisteredDecision.action(isAppRunning: false) == .launchAndPoll)
    }

    @Test func runningButUnregisteredWaitsInsteadOfLaunching() {
        // "App running but unregistered": the #0361 regression this type
        // exists to prevent. Launching here would spawn a duplicate process
        // alongside the one already running — the one thing the fix must
        // never do.
        #expect(NoEndpointRegisteredDecision.action(isAppRunning: true) == .waitForReregistration)
    }

    @Test func theTwoStatesMapToDistinctActions() {
        // Asserting distinctness directly, not just each mapping
        // individually, catches a future edit that collapses both cases to
        // the same action — which would silently reintroduce #0361.
        #expect(NoEndpointRegisteredDecision.action(isAppRunning: true) != NoEndpointRegisteredDecision.action(isAppRunning: false))
    }
}
