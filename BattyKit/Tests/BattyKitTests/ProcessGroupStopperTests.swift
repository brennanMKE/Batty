// ProcessGroupStopperTests.swift

import Darwin
import Foundation
import Testing
@testable import BattyKit

final class FakeProcessSignaller: ProcessSignalling, @unchecked Sendable {
    var sent: [(StopTarget, Int32)] = []
    /// The target stops being alive once one of these signals is sent.
    var diesOn: Set<Int32>
    private(set) var alive = true

    init(diesOn: Set<Int32> = [SIGINT]) {
        self.diesOn = diesOn
    }

    var signals: [Int32] { sent.map(\.1) }

    func signal(_ target: StopTarget, _ sig: Int32) -> Int32 {
        sent.append((target, sig))
        if diesOn.contains(sig) || sig == SIGKILL { alive = false }
        return 0
    }

    func isAlive(_ target: StopTarget) -> Bool { alive }
}

enum DriveStep<T: Sendable>: Sendable {
    case done(T)
    case sleeper
}

/// Advances `clock` by `step` each time the work registers a sleeper,
/// until `task` finishes.
@MainActor
func drive<T: Sendable>(_ task: Task<T, Never>, clock: TestClock, step: Duration = .milliseconds(250)) async -> T {
    while true {
        let next: DriveStep<T> = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.resume(.done(await task.value)) }
            Task.detached { await clock.waitForSleepers(1); once.resume(.sleeper) }
        }
        if case .done(let value) = next { return value }
        await clock.advance(by: step)
    }
}

@Suite(.auditsSignals)
@MainActor
struct ProcessGroupStopperTests {
    /// Above macOS's highest pid (99998), so no real process can collide
    /// with it in the ancestor checks.
    private let target = StopTarget.processGroup(104_242)

    @Test func sendsSIGINTFirstAndStopsWhenTheGroupExits() async {
        let clock = TestClock()
        let signaller = FakeProcessSignaller(diesOn: [SIGINT])
        let outcome = await ProcessGroupStopper.stop(target, signaller: signaller, clock: clock)
        #expect(outcome == .exited(after: SIGINT))
        #expect(signaller.signals == [SIGINT])
    }

    @Test func escalatesToSIGTERMAfterTheInterruptBound() async {
        let clock = TestClock()
        let signaller = FakeProcessSignaller(diesOn: [SIGTERM])
        let target = target
        let task = Task { await ProcessGroupStopper.stop(target, signaller: signaller, clock: clock) }
        let outcome = await drive(task, clock: clock)
        #expect(outcome == .exited(after: SIGTERM))
        #expect(signaller.signals == [SIGINT, SIGTERM])
        #expect(clock.now == Date(timeIntervalSince1970: 5))
    }

    @Test func escalatesToSIGKILLAfterTheTerminateBound() async {
        let clock = TestClock()
        let signaller = FakeProcessSignaller(diesOn: [])
        let target = target
        let task = Task { await ProcessGroupStopper.stop(target, signaller: signaller, clock: clock) }
        let outcome = await drive(task, clock: clock)
        #expect(outcome == .killed)
        #expect(signaller.signals == [SIGINT, SIGTERM, SIGKILL])
        #expect(clock.now == Date(timeIntervalSince1970: 8))
    }

    @Test func exitEventEndsTheWaitBeforeTheBound() async {
        let clock = TestClock()
        let signaller = FakeProcessSignaller(diesOn: [])
        var finished = false
        let target = target
        let task = Task { await ProcessGroupStopper.stop(target, signaller: signaller, clock: clock, exitEvent: { finished }) }
        await clock.waitForSleepers(1)
        finished = true
        await clock.advance(by: .milliseconds(250))
        #expect(await task.value == .exited(after: SIGINT))
        #expect(signaller.signals == [SIGINT])
    }

    @Test func refusesBattysOwnGroupAndPgidOne() async {
        let signaller = FakeProcessSignaller()
        for pgid in [getpgrp(), 1, 0] {
            let outcome = await ProcessGroupStopper.stop(.processGroup(pgid), signaller: signaller, clock: TestClock())
            guard case .refused = outcome else { Issue.record("pgid \(pgid) was not refused"); continue }
        }
        #expect(signaller.sent.isEmpty)
    }

    @Test func refusesBattyAndItsAncestorsAndTheirGroups() async {
        let signaller = FakeProcessSignaller()
        let parent = getppid()
        let targets: [StopTarget] = [.processTree(getpid()), .processTree(parent), .processTree(1), .processGroup(getpgid(parent))]
        for target in targets {
            let outcome = await ProcessGroupStopper.stop(target, signaller: signaller, clock: TestClock())
            guard case .refused = outcome else { Issue.record("\(target) was not refused"); continue }
        }
        #expect(signaller.sent.isEmpty)
    }

    @Test func treeNeverIncludesBattyOrAnAncestor() {
        #expect(SystemProcessSignaller.tree(root: getppid()).isEmpty)
        #expect(SystemProcessSignaller.tree(root: getpid()).isEmpty)
    }

    @Test func checkRefusalBeforeTheFirstSignalSendsNothing() async {
        let signaller = FakeProcessSignaller()
        let outcome = await ProcessGroupStopper.stop(target, signaller: signaller, clock: TestClock(), check: { .refuse("not ours") })
        #expect(outcome == .refused("not ours"))
        #expect(signaller.sent.isEmpty)
    }

