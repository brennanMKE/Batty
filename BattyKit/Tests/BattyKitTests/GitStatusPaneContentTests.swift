// GitStatusPaneContentTests.swift

import Foundation
import Testing
@testable import BattyKit

// MARK: - Test doubles
//
// Mirrors `PaneContentLifecycleTests`'s `WatcherLedger`/`RecordingPaneContent`
// shape (#0303), applied to `GitStatusPaneContent`'s actual seams
// (`GitStatusWatching`/`GitStatusScanning`) instead of the generic
// `PaneContentLifecycle` alone — these prove *this* conformer wires a real
// watcher/scanner faithfully to the transitions, not just that the
// underlying state machine is correct (already covered by
// `PaneContentLifecycleTests`).
//
// Both doubles are `nonisolated` — matching the production conformers
// (`FSEventsGitStatusWatcher`/`ProcessGitStatusScanner`) — with plain,
// unsynchronized counters. Safe here because every call in these tests
// happens sequentially from the `@MainActor` test function's own thread of
// control (`GitStatusPaneContent`'s own methods, which call into these
// doubles, are themselves MainActor-isolated); a real conformer needs its
// own thread-safety for genuine background-thread work, which
// `ProcessGitStatusScanner`'s lock-guarded `activeProcesses` provides.

private nonisolated final class RecordingWatcher: GitStatusWatching, @unchecked Sendable {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private let onEvent: @MainActor () -> Void

    init(onEvent: @escaping @MainActor () -> Void) {
        self.onEvent = onEvent
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }

    /// Test-only: simulates an FSEvents callback firing. `@MainActor`
    /// because the real callback is always delivered on the main queue
    /// (`FSEventStreamSetDispatchQueue(_, .main)`) — this double is called
    /// the same way, directly from `@MainActor` test functions.
    @MainActor func trigger() { onEvent() }
}

/// `GitStatusPaneContent` creates a brand-new watcher instance on every
/// `suspended → active` transition (matching the design: "suspended means
/// fully torn down, not paused" — a real `FSEventStream` is genuinely
/// released and re-created, not reused). This box records every watcher
/// the factory has produced so a test can inspect the *specific* instance
/// a given phase transition acquired or released, not just a single
/// long-lived double's cumulative counts.
@MainActor
private final class WatcherBox {
    private(set) var created: [RecordingWatcher] = []
    var current: RecordingWatcher? { created.last }

    func make(onEvent: @escaping @MainActor () -> Void) -> RecordingWatcher {
        let watcher = RecordingWatcher(onEvent: onEvent)
        created.append(watcher)
        return watcher
    }
}

/// Lets a test observe "a scan has started" and control exactly when it
/// resolves — replaces `RecordingScanner`'s old `scanDelayNanoseconds` real,
/// fixed delay with an explicit continuation a test releases itself
/// (`#0430`), the same "gate the fake, don't sleep past it" shape
/// `SystemMetricsPaneContentTests`'s `GatedSampler` uses for its own sampler
/// (a "started" signal plus an explicit `release()`).
/// `nonisolated`/`@unchecked Sendable` + lock: `RecordingScanner
/// .scan(atPath:)` runs inside `GitStatusPaneContent`'s own scan `Task`, not
/// necessarily on the `@MainActor` the test itself runs on.
private nonisolated final class ScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasStarted = false
    private var startWaiter: (() -> Void)?
    private var isReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    /// Called by `RecordingScanner.scan(atPath:)`: records that a scan has
    /// started (waking any `waitForScanStarted()` caller), then suspends
    /// until the test calls `release()`.
    func markStartedAndAwaitRelease() async {
        let notifyStarted: (() -> Void)? = lock.withLock {
            hasStarted = true
            let waiter = startWaiter
            startWaiter = nil
            return waiter
        }
        notifyStarted?()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if isReleased { return true }
                releaseContinuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
            isReleased = true
            let waiting = releaseContinuation
            releaseContinuation = nil
            return waiting
        }
        toResume?.resume()
    }

    /// `bound` is a hang-guard only, the same rule `ChildProcessReadiness`/
    /// `TestClock.waitForSleepers` follow (`docs/async-test-seams.md` §2,
    /// §1): on expiry this resolves `false`, never how it's meant to
    /// succeed.
    @discardableResult
    func waitForScanStarted(bound: TimeInterval = 15) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let timeoutWorkItem = DispatchWorkItem { once.resume(false) }
            once.setOnResumed { timeoutWorkItem.cancel() }
            let resumeNow: Bool = lock.withLock {
                if hasStarted { return true }
                startWaiter = { once.resume(true) }
                return false
            }
            if resumeNow {
                once.resume(true)
            } else {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bound, execute: timeoutWorkItem)
            }
        }
    }
}

