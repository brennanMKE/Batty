// AppConnectDanceTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import batty

/// Covers `AppConnectDance.resolveEndpoint`'s wiring (#0365). It has four
/// collaborators — `BrokerAppEndpointClient.fetchEndpoint`,
/// `AppBundleLocator.resolve`, `AppLauncher.launch`,
/// `RunningAppChecker.isRunning` — but #0361 left only three of them
/// injectable (`resolveAppBundle`/`launch`/`isAppRunning`; `launch` itself
/// has been a seam since #0271, `AppConnectDance`'s original issue). The
/// broker fetch was never one, so no test could reach the branches those
/// three seams exist to pin without a live `BattyBroker` Mach service.
/// `fetchEndpoint` and `sleep` (the latter threading through to
/// `BoundedPoll.poll`, which was already injectable) close that gap: every
/// test below runs with no XPC connection attempted and no real sleeping.
///
/// The property that mattered most in the original #0361 regression —
/// `resolveEndpoint` must never call `launch` while a process at the
/// resolved bundle path is running — is asserted directly in
/// `appRunningAndUnregisteredNeverLaunches`.
struct AppConnectDanceTests {

    private let fakeBundleURL = URL(fileURLWithPath: "/Applications/Batty.app", isDirectory: true)

    private static func fakeEndpoint() -> NSXPCListenerEndpoint {
        NSXPCListener.anonymous().endpoint
    }

    private func neverSleeps(_ interval: TimeInterval) {}

    private func expectSuccess(
        _ result: Swift.Result<NSXPCListenerEndpoint, AppConnectDance.Failure>,
        isIdenticalTo expected: NSXPCListenerEndpoint,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch result {
        case .success(let endpoint):
            #expect(endpoint === expected, "expected the exact endpoint the fake broker returned", sourceLocation: sourceLocation)
        case .failure(let failure):
            Issue.record("expected .success, got .failure(\(failure))", sourceLocation: sourceLocation)
        }
    }

