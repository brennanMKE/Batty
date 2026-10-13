// ProcessFollowByNameTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Follow-by-name (mode C) of `ProcessStatusPaneContent`, driven through the
/// `nameResolver` and `coreMetricsProvider` seams and a `TestClock`. No
/// real time passes in any test here except the real-process test, which
/// waits on nothing but process exit it forced itself.
@MainActor
struct ProcessFollowByNameTests {

    /// A scripted process table: which pids are alive (with their cumulative
    /// CPU ticks) and what the name resolver returns.
    final class World {
        var alive: [pid_t: UInt64] = [:]
        var resolves: pid_t?
        var resolverCalls = 0

        func metrics(_ pid: pid_t) -> Result<ProcessInspector.CoreMetrics, ProcessInspector.SampleFailure> {
            guard let ticks = alive[pid] else { return .failure(.processNotFound) }
            return .success(ProcessInspector.CoreMetrics(
                residentBytes: 1_000, physFootprintBytes: 2_000, threadCount: 3, openFileCount: 4,
                cpuTicksUser: ticks, cpuTicksSystem: 0
            ))
        }
    }

    private func makeContent(world: World, name: String = "app", clock: SchedulingClock = TestClock()) -> ProcessStatusPaneContent {
        ProcessStatusPaneContent(
            target: .followingName(name),
            tabLookup: { _ in nil },
            coreMetricsProvider: { world.metrics($0) },
            clock: clock,
            nameResolver: { requested in
                world.resolverCalls += 1
                #expect(requested == name)
                return world.resolves
            }
        )
    }

    /// One virtual tick: fires the pending sleeper, then awaits the loop
    /// re-registering, which only happens after `performSample()` returned.
    private func tick(_ clock: TestClock) async {
        await clock.advance(by: .seconds(1))
        #expect(await clock.waitForSleepers(1))
    }

    @Test func noMatchAtSetUpIsWaitingNotNoSelectionAndKeepsSampling() {
        let world = World()
        let content = makeContent(world: world)
        content.setUp(visible: true)
        #expect(content.runState == .waiting)
        #expect(content.hasNoSelection == false)
        #expect(content.isSamplingTaskAlive)
        #expect(content.snapshot == nil)
        #expect(world.resolverCalls == 1)
    }

    @Test func resolvedPidIsSampledAsRunning() {
        let world = World()
        world.alive = [501: 10]
        world.resolves = 501
        let content = makeContent(world: world)
        content.setUp(visible: true)
        #expect(content.runState == .running)
        #expect(content.snapshot?.pid == 501)
        #expect(content.target == .followingName("app"))
        #expect(content.followedPid == 501)
    }

    @Test func lossOfTheFollowedPidWaitsKeepsTheSnapshotAndTheTask() {
        let world = World()
        world.alive = [501: 10]
        world.resolves = 501
        let content = makeContent(world: world)
        content.setUp(visible: true)
        let lastSnapshot = content.snapshot
        #expect(lastSnapshot?.pid == 501)

        world.alive = [:]
        world.resolves = nil
        content.sampleNowForTesting()

        #expect(content.runState == .waiting)
        #expect(content.snapshot == lastSnapshot)
        #expect(content.hasNoSelection == false)
        #expect(content.isSamplingTaskAlive)
        #expect(content.followedPid == nil)
    }

    @Test func successiveReplacementsAreEachPickedUp() {
        let world = World()
        world.alive = [501: 10]
        world.resolves = 501
        let content = makeContent(world: world)
        content.setUp(visible: true)

        world.alive = [:]
        content.sampleNowForTesting()
        #expect(content.runState == .waiting)

        world.alive = [502: 20]
        world.resolves = 502
        content.sampleNowForTesting()
        #expect(content.runState == .running)
        #expect(content.snapshot?.pid == 502)
        #expect(content.followedPid == 502)

        world.alive = [:]
        world.resolves = nil
        content.sampleNowForTesting()
        #expect(content.runState == .waiting)
        #expect(content.snapshot?.pid == 502)

        world.alive = [503: 30]
        world.resolves = 503
        content.sampleNowForTesting()
        #expect(content.runState == .running)
        #expect(content.snapshot?.pid == 503)
        #expect(content.isSamplingTaskAlive)
    }