private nonisolated final class RecordingScanner: GitStatusScanning, @unchecked Sendable {
    private(set) var scanCount = 0
    private(set) var terminateIfRunningCount = 0
    private(set) var terminateAndWaitBrieflyCount = 0
    /// Counts calls to the quit-path-only requirement
    /// (`GitStatusPaneContent.waitForDeferredTeardown()` →
    /// `GitStatusScanning.waitForPendingTeardownSynchronously()`) — this
    /// double has no real deferred work to wait for, but a required
    /// protocol requirement (not a defaulted no-op) means this count is
    /// what proves the quit path actually reaches the scanner at all.
    private(set) var waitForPendingTeardownSynchronouslyCount = 0

    /// What the *next* `scan(atPath:)` call returns. Settable from a test
    /// before triggering a scan.
    var nextResult: GitStatusScanResult = .notARepository
    /// When set, `scan(atPath:)` suspends on this gate after recording the
    /// call, until the test explicitly releases it — lets a test hide the
    /// pane (or otherwise change phase) while a scan is still genuinely in
    /// flight, to verify the stale result gets discarded rather than
    /// applied (the `generation` guard in
    /// `GitStatusPaneContent.handleScanResult`), with no real delay
    /// (`#0430`; replaces the old `scanDelayNanoseconds`).
    var gate: ScanGate?

    func scan(atPath path: String) async -> GitStatusScanResult {
        scanCount += 1
        if let gate {
            await gate.markStartedAndAwaitRelease()
        }
        return nextResult
    }

    func diff(atPath path: String, relativeFilePath: String, staged: Bool) async -> String? {
        "diff for \(relativeFilePath)"
    }

    func terminateIfRunning() { terminateIfRunningCount += 1 }
    func terminateAndWaitBriefly() { terminateAndWaitBrieflyCount += 1 }
    func waitForPendingTeardownSynchronously() { waitForPendingTeardownSynchronouslyCount += 1 }
}

@MainActor
private func makeContent(
    scanner: RecordingScanner,
    clock: SchedulingClock = TestClock(),
    debounceNanoseconds: UInt64 = 5_000_000
) -> (GitStatusPaneContent, WatcherBox) {
    let box = WatcherBox()
    let content = GitStatusPaneContent(
        directoryPath: "/tmp/example-repo",
        scanner: scanner,
        watcherFactory: { _, onEvent in box.make(onEvent: onEvent) },
        debounceNanoseconds: debounceNanoseconds,
        clock: clock
    )
    return (content, box)
}

