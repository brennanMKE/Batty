// ServerJobOwnershipTests.swift

import Darwin
import Foundation
import Testing
@testable import BattyKit

@MainActor
struct ServerJobOwnershipTests {
    let tabID = UUID()

    private func shell(_ table: FakeProcessTable) throws -> ProcessRecord {
        try #require(ServerJobResolver.locateTabShell(tabID: tabID, spawnedAfter: nil, snapshot: table.snapshot(), table: table))
    }

    @Test func locatesTheTabShellUnderBattysLoginChild() throws {
        let table = FakeProcessTable(tabID: tabID)
        #expect(try shell(table).pid == FakeProcessTable.shell)
    }

    @Test func aNestedShellCarryingTheSameTabIDIsNotTheTabShell() throws {
        let table = FakeProcessTable(tabID: tabID)
        table.add(ProcessRecord(pid: 100_610, ppid: FakeProcessTable.shell, pgid: 100_610))
        table.environments[100_610] = [ServerJobResolver.tabEnvironmentEntry(tabID)]
        #expect(try shell(table).pid == FakeProcessTable.shell)
    }

    @Test func aProcessOutsideBattyCarryingTheTabIDIsNotTheTabShell() {
        let table = FakeProcessTable(tabID: UUID())
        table.add(ProcessRecord(pid: 100_620, ppid: 1, pgid: 100_620))
        table.environments[100_620] = [ServerJobResolver.tabEnvironmentEntry(tabID)]
        #expect(ServerJobResolver.locateTabShell(tabID: tabID, spawnedAfter: nil, snapshot: table.snapshot(), table: table) == nil)
    }

    @Test func aListenerInItsOwnGroupUnderTheShellIsStopped() throws {
        let table = FakeProcessTable(tabID: tabID)
        let decision = ServerJobResolver.planGroupStop(listener: FakeProcessTable.listener, shell: try shell(table), snapshot: table.snapshot(), selfPid: table.selfPid)
        guard case .signal(let plan) = decision else { Issue.record("expected a plan, got \(decision)"); return }
        #expect(plan.target == .processGroup(FakeProcessTable.jobLeader))
        #expect(plan.anchor?.pid == FakeProcessTable.jobLeader)
    }

    @Test func aListenerOutsideTheTabShellTreeIsRefused() throws {
        let table = FakeProcessTable(tabID: tabID)
        table.add(ProcessRecord(pid: 100_990, ppid: 1, pgid: 100_990))
        let decision = ServerJobResolver.planGroupStop(listener: 100_990, shell: try shell(table), snapshot: table.snapshot(), selfPid: table.selfPid)
        guard case .refused = decision else { Issue.record("expected a refusal, got \(decision)"); return }
    }

    @Test func battysOwnAndAncestorGroupsAreRefused() throws {
        let table = FakeProcessTable(tabID: tabID)
        let shellStamp = try shell(table).stamp
        for pgid: pid_t in [100_050, 1, 0] {
            let plan = StopPlan(target: .processGroup(pgid), shell: shellStamp, anchor: nil)
            guard case .refuse = ServerJobResolver.check(plan, snapshot: table.snapshot(), selfPid: table.selfPid) else {
                Issue.record("group \(pgid) was not refused")
                continue
            }
        }
    }

    @Test func battyAndAncestorTreesAreRefused() {
        let table = FakeProcessTable(tabID: tabID)
        for pid: pid_t in [FakeProcessTable.batty, 100_050, 1] {
            let decision = ServerJobResolver.planTreeStop(listener: pid, snapshot: table.snapshot(), selfPid: table.selfPid)
            guard case .refused = decision else { Issue.record("pid \(pid) was not refused, got \(decision)"); continue }
        }
    }

    @Test func aReusedTreeRootIsRefused() {
        let table = FakeProcessTable(tabID: tabID)
        let plan = StopPlan(target: .processTree(FakeProcessTable.listener), anchor: ProcessStamp(pid: FakeProcessTable.listener, startSeconds: 1, startMicroseconds: 0))
        guard case .refuse = ServerJobResolver.check(plan, snapshot: table.snapshot(), selfPid: table.selfPid) else {
            Issue.record("reused root was not refused")
            return
        }
    }