    private func expectFailure(
        _ result: Swift.Result<NSXPCListenerEndpoint, AppConnectDance.Failure>,
        _ expected: AppConnectDance.Failure,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch result {
        case .failure(let failure):
            #expect(failure == expected, sourceLocation: sourceLocation)
        case .success:
            Issue.record("expected .failure(\(expected)), got .success", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Broker unreachable

    @Test func brokerUnreachableFailsImmediatelyWithoutResolvingABundle() {
        var resolveAppBundleCalls = 0
        var isAppRunningCalls = 0
        var launchCalls = 0

        let result = AppConnectDance.resolveEndpoint(
            fetchEndpoint: { _ in .unreachable },
            resolveAppBundle: {
                resolveAppBundleCalls += 1
                return .success(fakeBundleURL)
            },
            launch: { _ in
                launchCalls += 1
                return true
            },
            isAppRunning: { _ in
                isAppRunningCalls += 1
                return false
            },
            sleep: neverSleeps
        )

        expectFailure(result, .brokerUnreachable)
        #expect(resolveAppBundleCalls == 0)
        #expect(isAppRunningCalls == 0)
        #expect(launchCalls == 0)
    }

    // MARK: - Endpoint already registered

    @Test func registeredEndpointIsUsedDirectlyWithoutLaunching() {
        var launchCalls = 0
        let endpoint = Self.fakeEndpoint()

        let result = AppConnectDance.resolveEndpoint(
            fetchEndpoint: { _ in .endpoint(endpoint) },
            launch: { _ in
                launchCalls += 1
                return true
            },
            sleep: neverSleeps
        )

        expectSuccess(result, isIdenticalTo: endpoint)
        #expect(launchCalls == 0)
    }

    // MARK: - App running, no endpoint registered

    /// The exact property #0361 fixes: a process at the resolved bundle
    /// path is already running, so launching would spawn a duplicate.
    @Test func appRunningAndUnregisteredNeverLaunches() {
        var launchCalls = 0

        let result = AppConnectDance.resolveEndpoint(
            reregistrationPollMaxAttempts: 2,
            reregistrationPollInterval: 0,
            fetchEndpoint: { _ in .endpoint(nil) },
            resolveAppBundle: { .success(fakeBundleURL) },
            launch: { _ in
                launchCalls += 1
                return true
            },
            isAppRunning: { _ in true },
            sleep: neverSleeps
        )

        #expect(launchCalls == 0)
        expectFailure(result, .appRunningUnregistered)
    }

    @Test func appRunningAndUnregisteredSucceedsIfItReregistersMidPoll() {
        var launchCalls = 0
        var fetchCallCount = 0
        let endpoint = Self.fakeEndpoint()

        let result = AppConnectDance.resolveEndpoint(
            reregistrationPollMaxAttempts: 5,
            reregistrationPollInterval: 0,
            fetchEndpoint: { _ in
                fetchCallCount += 1
                // First call is the initial "is anything registered" check
                // (.endpoint(nil)); the second is the first poll attempt,
                // which now finds the app re-registered.
                return fetchCallCount <= 1 ? .endpoint(nil) : .endpoint(endpoint)
            },
            resolveAppBundle: { .success(fakeBundleURL) },
            launch: { _ in
                launchCalls += 1
                return true
            },
            isAppRunning: { _ in true },
            sleep: neverSleeps
        )

        #expect(launchCalls == 0)
        expectSuccess(result, isIdenticalTo: endpoint)
    }

    // MARK: - App not running, no endpoint registered

    @Test func appNotRunningLaunchesExactlyOnceWithTheResolvedBundleURL() {
        var launchedURLs: [URL] = []
        let endpoint = Self.fakeEndpoint()
        var fetchCallCount = 0

        let result = AppConnectDance.resolveEndpoint(
            pollMaxAttempts: 5,
            pollInterval: 0,
            fetchEndpoint: { _ in
                fetchCallCount += 1
                return fetchCallCount <= 1 ? .endpoint(nil) : .endpoint(endpoint)
            },
            resolveAppBundle: { .success(fakeBundleURL) },
            launch: { url in
                launchedURLs.append(url)
                return true
            },
            isAppRunning: { _ in false },
            sleep: neverSleeps
        )

        #expect(launchedURLs == [fakeBundleURL])
        expectSuccess(result, isIdenticalTo: endpoint)
    }

    @Test func appNotRunningAndPollNeverRegistersFailsWithAppUnavailable() {
        let result = AppConnectDance.resolveEndpoint(
            pollMaxAttempts: 3,
            pollInterval: 0,
            fetchEndpoint: { _ in .endpoint(nil) },
            resolveAppBundle: { .success(fakeBundleURL) },
            launch: { _ in true },
            isAppRunning: { _ in false },
            sleep: neverSleeps
        )

        expectFailure(result, .appUnavailable)
    }

    // MARK: - App bundle resolution failure

    @Test func bundleResolutionFailureSkipsRunningCheckAndLaunch() {
        var isAppRunningCalls = 0
        var launchCalls = 0
        let failure = AppBundleLocator.Failure.expectedBundleMissing(expectedPath: "/Applications/Batty.app", otherClaimants: [])

        let result = AppConnectDance.resolveEndpoint(
            fetchEndpoint: { _ in .endpoint(nil) },
            resolveAppBundle: { .failure(failure) },
            launch: { _ in
                launchCalls += 1
                return true
            },
            isAppRunning: { _ in
                isAppRunningCalls += 1
                return false
            },
            sleep: neverSleeps
        )

        #expect(isAppRunningCalls == 0)
        #expect(launchCalls == 0)
        expectFailure(result, .appBundleUnresolved(failure.diagnosticMessage))
    }

    // MARK: - Launch failure short-circuits the poll bound

    /// The comment on the `guard launch(bundleURL) else` branch claims a
    /// failed launch short-circuits rather than burning the full poll
    /// bound. Pinned here by asserting `fetchEndpoint` is never called a
    /// second time (the poll never starts) when `launch` returns `false`.
    @Test func failedLaunchShortCircuitsWithoutPolling() {
        var fetchCallCount = 0

        let result = AppConnectDance.resolveEndpoint(
            pollMaxAttempts: 20,
            pollInterval: 0,
            fetchEndpoint: { _ in
                fetchCallCount += 1
                return .endpoint(nil)
            },
            resolveAppBundle: { .success(fakeBundleURL) },
            launch: { _ in false },
            isAppRunning: { _ in false },
            sleep: neverSleeps
        )

        #expect(fetchCallCount == 1)
        expectFailure(result, .appUnavailable)
    }

    // MARK: - Worst-case simulated elapsed time (#0369)

    /// Pins `.launchAndPoll`'s worst case against a broker that accepts
    /// connections but never replies: the sum of every `pollTimeout`
    /// handed to `fetchEndpoint` during the poll loop, plus every `sleep`
    /// interval, matches the ~24.8 s the doc comment on `resolveEndpoint`
    /// derives from its defaults (`pollMaxAttempts: 20, pollTimeout: 1.0,
    /// pollInterval: 0.25`). No real time passes — `fetchEndpoint` and
    /// `sleep` are faked — so this is the time a live run would take if
    /// every attempt actually consumed its full timeout.
    @Test func launchAndPollWorstCaseSimulatedElapsedTimeMatchesDocumentedBound() {
        var timeoutsSeen: [TimeInterval] = []
        var sleepsSeen: [TimeInterval] = []

        let result = AppConnectDance.resolveEndpoint(
            fetchEndpoint: { timeout in
                timeoutsSeen.append(timeout)
                return .endpoint(nil)
            },
            resolveAppBundle: { .success(fakeBundleURL) },
            launch: { _ in true },
            isAppRunning: { _ in false },
            sleep: { sleepsSeen.append($0) }
        )

        expectFailure(result, .appUnavailable)

        // The first fetch is the initial "is anything registered" check
        // (brokerTimeout, default 3.0); the rest are the 20 poll attempts
        // (pollTimeout, default 1.0 each).
        #expect(timeoutsSeen.count == 21)
        #expect(timeoutsSeen.first == 3.0)
        let pollTimeouts = Array(timeoutsSeen.dropFirst())
        #expect(pollTimeouts == Array(repeating: 1.0, count: 20))
        #expect(sleepsSeen == Array(repeating: 0.25, count: 19))

        let simulatedPollElapsed = pollTimeouts.reduce(0, +) + sleepsSeen.reduce(0, +)
        #expect(abs(simulatedPollElapsed - 24.75) < 0.0001)
    }

    /// Pins `.waitForReregistration`'s worst case at a shorter bound than
    /// `.launchAndPoll`'s: with the `reregistrationPoll*` defaults
    /// (`reregistrationPollMaxAttempts: 13, reregistrationPollTimeout: 0.5,
    /// reregistrationPollInterval: 0.5`), the simulated elapsed time is
    /// ~12.5 s — roughly half of `.launchAndPoll`'s ~24.8 s, not the few
    /// seconds the common (healthy-broker) case reaches in practice. A
    /// regression back to sharing `pollMaxAttempts`/`pollTimeout`/`pollInterval`
    /// between both arms would push this to 24.75 and fail the assertion.
    @Test func waitForReregistrationWorstCaseSimulatedElapsedTimeIsMuchShorterThanLaunchAndPoll() {
        var timeoutsSeen: [TimeInterval] = []
        var sleepsSeen: [TimeInterval] = []
        var launchCalls = 0

        let result = AppConnectDance.resolveEndpoint(
            fetchEndpoint: { timeout in
                timeoutsSeen.append(timeout)
                return .endpoint(nil)
            },
            resolveAppBundle: { .success(fakeBundleURL) },
            launch: { _ in
                launchCalls += 1
                return true
            },
            isAppRunning: { _ in true },
            sleep: { sleepsSeen.append($0) }
        )

        expectFailure(result, .appRunningUnregistered)
        #expect(launchCalls == 0)

        // The first fetch is the initial "is anything registered" check
        // (brokerTimeout, default 3.0); the rest are the 13 reregistration
        // poll attempts (reregistrationPollTimeout, default 0.5 each).
        #expect(timeoutsSeen.count == 14)
        #expect(timeoutsSeen.first == 3.0)
        let pollTimeouts = Array(timeoutsSeen.dropFirst())
        #expect(pollTimeouts == Array(repeating: 0.5, count: 13))
        #expect(sleepsSeen == Array(repeating: 0.5, count: 12))

        let simulatedPollElapsed = pollTimeouts.reduce(0, +) + sleepsSeen.reduce(0, +)
        #expect(abs(simulatedPollElapsed - 12.5) < 0.0001)
        #expect(simulatedPollElapsed < 24.75, "expected shorter than .launchAndPoll's ~24.8 s bound")
    }

    /// Pins the behavioral claim `reregistrationPoll*`'s defaults rest on:
    /// an app that re-registers shortly after `AppXPCCoordinator`'s first
    /// `BrokerReconnectBackoff` retry (5 s after `BrokerReconnectBudget`'s
    /// immediate-retry burst is exhausted) is caught as a success, not
    /// exhausted into exit `6`. Simulates registration landing on the 12th
    /// poll attempt, whose preceding sleeps sum to 11 * 0.5 = 5.5 s — past
    /// the 5 s mark — and asserts `resolveEndpoint` returns the endpoint
    /// rather than exhausting the bound.
    @Test func waitForReregistrationSucceedsIfTheAppReregistersDuringTheFirstBackoffRetryWindow() {
        var fetchCallCount = 0
        let endpoint = Self.fakeEndpoint()

        let result = AppConnectDance.resolveEndpoint(
            fetchEndpoint: { _ in
                fetchCallCount += 1
                // Call 1 is the initial check; calls 2-12 are poll attempts
                // 1-11 (still unregistered); call 13 is poll attempt 12,
                // landing at 5.5 s of simulated sleeps — just past the 5 s
                // first backoff retry — where the app has re-registered.
                return fetchCallCount < 13 ? .endpoint(nil) : .endpoint(endpoint)
            },
            resolveAppBundle: { .success(fakeBundleURL) },
            launch: { _ in true },
            isAppRunning: { _ in true },
            sleep: { _ in }
        )

        expectSuccess(result, isIdenticalTo: endpoint)
        #expect(fetchCallCount == 13)
    }
}
