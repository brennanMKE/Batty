// ColdLaunchEndpointResolverTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import batty

/// Covers `NewSessionCommand.ColdLaunchEndpointResolver` (#0415): the
/// caching and `lastFetchWasBrokerUnreachable` tracking that used to live in
/// an inline closure inside `run()`'s `.notRunningYet` arm, extracted so
/// both can be pinned without a live broker connection or the surrounding
/// `pollForNewSession` poll.
struct ColdLaunchEndpointResolverTests {

    private static func fakeEndpoint() -> NSXPCListenerEndpoint {
        NSXPCListener.anonymous().endpoint
    }

    @Test func noEndpointRegisteredReturnsNilAndClearsTheFlag() {
        let resolver = NewSessionCommand.ColdLaunchEndpointResolver(timeout: 1.0, fetchEndpoint: { _ in .endpoint(nil) })

        #expect(resolver.resolve() == nil)
        #expect(resolver.lastFetchWasBrokerUnreachable == false)
    }

    @Test func brokerUnreachableReturnsNilAndSetsTheFlag() {
        let resolver = NewSessionCommand.ColdLaunchEndpointResolver(timeout: 1.0, fetchEndpoint: { _ in .unreachable })

        #expect(resolver.resolve() == nil)
        #expect(resolver.lastFetchWasBrokerUnreachable == true)
    }

    /// The flag tracks only the *most recent* fetch: an `.unreachable` fetch
    /// followed by an `.endpoint(.none)` fetch must clear it back to
    /// `false`, not latch it once set.
    @Test func flagTracksTheMostRecentFetchOnly() {
        var responses: [BrokerAppEndpointClient.Result] = [.unreachable, .endpoint(nil)]
        let resolver = NewSessionCommand.ColdLaunchEndpointResolver(timeout: 1.0, fetchEndpoint: { _ in responses.removeFirst() })

        #expect(resolver.resolve() == nil)
        #expect(resolver.lastFetchWasBrokerUnreachable == true)

        #expect(resolver.resolve() == nil)
        #expect(resolver.lastFetchWasBrokerUnreachable == false)
    }

    /// The first `.endpoint(.some)` is returned and cached — a fetch stub
    /// that would return something *different* on a later call proves the
    /// cache actually skips the broker round trip, not merely that the
    /// first call's return value happened to match.
    @Test func firstEndpointFoundIsCachedSoLaterCallsMakeNoFurtherFetches() {
        let firstEndpoint = Self.fakeEndpoint()
        let secondEndpoint = Self.fakeEndpoint()
        var fetchCallCount = 0

        let resolver = NewSessionCommand.ColdLaunchEndpointResolver(timeout: 1.0, fetchEndpoint: { _ in
            fetchCallCount += 1
            return .endpoint(fetchCallCount == 1 ? firstEndpoint : secondEndpoint)
        })

        let first = resolver.resolve()
        let second = resolver.resolve()
        let third = resolver.resolve()

        #expect(first === firstEndpoint)
        #expect(second === firstEndpoint)
        #expect(third === firstEndpoint)
        #expect(fetchCallCount == 1)
    }

    /// A distinctive, non-default value (not `NewSessionCommand
    /// .pollRequestTimeout`, so this couldn't pass against a hardcoded
    /// production timeout) proves `timeout` is actually threaded through to
    /// `fetchEndpoint` rather than ignored.
    @Test func fetchIsCalledWithTheConfiguredTimeout() {
        var timeoutsSeen: [TimeInterval] = []
        let resolver = NewSessionCommand.ColdLaunchEndpointResolver(timeout: 7.25, fetchEndpoint: { timeout in
            timeoutsSeen.append(timeout)
            return .endpoint(nil)
        })

        _ = resolver.resolve()
        _ = resolver.resolve()

        #expect(timeoutsSeen == [7.25, 7.25])
    }

    /// `init`'s default `timeout` argument tracks `NewSessionCommand
    /// .pollRequestTimeout` — `run()` relies on this default rather than
    /// passing the constant explicitly.
    @Test func defaultTimeoutMatchesPollRequestTimeout() {
        var timeoutsSeen: [TimeInterval] = []
        let resolver = NewSessionCommand.ColdLaunchEndpointResolver(fetchEndpoint: { timeout in
            timeoutsSeen.append(timeout)
            return .endpoint(nil)
        })

        _ = resolver.resolve()

        #expect(timeoutsSeen == [NewSessionCommand.pollRequestTimeout])
    }
}
