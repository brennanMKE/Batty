// TestTeardownReapGateTests.swift

import Testing
@testable import BattyKit

/// Direct coverage of `TestTeardownReapGate` (#0428). No timing assertion
/// is needed to pin "stays closed until `open()`": `open()` sets `isOpen`
/// permanently before resuming anyone queued, so a waiter reaches
/// `waitUntilOpen()` either before `open()` (queued, then resumed by it) or
/// after (the `isOpen` fast path returns immediately) — both orderings
/// complete, so `await`ing each waiter is itself the correctness proof, not
/// a race against elapsed time.
nonisolated struct TestTeardownReapGateTests {
    /// `waitForParkedWaiter` returning `false` means its hang-guard bound
    /// elapsed instead of a real "someone is parked" event. Unlike
    /// `TestClock.sleep(for:)`, `waitUntilOpen()` installs no cancellation
    /// handler — cancelling its caller does not release it, only `open()`
    /// does — so on failure this records the actual failure and opens the
    /// gate itself, then awaits the task so a caller can safely `return`
    /// right after without leaving it still running past the test.
    @discardableResult
    private func requireParkedWaiter(
        on gate: TestTeardownReapGate,
        resuming task: Task<Void, Never>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let ready = await gate.waitForParkedWaiter()
        if !ready {
            Issue.record("waitForParkedWaiter() never reached its threshold", sourceLocation: sourceLocation)
            gate.open()
            await task.value
        }
        return ready
    }

    @Test func openResumesEveryWaiterRegardlessOfArrivalOrder() async {
        let gate = TestTeardownReapGate()

        async let first: Void = gate.waitUntilOpen()
        async let second: Void = gate.waitUntilOpen()

        gate.open()

        await first
        await second
    }

    @Test func waitUntilOpenReturnsImmediatelyOnceAlreadyOpen() async {
        let gate = TestTeardownReapGate()
        gate.open()

        await gate.waitUntilOpen()
        await gate.waitUntilOpen() // idempotent — a second call is still a no-op
    }

    /// Mirrors the actual proving use: production code (`Task.detached`)
    /// calls `waitUntilOpen()` off the main actor, so the gate's own
    /// correctness cannot depend on any particular actor's executor.
    @Test func waitUntilOpenWorksFromADetachedTask() async {
        let gate = TestTeardownReapGate()
        let task = Task.detached { await gate.waitUntilOpen() }
        gate.open()
        await task.value
    }

    // MARK: - waitForParkedWaiter

    /// A closed gate parks its caller in `waitUntilOpen()`, and
    /// `waitForParkedWaiter()` observes that as an event — not by assuming
    /// a closed gate implies a waiter exists.
    @Test func closedGateParksItsWaiterAndWaitForParkedWaiterObservesIt() async {
        let gate = TestTeardownReapGate()
        let task = Task { await gate.waitUntilOpen() }

        guard await requireParkedWaiter(on: gate, resuming: task) else { return }

        gate.open()
        await task.value
    }

    /// The negative half: with nobody actually parked, `waitForParkedWaiter`
    /// returns `false` — only via its hang-guard bound expiring, proving
    /// it's a real check, not vacuously true — and the gate is left in a
    /// consistent state afterward: a real waiter registered next is still
    /// served correctly by `open()`.
    @Test func waitForParkedWaiterTimingOutLeavesTheGateUsable() async {
        let gate = TestTeardownReapGate()

        #expect(await gate.waitForParkedWaiter(bound: 0.2) == false)

        let task = Task { await gate.waitUntilOpen() }
        guard await requireParkedWaiter(on: gate, resuming: task) else { return }
        gate.open()
        await task.value
    }
}