/// Races a real signal (delivered via `signal()`) against a hang-guard
/// timeout — the same `ResumeOnce` + cancellable `DispatchWorkItem` shape
/// `ChildProcessReadiness` uses. `nonisolated`/`@unchecked Sendable` + lock
/// is load-bearing here, not decorative: this package defaults every
/// declaration to `@MainActor` isolation (`Package.swift`'s
/// `.defaultIsolation(MainActor.self)`), so a closure like the timeout's
/// `{ once.resume(false) }`, if it were instead written directly inside an
/// `@MainActor`-isolated function, would itself be inferred `@MainActor`-
/// isolated by lexical inheritance — and calling MainActor-isolated code
/// synchronously from the raw background-queue thread the `DispatchWorkItem`
/// actually runs on (no Swift Task/executor hop involved at all) traps at
/// runtime instead of failing the test. Keeping the whole continuation race
/// on a `nonisolated` type sidesteps that entirely — matching why
/// `TestClock`, `TestTeardownReapGate`, `ChildProcessReadiness`, and this
/// suite's own `ScanGate` are all explicitly `nonisolated` too.
private nonisolated final class ScanHandledSignal: @unchecked Sendable {
    private let lock = NSLock()
    /// Set the instant `signal()` runs, *before* it even checks whether a
    /// waiter is registered — this is what closes the lost-wakeup race:
    /// `signal()` can run (on MainActor, from `handleScanResult`) after
    /// `awaitScanHandled` installs the callback but *before* `wait()` below
    /// — a `nonisolated` async call, which this package's
    /// `.defaultIsolation(MainActor.self)` routes onto the global
    /// concurrent executor, i.e. a genuine hop away from MainActor — has
    /// actually reached its own `withCheckedContinuation` registration.
    /// Without this flag, a `signal()` that wins that race finds no
    /// `pendingResume` yet, does nothing, and the real event is silently
    /// dropped — `wait()` then only ever resolves via its hang-guard
    /// timeout. `wait()` checks this flag both before and (again, closing
    /// the same race a second time) *inside* its continuation's
    /// registration closure — the same idiom
    /// `TestTeardownReapGate.waitUntilOpen()` uses for the identical
    /// concurrent-`open()` race.
    private var isSignaled = false
    private var pendingResume: ((Bool) -> Void)?

    /// Called from `GitStatusPaneContent.onScanResultHandledForTesting`
    /// (`@MainActor`) once the awaited count is reached. Safe to call
    /// from any actor: this type has no isolation of its own to violate.
    func signal() {
        let resume: ((Bool) -> Void)? = lock.withLock {
            isSignaled = true
            let pending = pendingResume
            pendingResume = nil
            return pending
        }
        resume?(true)
    }

    /// `bound` is a hang-guard only, the same rule `ChildProcessReadiness`/
    /// `TestClock.waitForSleepers` follow: on expiry this resolves `false`,
    /// never how it's meant to succeed.
    func wait(bound: TimeInterval) async -> Bool {
        let alreadySignaled: Bool = lock.withLock { isSignaled }
        if alreadySignaled { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let timeoutWorkItem = DispatchWorkItem { once.resume(false) }
            once.setOnResumed { timeoutWorkItem.cancel() }
            let resumeNow: Bool = lock.withLock {
                if isSignaled { return true }
                pendingResume = { once.resume($0) }
                return false
            }
            if resumeNow {
                once.resume(true)
            } else {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bound, execute: timeoutWorkItem)
            }
        }
    }
}