    @Test func aReplacementResetsLoadedDisclosures() {
        let world = World()
        world.alive = [501: 10]
        world.resolves = 501
        let content = makeContent(world: world)
        content.setUp(visible: true)
        #expect(content.openFilesState == .notLoaded)
        content.loadOpenFiles()
        content.loadChildProcesses()
        #expect(content.openFilesState != .notLoaded)
        #expect(content.childProcessesState != .notLoaded)

        world.alive = [:]
        content.sampleNowForTesting()
        world.alive = [502: 20]
        world.resolves = 502
        content.sampleNowForTesting()

        #expect(content.snapshot?.pid == 502)
        #expect(content.openFilesState == .notLoaded)
        #expect(content.childProcessesState == .notLoaded)
    }

    @Test func resolverRunsOncePerWaitingTickAndNeverWhileAPidIsHeld() {
        let world = World()
        let content = makeContent(world: world)
        content.setUp(visible: true)
        #expect(world.resolverCalls == 1)
        content.sampleNowForTesting()
        content.sampleNowForTesting()
        #expect(world.resolverCalls == 3)

        world.alive = [501: 10]
        world.resolves = 501
        content.sampleNowForTesting()
        #expect(world.resolverCalls == 4)
        #expect(content.runState == .running)

        for _ in 0..<5 { content.sampleNowForTesting() }
        #expect(world.resolverCalls == 4, "a live followed pid must not trigger enumeration")

        world.alive = [:]
        world.resolves = nil
        content.sampleNowForTesting()
        #expect(world.resolverCalls == 4, "the tick that discovers the loss does not re-enumerate")
        content.sampleNowForTesting()
        #expect(world.resolverCalls == 5)
    }

    @Test func theResolverIsDrivenByTheClockTickByTick() async {
        let clock = TestClock()
        let world = World()
        let content = makeContent(world: world, clock: clock)
        content.setUp(visible: true)
        #expect(await clock.waitForSleepers(1))
        #expect(content.runState == .waiting)

        world.alive = [501: 10]
        world.resolves = 501
        await tick(clock)
        #expect(content.runState == .running)
        #expect(content.snapshot?.pid == 501)

        world.alive = [:]
        world.resolves = nil
        await tick(clock)
        #expect(content.runState == .waiting)
        #expect(content.snapshot?.pid == 501)

        world.alive = [502: 20]
        world.resolves = 502
        await tick(clock)
        await tick(clock)
        #expect(content.runState == .running)
        #expect(content.snapshot?.pid == 502)
        content.tearDown()
    }

    @Test func theCPUBaselineIsResetWhenTheFollowedProcessIsLost() async {
        let clock = TestClock()
        let world = World()
        world.alive = [501: 1_000_000_000]
        world.resolves = 501
        let content = makeContent(world: world, clock: clock)
        content.setUp(visible: true)
        #expect(await clock.waitForSleepers(1))
        #expect(content.snapshot?.cpuPercent == nil, "first sample has no baseline")

        world.alive = [501: 5_000_000_000]
        await tick(clock)
        #expect(content.snapshot?.cpuPercent != nil, "second sample deltas against the first")

        world.alive = [:]
        world.resolves = nil
        await tick(clock)
        #expect(content.runState == .waiting)

        world.alive = [501: 9_000_000_000]
        world.resolves = 501
        await tick(clock)
        #expect(content.runState == .running)
        #expect(content.snapshot?.cpuPercent == nil, "a reconnect starts a fresh baseline")
        content.tearDown()
    }

    @Test func aHiddenWaitingPaneDoesNoPeriodicWorkAndResumesOnShow() async {
        let clock = TestClock()
        let world = World()
        let content = makeContent(world: world, clock: clock)
        content.setUp(visible: true)
        #expect(await clock.waitForSleepers(1))
        #expect(content.runState == .waiting)
        let callsBeforeHide = world.resolverCalls

        content.setVisible(false)
        #expect(clock.pendingCount == 0)
        #expect(content.isSamplingTaskAlive == false)
        await clock.advance(by: .seconds(30))
        #expect(world.resolverCalls == callsBeforeHide)
        #expect(content.target == .followingName("app"))

        world.alive = [501: 10]
        world.resolves = 501
        content.setVisible(true)
        #expect(content.runState == .running)
        #expect(content.snapshot?.pid == 501)
        #expect(content.isSamplingTaskAlive)
        content.tearDown()
    }

    @Test func stopFollowingWithAResolvedPidPinsIt() {
        let world = World()
        world.alive = [501: 10]
        world.resolves = 501
        let content = makeContent(world: world)
        content.setUp(visible: true)

        content.stopFollowingName()

        #expect(content.target == .pinned(501))
        #expect(content.followedPid == nil)
        #expect(content.snapshot?.pid == 501)
        #expect(content.runState == .running)
    }

