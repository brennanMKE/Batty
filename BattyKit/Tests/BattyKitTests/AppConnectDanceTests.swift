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
            pollMaxAttempts: 2,
            pollInterval: 0,
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
            pollMaxAttempts: 5,
            pollInterval: 0,
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
}
