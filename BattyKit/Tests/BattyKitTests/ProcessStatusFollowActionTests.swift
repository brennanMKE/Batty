// ProcessStatusFollowActionTests.swift

import Foundation
import Testing
@testable import BattyKit

struct ProcessStatusFollowActionTests {
    typealias Target = ProcessStatusPaneContent.Target
    typealias RunState = ProcessStatusPaneContent.RunState

    nonisolated static let allStates: [RunState] = [.running, .exited, .permissionDenied, .unavailable, .waiting]
    private static let name = "bt-follow-x7q"
    private static let pid: pid_t = 48_213

    private func offered(_ target: Target?, _ state: RunState, name: String? = ProcessStatusFollowActionTests.name) -> ProcessStatusFollowAction? {
        ProcessStatusFollowAction.offered(target: target, runState: state, listedName: name, pid: Self.pid)
    }

    @Test func pinnedRunningWithANameSeedsTheLivePid() {
        #expect(offered(.pinned(Self.pid), .running) == .follow(name: Self.name, seedPid: Self.pid))
    }

    @Test func pinnedExitedWithANameHasNoSeed() {
        #expect(offered(.pinned(Self.pid), .exited) == .follow(name: Self.name, seedPid: nil))
    }

    @Test(arguments: [RunState.running, .exited])
    func pinnedWithoutANameOffersNothing(state: RunState) {
        #expect(offered(.pinned(Self.pid), state, name: nil) == nil)
    }

    @Test(arguments: [RunState.permissionDenied, .unavailable, .waiting])
    func pinnedInOtherStatesOffersNothing(state: RunState) {
        #expect(offered(.pinned(Self.pid), state) == nil)
    }

    @Test(arguments: allStates)
    func followingNameAlwaysOffersStop(state: RunState) {
        #expect(offered(.followingName(Self.name), state) == .stopFollowing)
        #expect(offered(.followingName(Self.name), state, name: nil) == .stopFollowing)
    }

    @Test(arguments: allStates)
    func followingTabAndNoTargetOfferNothing(state: RunState) {
        #expect(offered(.followingTab(UUID()), state) == nil)
        #expect(offered(nil, state) == nil)
    }

    @Test func theSeedIsTheGivenPidNotTheNameOrAFixedValue() {
        let other: pid_t = 91_007
        let action = ProcessStatusFollowAction.offered(target: .pinned(other), runState: .running, listedName: "other-name", pid: other)
        #expect(action == .follow(name: "other-name", seedPid: other))
    }
}