/// Awaits `content`'s scan-handled signal, recording (and returning
/// `false` on) a failed wait instead of silently continuing as though the
/// scan had resolved — the rule `docs/async-test-seams.md` §4 spells out
/// for every readiness wait in this suite. The bounded wait itself lives
/// entirely here, in the test target, via `ScanHandledSignal` above —
/// `GitStatusPaneContent` exposes only the raw event
/// (`onScanResultHandledForTesting`, fired once per `handleScanResult`
/// call), so a production type never owns a fixed-duration hang-guard
/// sleep for a test's own timeout (round 1 review, B2).
///
/// Only one wait may be in flight on a given `content` at a time — each
/// call installs (and, on completion, clears) the single
/// `onScanResultHandledForTesting` slot — which matches how every test in
/// this suite actually uses it: sequential awaits, never overlapping ones.
@MainActor
@discardableResult
private func awaitScanHandled(
    _ content: GitStatusPaneContent,
    atLeast count: Int,
    bound: TimeInterval = 15,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> Bool {
    if content.handledScanResultCount >= count {
        return true
    }
    let signal = ScanHandledSignal()
    content.onScanResultHandledForTesting = { handledCount in
        if handledCount >= count {
            signal.signal()
        }
    }
    let reached = await signal.wait(bound: bound)
    content.onScanResultHandledForTesting = nil
    if !reached {
        Issue.record(
            "scan-result-handled wait never reached count \(count)",
            sourceLocation: sourceLocation
        )
    }
    return reached
}

@MainActor
struct GitStatusPaneContentTests {

    // MARK: - Lifecycle: setup

    @Test func createdHiddenNeverAcquiresAWatcherOrScans() {
        let scanner = RecordingScanner()
        let clock = TestClock()
        let (content, box) = makeContent(scanner: scanner, clock: clock)
        content.setUp(visible: false)
        // A regression that makes `setUp(visible: false)` call `activate()`
        // unconditionally — synchronously, or deferred via a `Task`
        // assigned to `watcher`/`debounceTask`/`scanTask` — is caught by
        // `hasNoScheduledOrAcquiredWorkForTesting` with no wait at all:
        // `activate()` sets `watcher` and starts `scanTask` synchronously
        // as part of the call that schedules it, and assigning a deferred
        // `Task` to one of those properties is itself synchronous,
        // regardless of when the `Task`'s body actually runs.
        // `clock.pendingCount == 0` is a narrower, secondary check, not a
        // second way to catch the same class of regression: `TestClock`
        // only registers a sleeper once a `Task`'s body actually reaches
        // `await clock.sleep(for:)`, so a `Task` that hasn't been scheduled
        // to run yet — tracked or not — registers nothing, and this alone
        // cannot tell "correctly did nothing" apart from "scheduled
        // something that hasn't started." A raw, untracked
        // `Task { self.activate() }` — assigned to none of this type's
        // tracked properties — passes every check here; an accepted scope
        // limit, not something either check closes. See `issues/0430.md`'s
        // round 2 notes.
        #expect(content.lifecyclePhase == .suspended)
        #expect(box.created.isEmpty)
        #expect(scanner.scanCount == 0)
        #expect(content.hasNoScheduledOrAcquiredWorkForTesting)
        #expect(clock.pendingCount == 0)
    }

    @Test func createdVisibleAcquiresAWatcherAndScansOnce() async {
        let scanner = RecordingScanner()
        scanner.nextResult = .notARepository
        let (content, box) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        guard await awaitScanHandled(content, atLeast: 1) else { return }
        #expect(content.lifecyclePhase == .active)
        #expect(box.created.count == 1)
        #expect(box.current?.startCount == 1)
        #expect(scanner.scanCount == 1)
    }

    // MARK: - Lifecycle: show/hide

    @Test func hidingAnActivePaneStopsTheWatcherAndSuspendsToZeroPeriodicWork() async {
        let scanner = RecordingScanner()
        let clock = TestClock()
        let (content, box) = makeContent(scanner: scanner, clock: clock)
        content.setUp(visible: true)
        guard await awaitScanHandled(content, atLeast: 1) else { return }

        content.setVisible(false)
        #expect(content.lifecyclePhase == .suspended)
        #expect(box.current?.stopCount == 1)
        #expect(scanner.terminateIfRunningCount == 1)
        #expect(scanner.terminateAndWaitBrieflyCount == 0)
        // `suspend()` cancels any pending debounce synchronously —
        // `TestClock.sleep(for:)` wraps its continuation in
        // `withTaskCancellationHandler`, so a pending sleeper is removed
        // the instant `Task.cancel()` runs, not eventually. No watcher
        // event fired in this test, so there was never a debounce sleeper
        // to begin with; this still pins that hiding leaves none pending.
        #expect(clock.pendingCount == 0, "hiding must leave nothing pending on the clock")

        let scanCountAtHide = scanner.scanCount
        // Zero periodic work while suspended: mirrors
        // `PaneContentLifecycleTests`'s own "count attempted work, observe
        // it doesn't move" pattern, and
        // `ProcessStatusPaneLifecycleWiringTests.aHiddenProcessStatusPaneDoesNotKeepSampling`'s
        // clock-driven version of it. This only proves "no periodic work
        // *routed through the injected clock*" — `GitStatusPaneContent`
        // has no periodic mechanism today besides the one-shot debounce, so
        // this pins that a hypothetical periodic poller *following this
        // type's own established convention* (routing through `clock`,
        // same as the debounce) can't survive suspend: `advance(by:)`
        // firing zero sleepers here, on a clock nothing else is registered
        // on, means nothing was scheduled — not an inference from timing.
        // It does not, and cannot, catch a periodic loop built on a raw,
        // real-time sleep that bypasses the clock entirely.
        let firedWhileSuspended = await clock.advance(by: .seconds(3600))
        #expect(firedWhileSuspended == 0, "no periodic work may survive suspend")
        #expect(scanner.scanCount == scanCountAtHide, "no periodic work may survive suspend")
        #expect(clock.pendingCount == 0)
    }

    @Test func showingAfterHidingAcquiresAFreshWatcherAndForcesExactlyOneRefresh() async {
        let scanner = RecordingScanner()
        let (content, box) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        guard await awaitScanHandled(content, atLeast: 1) else { return }
        content.setVisible(false)
        let scanCountAtHide = scanner.scanCount
        let handledCountAtHide = content.handledScanResultCount

        content.setVisible(true)
        // Watcher acquisition happens inside `activate()`, called directly
        // (synchronously) from `setVisible(true)` — no wait needed.
        #expect(content.lifecyclePhase == .active)
        // Suspended means fully torn down, not paused — showing again
        // acquires a brand-new watcher instance rather than restarting the
        // released one.
        #expect(box.created.count == 2)
        #expect(box.created[0].stopCount == 1)
        #expect(box.created[1].startCount == 1)

        guard await awaitScanHandled(content, atLeast: handledCountAtHide + 1) else { return }
        #expect(scanner.scanCount == scanCountAtHide + 1)
    }

    @Test func redundantShowDoesNotDoubleAcquireOrDoubleRefresh() async {
        let scanner = RecordingScanner()
        let clock = TestClock()
        let (content, box) = makeContent(scanner: scanner, clock: clock)
        content.setUp(visible: true)
        guard await awaitScanHandled(content, atLeast: 1) else { return }
        // `handleScanResult` sets `isRefreshing = false` before it sets
        // `state`, in the same synchronous call, so both are already
        // settled once the scan-handled signal fires.
        #expect(content.state != .loading)
        #expect(content.isRefreshing == false)
        let generationBeforeRedundantShow = content.generationForTesting

        content.setVisible(true) // already visible — must be a no-op
        // Every one of these is an instant, synchronous check — no wait
        // needed. `generationForTesting` is unchanged only if `activate()`
        // never ran again: it's bumped synchronously at the top of
        // `activate()`, so this catches a regression that re-activates even
        // if `scanTask` from the first scan is already non-nil (which is
        // why `hasNoScheduledOrAcquiredWorkForTesting` alone wouldn't work
        // here — see its own doc comment). `isRefreshing` is a second,
        // independent synchronous tell: `requestScan()` sets it `true`
        // before ever reaching the `await` inside its scan `Task`.
        // `hasPendingDebounceForTesting` catches a regression that
        // schedules a debounce `Task` instead — `debounceTask` is still
        // nil at this point (no watcher event has ever fired), so, unlike
        // `hasNoScheduledOrAcquiredWorkForTesting`, checking it directly
        // here is meaningful. `clock.pendingCount == 0` is *not* a second,
        // independent way to catch that same regression: `TestClock` only
        // registers a sleeper once a `Task`'s body actually reaches `await
        // clock.sleep(for:)`, so a freshly-created, not-yet-run debounce
        // `Task` would leave `pendingCount` at 0 too, even though
        // `hasPendingDebounceForTesting` already caught it via the
        // synchronous property assignment. As with the setup tests above,
        // a raw, untracked `Task { self.activate() }` bypassing every
        // tracked property is an accepted, undetectable-without-waiting
        // gap — see `issues/0430.md`'s round 2 notes.
        #expect(content.generationForTesting == generationBeforeRedundantShow)
        #expect(content.isRefreshing == false)
        #expect(content.hasPendingDebounceForTesting == false)
        #expect(clock.pendingCount == 0)
        #expect(box.created.count == 1)
        #expect(box.current?.startCount == 1)
        #expect(scanner.scanCount == 1)
    }

    // MARK: - Lifecycle: teardown

    @Test func tearDownFromActiveReleasesTheWatcherSynchronouslyAndWaitsOnTheScanner() async {
        let scanner = RecordingScanner()
        let (content, box) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        guard await awaitScanHandled(content, atLeast: 1) else { return }

        content.tearDown()
        #expect(content.lifecyclePhase == .tornDown)
        #expect(box.current?.stopCount == 1)
        #expect(scanner.terminateAndWaitBrieflyCount == 1)
        #expect(scanner.terminateIfRunningCount == 0)
    }

    @Test func tearDownIsIdempotent() async {
        let scanner = RecordingScanner()
        let (content, box) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        guard await awaitScanHandled(content, atLeast: 1) else { return }

        content.tearDown()
        content.tearDown()
        #expect(box.current?.stopCount == 1)
        #expect(scanner.terminateAndWaitBrieflyCount == 1)
    }

    /// Pins the quit-path wiring `WindowRuntime.tearDownAllPaneContentSynchronouslyForQuit()`
    /// (#0354, #0422) depends on: `GitStatusPaneContent` must actually be
    /// reachable as `DeferredTeardownWaiting`, and its
    /// `waitForDeferredTeardown()` must actually reach the scanner's
    /// `waitForPendingTeardownSynchronously()` — not just compile-time
    /// conformance, but the real call happening.
    @Test func tearDownAsDeferredTeardownWaitingReachesTheScanner() async throws {
        let scanner = RecordingScanner()
        let (content, _) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        guard await awaitScanHandled(content, atLeast: 1) else { return }
        content.tearDown()

        let deferredTeardownWaiting = try #require(content as? DeferredTeardownWaiting)
        deferredTeardownWaiting.waitForDeferredTeardown()

        #expect(scanner.waitForPendingTeardownSynchronouslyCount == 1)
    }

    @Test func setVisibleAfterTearDownIsRejectedAndDoesNothing() {
        let scanner = RecordingScanner()
        let clock = TestClock()
        let (content, box) = makeContent(scanner: scanner, clock: clock)
        content.setUp(visible: false)
        content.tearDown()

        content.setVisible(true)
        // `tearDown()`'s `suspend()` already nils `watcher`/`debounceTask`/
        // `scanTask`, so — same reasoning as
        // `createdHiddenNeverAcquiresAWatcherOrScans` above (see its
        // comment for why `clock.pendingCount == 0` doesn't extend this
        // any further) — a regression that reactivates from the
        // `.rejected` branch via a `Task` assigned to one of those
        // properties is caught here with no wait. Same accepted scope
        // limit for a raw, untracked `Task {}` — see `issues/0430.md`'s
        // round 2 notes.
        #expect(box.created.isEmpty)
        #expect(scanner.scanCount == 0)
        #expect(content.lifecyclePhase == .tornDown)
        #expect(content.hasNoScheduledOrAcquiredWorkForTesting)
        #expect(clock.pendingCount == 0)
    }

    // MARK: - Debounce coalescing

    @Test func rapidWatcherEventsCoalesceIntoOneScanAfterTheDebounceWindow() async {
        let scanner = RecordingScanner()
        let clock = TestClock()
        let debounceNanoseconds: UInt64 = 60_000_000
        let (content, box) = makeContent(scanner: scanner, clock: clock, debounceNanoseconds: debounceNanoseconds)
        content.setUp(visible: true)
        guard await awaitScanHandled(content, atLeast: 1) else { return } // the initial "show" refresh

        let scanCountBeforeBurst = scanner.scanCount
        let handledCountBeforeBurst = content.handledScanResultCount
        for _ in 0..<5 {
            box.current?.trigger()
        }
        // Nothing new yet — `TestClock` never lets time pass on its own, so
        // this holds regardless of machine speed, not just "within a
        // window."
        #expect(scanner.scanCount == scanCountBeforeBurst)

        // Each watcher event cancels the previous debounce `Task` before
        // scheduling a fresh one; a cancelled `Task` calling
        // `TestClock.sleep(for:)` never actually registers as a sleeper
        // (registration checks `Task.isCancelled` under the same lock the
        // cancellation handler uses). Only the burst's *last* trigger's
        // `Task` is never cancelled, so exactly one sleeper should ever
        // register — a real, structural proof of coalescing, not an
        // inference from "only one scan happened."
        guard await clock.waitForSleepers(1) else {
            Issue.record("waitForSleepers(1) never reached its threshold")
            // `TestClock.sleep(for:)`'s cancellation handler releases a
            // registered-or-not sleeper either way (`docs/async-test-seams.md`
            // §4) — tear the pane down so nothing is left running past this
            // early return.
            content.tearDown()
            return
        }
        #expect(clock.pendingCount == 1, "a 5-trigger burst must coalesce into a single pending debounce")

        let firedSleepers = await clock.advance(by: .nanoseconds(Int64(debounceNanoseconds)))
        #expect(firedSleepers == 1, "advancing past the debounce window must fire exactly the one coalesced sleeper")
        guard await awaitScanHandled(content, atLeast: handledCountBeforeBurst + 1) else { return }
        #expect(scanner.scanCount == scanCountBeforeBurst + 1)
        #expect(clock.pendingCount == 0)
        // `scanner.scanCount` alone doesn't prove the debounce fired
        // `requestScanIfCurrent` exactly once: a regression that calls it
        // twice from the same fired sleeper still only shows one completed
        // scan here, because the second, pending-rescan-triggered
        // `requestScan()` runs synchronously inside `handleScanResult`'s
        // own tail — *before* this `await` resumes — and sets
        // `isRefreshing` back to `true` without yet having called
        // `scanner.scan()` again (that needs its own `Task` hop). Asserting
        // `isRefreshing == false` here catches that regression that
        // `scanCount` alone cannot.
        #expect(content.isRefreshing == false)
    }

    @Test func hidingDuringAnInFlightScanDiscardsItsResult() async {
        let scanner = RecordingScanner()
        let gate = ScanGate()
        scanner.gate = gate
        scanner.nextResult = .notARepository
        let (content, _) = makeContent(scanner: scanner)
        content.setUp(visible: true)

        guard await gate.waitForScanStarted() else {
            Issue.record("waitForScanStarted() never reached its threshold")
            // Release whatever `RecordingScanner.scan(atPath:)` would
            // otherwise still be parked on, and tear the pane down, so an
            // early return here never leaves a scan `Task` suspended
            // forever.
            gate.release()
            content.tearDown()
            return
        }
        // The scan is now genuinely in flight, suspended on the gate —
        // hide before it resolves.
        content.setVisible(false)
        let handledCountBeforeRelease = content.handledScanResultCount
        gate.release()

        // `handledScanResultCount` (and its companion event) increments at
        // the top of `handleScanResult`, before the generation/phase guard
        // that discards this particular result, so this reliably fires the
        // instant the stale result is (correctly) thrown away.
        guard await awaitScanHandled(content, atLeast: handledCountBeforeRelease + 1) else { return }
        // The scan that was in flight when hidden must not have flipped
        // state to `.notARepository` — the generation guard in
        // `handleScanResult` discards it because the pane is no longer
        // `.active` by the time the (stale) result arrives.
        #expect(content.state == .loading)
        #expect(content.lifecyclePhase == .suspended)
    }

    // MARK: - State reduction (parsing composed into a snapshot)

    @Test func aSuccessfulScanComposesAGitStatusSnapshotFromTheRawScan() async {
        let scanner = RecordingScanner()
        // NUL-joined, matching real `-z` output — see
        // `GitStatusPorcelainParser`'s doc comment for why (review round 1,
        // B1: a newline-joined fixture is not what the parser consumes
        // any more).
        scanner.nextResult = .snapshot(GitStatusRawScan(
            statusOutput: [
                "# branch.oid abc123",
                "# branch.head main",
                "# branch.upstream origin/main",
                "# branch.ab +1 -0",
                "# stash 2",
                "1 M. N... 100644 100644 100644 aaaa bbbb a.txt",
                "? new.txt",
            ].joined(separator: "\u{0}"),
            operationMarker: .none,
            submoduleParentName: nil,
            isWorktree: false,
            repositoryToplevel: "/tmp/example-repo"
        ))
        let (content, _) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        guard await awaitScanHandled(content, atLeast: 1) else { return }

        guard case .snapshot(let snapshot) = content.state else {
            Issue.record("expected a snapshot state")
            return
        }
        #expect(snapshot.repoName == "example-repo")
        #expect(snapshot.repositoryToplevel == "/tmp/example-repo")
        #expect(snapshot.branch == "main")
        #expect(snapshot.ahead == 1)
        #expect(snapshot.stashCount == 2)
        #expect(snapshot.staged == [GitStatusFileEntry(path: "a.txt", statusKind: .modified)])
        #expect(snapshot.untracked == [GitStatusFileEntry(path: "new.txt", statusKind: .untracked)])
        #expect(snapshot.operationState == .none)
    }

    @Test func aMergeMarkerComposesConflictCountFromTheParsedConflictedEntries() async {
        let scanner = RecordingScanner()
        scanner.nextResult = .snapshot(GitStatusRawScan(
            statusOutput: [
                "# branch.head main",
                "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflict.txt",
            ].joined(separator: "\u{0}"),
            operationMarker: .merge,
            submoduleParentName: nil,
            isWorktree: false,
            repositoryToplevel: "/tmp/example-repo"
        ))
        let (content, _) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        guard await awaitScanHandled(content, atLeast: 1) else { return }

        guard case .snapshot(let snapshot) = content.state else {
            Issue.record("expected a snapshot state")
            return
        }
        #expect(snapshot.operationState == .merge(conflictCount: 1))
        #expect(snapshot.conflicted == [GitStatusFileEntry(path: "conflict.txt", statusKind: .unmerged)])
    }

    @Test func notARepositoryResultProducesTheDefinedEmptyState() async {
        let scanner = RecordingScanner()
        scanner.nextResult = .notARepository
        let (content, _) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        guard await awaitScanHandled(content, atLeast: 1) else { return }
        #expect(content.state == .notARepository(path: "/tmp/example-repo"))
    }

    // MARK: - Change Directory…

    @Test func changeDirectoryRetargetsAndForcesAFreshScan() async {
        let scanner = RecordingScanner()
        scanner.nextResult = .notARepository
        let (content, box) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        guard await awaitScanHandled(content, atLeast: 1) else { return }
        let handledCountBeforeRetarget = content.handledScanResultCount

        content.changeDirectory(to: "/tmp/other-repo")
        #expect(content.directoryPath == "/tmp/other-repo")
        #expect(content.state == .loading)
        guard await awaitScanHandled(content, atLeast: handledCountBeforeRetarget + 1) else { return }
        #expect(box.created.count == 2)
        #expect(box.created[0].stopCount == 1) // old watcher released
        #expect(box.created[1].startCount == 1) // new watcher acquired
    }
}