    @Test func checkIsRepeatedBeforeEachEscalation() async {
        let clock = TestClock()
        let signaller = FakeProcessSignaller(diesOn: [])
        var checks = 0
        let target = target
        let task = Task {
            await ProcessGroupStopper.stop(target, signaller: signaller, clock: clock, check: {
                checks += 1
                return checks == 1 ? .proceed : .refuse("pid reused")
            })
        }
        let outcome = await drive(task, clock: clock)
        #expect(outcome == .refused("pid reused"))
        #expect(signaller.signals == [SIGINT])
        #expect(checks == 2)
    }

    @Test func aStopCancelledBetweenCheckAndSignalSendsNothingMore() async {
        let clock = TestClock()
        let signaller = FakeProcessSignaller(diesOn: [])
        var checks = 0
        let target = target
        let task = Task {
            await ProcessGroupStopper.stop(target, signaller: signaller, clock: clock, check: {
                checks += 1
                if checks == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                return .proceed
            })
        }
        let outcome = await drive(task, clock: clock)
        #expect(outcome == .refused("cancelled"))
        #expect(signaller.signals == [SIGINT])
    }

    @Test func goneBeforeTheFirstSignalIsAlreadyGone() async {
        let signaller = FakeProcessSignaller()
        let outcome = await ProcessGroupStopper.stop(target, signaller: signaller, clock: TestClock(), check: { .gone })
        #expect(outcome == .alreadyGone)
        #expect(signaller.sent.isEmpty)
    }
}

/// Real `/bin/sh` fixtures in their own process group, like `go run .` and
/// its compiled child. The grandchild prints "ready" itself, so it exists
/// before any signal; the pipe every member inherits gives EOF as the death
/// event.
@Suite(.auditsSignals)
@MainActor
struct ProcessGroupStopperRealProcessTests {
    private struct Fixture {
        let child: OwnedChild
        let pipe: Pipe
        var pid: pid_t { child.pid }
        var output: FileHandle { pipe.fileHandleForReading }
    }

    private func spawn(_ script: String) throws -> Fixture {
        let pipe = Pipe()
        let child = try TestChildSpawner.spawn(
            "/bin/sh",
            arguments: ["/bin/sh", "-c", script],
            ownGroup: true,
            stdout: pipe.fileHandleForWriting.fileDescriptor
        )
        try pipe.fileHandleForWriting.close()
        return Fixture(child: child, pipe: pipe)
    }

    /// Resolves at EOF: every holder of the pipe has exited. False when the
    /// hang guard expires first.
    private nonisolated static func awaitEOF(_ handle: FileHandle) async -> Bool {
        await awaitBounded {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = ResumeOnce(continuation)
                handle.readabilityHandler = { fileHandle in
                    if fileHandle.availableData.isEmpty {
                        fileHandle.readabilityHandler = nil
                        once.resume(())
                    }
                }
            }
        }
    }

    /// Reaps the fixture's leader off the main actor. False when the hang
    /// guard expires first.
    private nonisolated static func reap(_ fixture: Fixture) async -> Bool {
        await fixture.child.reap() != nil
    }

    /// After a failed guard: kill the fixture's own group so nothing
    /// outlives the test, then reap it.
    private func cleanUp(_ fixture: Fixture) async {
        fixture.output.readabilityHandler = nil
        fixture.child.signalGroup(SIGKILL)
        _ = await Self.reap(fixture)
    }

    @Test func interruptEndsAGoRunStyleParentAndChild() async throws {
        let fixture = try spawn("/bin/sh -c 'echo ready; exec /bin/sleep 30'; /bin/sleep 30")
        #expect(await ChildProcessReadiness.waitForData(on: fixture.pipe))
        let clock = TestClock()
        let signaller = SystemProcessSignaller()
        let stop = Task { await ProcessGroupStopper.stop(.processGroup(fixture.pid), signaller: signaller, clock: clock) }
        guard await Self.awaitEOF(fixture.output), await Self.reap(fixture) else {
            Issue.record("SIGINT did not end the fixture's group")
            stop.cancel()
            _ = await awaitBoundedValue { await stop.value }
            await cleanUp(fixture)
            return
        }
        let outcome = await drive(stop, clock: clock)
        #expect(outcome == .exited(after: SIGINT))
        #expect(!signaller.isAlive(.processGroup(fixture.pid)))
    }

    @Test func ignoredInterruptAndTerminateEndInSIGKILLForTheWholeGroup() async throws {
        let fixture = try spawn("trap '' INT TERM; /bin/sh -c 'echo ready; exec /bin/sleep 30'; /bin/sleep 30")
        #expect(await ChildProcessReadiness.waitForData(on: fixture.pipe))
        let clock = TestClock()
        let signaller = SystemProcessSignaller()
        let stop = Task { await ProcessGroupStopper.stop(.processGroup(fixture.pid), signaller: signaller, clock: clock) }
        let outcome = await drive(stop, clock: clock)
        #expect(outcome == .killed)
        guard await Self.awaitEOF(fixture.output), await Self.reap(fixture) else {
            Issue.record("SIGKILL did not end the fixture's group")
            await cleanUp(fixture)
            return
        }
        #expect(!signaller.isAlive(.processGroup(fixture.pid)))
    }
}