    @Test func stopFollowingWhileWaitingClearsTheTarget() {
        let world = World()
        let content = makeContent(world: world)
        content.setUp(visible: true)

        content.stopFollowingName()

        #expect(content.target == nil)
        #expect(content.hasNoSelection)
    }

    @Test func stopFollowingIsANoOpForOtherTargets() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()), tabLookup: { _ in nil })
        content.setUp(visible: true)
        content.stopFollowingName()
        #expect(content.target == .pinned(getpid()))
    }

    @Test func retargetingAwayClearsTheFollowedPid() {
        let world = World()
        world.alive = [501: 10, 777: 10]
        world.resolves = 501
        let content = makeContent(world: world)
        content.setUp(visible: true)
        #expect(content.followedPid == 501)

        content.retarget(to: .pinned(777))

        #expect(content.followedPid == nil)
        #expect(content.snapshot?.pid == 777)
        #expect(content.target == .pinned(777))
    }

    @Test func aPinnedTargetStillTombstonesWithTheNameResolverPresent() {
        let world = World()
        world.resolves = 999
        let content = ProcessStatusPaneContent(
            target: .pinned(501),
            tabLookup: { _ in nil },
            coreMetricsProvider: { world.metrics($0) },
            nameResolver: { _ in world.resolverCalls += 1; return world.resolves }
        )
        content.setUp(visible: true)
        #expect(content.runState == .exited)
        #expect(content.isSamplingTaskAlive == false)
        #expect(world.resolverCalls == 0)
    }

    @Test func permissionDeniedKeepsTheFollowedPid() {
        let world = World()
        var denied = true
        let content = ProcessStatusPaneContent(
            target: .followingName("app"),
            tabLookup: { _ in nil },
            coreMetricsProvider: { pid in denied ? .failure(.permissionDenied) : world.metrics(pid) },
            nameResolver: { _ in world.resolverCalls += 1; return 501 }
        )
        world.alive = [501: 10]
        content.setUp(visible: true)
        #expect(content.runState == .permissionDenied)
        #expect(content.followedPid == 501)

        denied = false
        content.sampleNowForTesting()
        #expect(content.runState == .running)
        #expect(world.resolverCalls == 1)
    }

    // MARK: - Real enumerator

    private func uniqueSleepCopy() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-0486-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "bt0486-" + UUID().uuidString.prefix(6).lowercased()
        let url = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: url)
        return url
    }

    @Test func theRealEnumeratorFindsAUniquelyNamedProcessAndItsReplacement() throws {
        let executable = try uniqueSleepCopy()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let name = executable.lastPathComponent
        #expect(name.count <= 15)
        let fixture = ChildProcessFixture()
        defer { fixture.killAndReapAll() }

        #expect(ProcessInspector.firstSameUserProcess(named: name) == nil)

        func launch() throws -> Process {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["300"]
            try fixture.run(process)
            return process
        }

        let first = try launch()
        #expect(ProcessInspector.firstSameUserProcess(named: name) == first.processIdentifier)
        #expect(ProcessInspector.listedName(pid: first.processIdentifier) == name)

        let content = ProcessStatusPaneContent(target: .followingName(name), tabLookup: { _ in nil })
        content.setUp(visible: true)
        #expect(content.runState == .running)
        #expect(content.snapshot?.pid == first.processIdentifier)

        ChildProcessFixture.killAndReap(first)
        content.sampleNowForTesting()
        #expect(content.runState == .waiting)
        content.sampleNowForTesting()
        #expect(content.runState == .waiting, "nothing with that name is running")

        let second = try launch()
        content.sampleNowForTesting()
        #expect(content.runState == .running)
        #expect(content.snapshot?.pid == second.processIdentifier)
        content.tearDown()
    }

    @Test func theRealEnumeratorPrefersTheLongestRunningProcessOfAName() throws {
        let executable = try uniqueSleepCopy()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let name = executable.lastPathComponent
        let fixture = ChildProcessFixture()
        defer { fixture.killAndReapAll() }

        let older = Process()
        older.executableURL = executable
        older.arguments = ["300"]
        try fixture.run(older)
        let newer = Process()
        newer.executableURL = executable
        newer.arguments = ["300"]
        try fixture.run(newer)

        let listed = ProcessInspector.allSameUserProcesses()
            .filter { $0.name == name }
            .sorted(by: ProcessInspector.RunningProcess.listOrder)
        #expect(listed.count == 2)
        #expect(ProcessInspector.firstSameUserProcess(named: name) == listed.first?.id)
        #expect(listed.first?.id == older.processIdentifier)
    }
}
