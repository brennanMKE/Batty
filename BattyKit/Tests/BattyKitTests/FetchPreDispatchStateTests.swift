// FetchPreDispatchStateTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import batty

/// Covers `NewSessionCommand.fetchPreDispatchState` (#0415): its
/// `fetchEndpoint` and `fetchTopology` seams, mirroring the style #0365 gave
/// `AppConnectDance.resolveEndpoint`, let every branch run with no live
/// broker or app connection.
struct FetchPreDispatchStateTests {

    private static let fakeBundleURL = URL(fileURLWithPath: "/Applications/Batty.app", isDirectory: true)

    private static func fakeEndpoint() -> NSXPCListenerEndpoint {
        NSXPCListener.anonymous().endpoint
    }

    private static func emptyPayload() -> TopologyPayload {
        TopologyPayload(pid: 1, windows: [])
    }

    private func expect(
        _ state: NewSessionCommand.PreDispatchState,
        isDegraded: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch state {
        case .degraded:
            #expect(isDegraded, "expected non-.degraded, got .degraded", sourceLocation: sourceLocation)
        default:
            #expect(!isDegraded, "expected .degraded, got \(state)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - .unreachable

    @Test func brokerUnreachableIsDegradedWithoutConsultingBundleOrRunningState() {
        var resolveAppBundleCalls = 0
        var isAppRunningCalls = 0
        var fetchTopologyCalls = 0

        let state = NewSessionCommand.fetchPreDispatchState(
            fetchEndpoint: { _ in .unreachable },
            resolveAppBundle: {
                resolveAppBundleCalls += 1
                return .success(Self.fakeBundleURL)
            },
            isAppRunning: { _ in
                isAppRunningCalls += 1
                return false
            },
            fetchTopology: { _ in
                fetchTopologyCalls += 1
                return .success(Self.emptyPayload())
            }
        )

        expect(state, isDegraded: true)
        #expect(resolveAppBundleCalls == 0)
        #expect(isAppRunningCalls == 0)
        #expect(fetchTopologyCalls == 0)
    }

    /// The fetch is called exactly once, with `snapshotTimeout` — pinned by
    /// recording the timeout passed rather than only the call count, so a
    /// stray second call at a different timeout still fails this.
    @Test func fetchIsCalledExactlyOnceWithSnapshotTimeout() {
        var timeoutsSeen: [TimeInterval] = []

        _ = NewSessionCommand.fetchPreDispatchState(
            fetchEndpoint: { timeout in
                timeoutsSeen.append(timeout)
                return .unreachable
            }
        )

        #expect(timeoutsSeen == [3.0])
    }

    // MARK: - .endpoint(.some(...))

    @Test func registeredEndpointWithSuccessfulListReturnsReadyWithThatSnapshot() {
        let endpoint = Self.fakeEndpoint()
        let payload = Self.emptyPayload()

        let state = NewSessionCommand.fetchPreDispatchState(
            fetchEndpoint: { _ in .endpoint(endpoint) },
            fetchTopology: { receivedEndpoint in
                #expect(receivedEndpoint === endpoint)
                return .success(payload)
            }
        )

        guard case .ready(let readyEndpoint, let snapshot) = state else {
            Issue.record("expected .ready, got \(state)")
            return
        }
        #expect(readyEndpoint === endpoint)
        #expect(snapshot.pid == payload.pid)
    }

    @Test func registeredEndpointWithFailedListIsDegraded() {
        let endpoint = Self.fakeEndpoint()

        let state = NewSessionCommand.fetchPreDispatchState(
            fetchEndpoint: { _ in .endpoint(endpoint) },
            fetchTopology: { _ in .unreachable }
        )

        expect(state, isDegraded: true)
    }

    // MARK: - .endpoint(.none)

    @Test func noEndpointWithAppNotRunningIsNotRunningYet() {
        let state = NewSessionCommand.fetchPreDispatchState(
            fetchEndpoint: { _ in .endpoint(nil) },
            resolveAppBundle: { .success(Self.fakeBundleURL) },
            isAppRunning: { _ in false }
        )

        guard case .notRunningYet = state else {
            Issue.record("expected .notRunningYet, got \(state)")
            return
        }
    }

    @Test func noEndpointWithAppRunningIsDegraded() {
        let state = NewSessionCommand.fetchPreDispatchState(
            fetchEndpoint: { _ in .endpoint(nil) },
            resolveAppBundle: { .success(Self.fakeBundleURL) },
            isAppRunning: { _ in true }
        )

        expect(state, isDegraded: true)
    }

    @Test func noEndpointWithBundleResolutionFailureIsDegradedWithoutConsultingRunningState() {
        var isAppRunningCalls = 0
        let failure = AppBundleLocator.Failure.expectedBundleMissing(expectedPath: "/Applications/Batty.app", otherClaimants: [])

        let state = NewSessionCommand.fetchPreDispatchState(
            fetchEndpoint: { _ in .endpoint(nil) },
            resolveAppBundle: { .failure(failure) },
            isAppRunning: { _ in
                isAppRunningCalls += 1
                return false
            }
        )

        expect(state, isDegraded: true)
        #expect(isAppRunningCalls == 0)
    }
}