    @Test func anEmptiedGroupIsGone() throws {
        let table = FakeProcessTable(tabID: tabID)
        let plan = StopPlan(target: .processGroup(100_777), shell: try shell(table).stamp, anchor: nil)
        #expect(ServerJobResolver.check(plan, snapshot: table.snapshot(), selfPid: table.selfPid) == .gone)
    }

    @Test func environmentParsingStopsAtTheEndOfTheBlock() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { buffer.append(contentsOf: $0) }
        buffer += Array("/bin/zsh".utf8) + [0]
        while (buffer.count - 4) % 8 != 0 { buffer.append(0) }
        buffer += Array("-zsh".utf8) + [0] + Array("".utf8) + [0]
        buffer += Array("A=1".utf8) + [0] + Array("BATTY_TAB_ID=x".utf8) + [0] + [0] + Array("junk".utf8) + [0]
        #expect(SystemProcessTable.environment(fromProcArgs2: buffer) == ["A=1", "BATTY_TAB_ID=x"])
    }

    @Test func aShellWithAHiddenEnvironmentIsFoundAsTheOnlyShellStartedAfterTheBaseline() {
        let table = FakeProcessTable(tabID: tabID)
        table.environments[FakeProcessTable.shell] = []
        table.add(ProcessRecord(pid: FakeProcessTable.login, ppid: FakeProcessTable.batty, pgid: FakeProcessTable.login, uid: 0, startSeconds: 50))
        table.add(ProcessRecord(pid: 100_210, ppid: FakeProcessTable.batty, pgid: 100_210, uid: 0, startSeconds: 20))
        table.add(ProcessRecord(pid: 100_610, ppid: 100_210, pgid: 100_610, startSeconds: 20))
        let baseline = ShellSpawnBaseline(seconds: 40, microseconds: 0)
        let found = ServerJobResolver.locateTabShell(tabID: tabID, spawnedAfter: baseline, snapshot: table.snapshot(), table: table)
        #expect(found?.pid == FakeProcessTable.shell)
        #expect(ServerJobResolver.locateTabShell(tabID: tabID, spawnedAfter: nil, snapshot: table.snapshot(), table: table) == nil)
    }

    @Test func twoShellsStartedAfterTheBaselineAreAmbiguous() {
        let table = FakeProcessTable(tabID: tabID)
        table.environments[FakeProcessTable.shell] = []
        table.add(ProcessRecord(pid: FakeProcessTable.login, ppid: FakeProcessTable.batty, pgid: FakeProcessTable.login, uid: 0, startSeconds: 50))
        table.add(ProcessRecord(pid: 100_210, ppid: FakeProcessTable.batty, pgid: 100_210, uid: 0, startSeconds: 51))
        table.add(ProcessRecord(pid: 100_610, ppid: 100_210, pgid: 100_610, startSeconds: 51))
        let baseline = ShellSpawnBaseline(seconds: 40, microseconds: 0)
        #expect(ServerJobResolver.locateTabShell(tabID: tabID, spawnedAfter: baseline, snapshot: table.snapshot(), table: table) == nil)
    }

    @Test func aShellNamingAnotherTabIsNeverChosenByStartTime() {
        let table = FakeProcessTable(tabID: UUID())
        let baseline = ShellSpawnBaseline(seconds: 0, microseconds: 0)
        #expect(ServerJobResolver.locateTabShell(tabID: tabID, spawnedAfter: baseline, snapshot: table.snapshot(), table: table) == nil)
    }

    /// The real table reads a spawned child's parent, group and start time,
    /// and Batty's ancestry.
    @Test func systemTableRecordsASpawnedChild() async throws {
        let baseline = ShellSpawnBaseline.now()
        let child = try TestChildSpawner.spawn("/bin/sleep", arguments: ["/bin/sleep", "30"], ownGroup: false)
        let pid = child.pid
        let table = SystemProcessTable()
        let record = table.snapshot().records[pid]
        child.signal(SIGKILL)
        #expect(await child.reap() != nil)
        #expect(record?.ppid == getpid())
        #expect(record?.pgid == getpgrp())
        #expect(record.map(baseline.precedes) == true)
        #expect(table.snapshot().ancestors(of: getpid()).contains(getppid()))
    }
}
