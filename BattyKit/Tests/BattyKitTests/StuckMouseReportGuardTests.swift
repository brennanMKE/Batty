// StuckMouseReportGuardTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct StuckMouseReportGuardTests {
    private func process(members: [pid_t], name: String?) -> StuckMouseReportGuard.Process {
        .init(groupMembers: { _ in members }, name: { _ in name })
    }

    private func decide(
        captured: Bool = true,
        pid: pid_t? = 100,
        members: [pid_t] = [100],
        name: String? = "zsh"
    ) -> Bool {
        StuckMouseReportGuard.shouldWithholdClick(
            isMouseCaptured: captured,
            foregroundPid: pid,
            shiftHeld: false,
            process: process(members: members, name: name)
        )
    }

    @Test func withholdsWhenMouseModeIsOnAtIdleShell() {
        #expect(decide())
        #expect(decide(name: "bash"))
    }

    @Test func passesShiftClicksSoTheyCanSelectLocally() {
        let withheld = StuckMouseReportGuard.shouldWithholdClick(
            isMouseCaptured: true,
            foregroundPid: 100,
            shiftHeld: true,
            process: process(members: [100], name: "zsh")
        )
        #expect(!withheld)
    }

    @Test func passesClicksWhenNothingRequestedReporting() {
        #expect(!decide(captured: false))
    }

    @Test func passesClicksToProgramsThatOwnTheTerminal() {
        #expect(!decide(name: "vim"))
        #expect(!decide(name: "htop"))
        #expect(!decide(name: "claude"))
    }

    @Test func passesClicksWhenShellSharesItsGroupWithOtherProcesses() {
        #expect(!decide(members: [100, 101]))
        #expect(!decide(members: [7]))
    }

    @Test func passesClicksWhenProcessIsUnknown() {
        #expect(!decide(pid: nil))
        #expect(!decide(members: []))
        #expect(!decide(name: nil))
    }
}

@MainActor
struct StuckMouseReportGuardLiveProcessTests {
    @Test func liveGroupMembersListsTheTestProcessInItsOwnGroup() {
        let members = StuckMouseReportGuard.Process.live.groupMembers(getpgrp())
        #expect(members.contains(getpid()))
    }

    @Test func liveNameResolvesTheTestProcess() {
        #expect(StuckMouseReportGuard.Process.live.name(getpid()) != nil)
    }
}
