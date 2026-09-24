// GitStatusPaneContentTests.swift

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

private nonisolated final class RecordingScanner: GitStatusScanning, @unchecked Sendable {
    private(set) var scanCount = 0
    private(set) var terminateIfRunningCount = 0
    private(set) var terminateAndWaitBrieflyCount = 0

    /// What the *next* `scan(atPath:)` call returns. Settable from a test
    /// before triggering a scan.
    var nextResult: GitStatusScanResult = .notARepository
    /// Optional artificial delay before `scan(atPath:)` resolves — lets a
    /// test hide the pane (or otherwise change phase) while a scan is
    /// still in flight, to verify the stale result gets discarded rather
    /// than applied (the `generation` guard in
    /// `GitStatusPaneContent.handleScanResult`).
    var scanDelayNanoseconds: UInt64 = 0

    func scan(atPath path: String) async -> GitStatusScanResult {
        scanCount += 1
        if scanDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: scanDelayNanoseconds)
        }
        return nextResult
    }

    func diff(atPath path: String, relativeFilePath: String, staged: Bool) async -> String? {
        "diff for \(relativeFilePath)"
    }

    func terminateIfRunning() { terminateIfRunningCount += 1 }
    func terminateAndWaitBriefly() { terminateAndWaitBrieflyCount += 1 }
}

@MainActor
private func makeContent(
    scanner: RecordingScanner,
    debounceNanoseconds: UInt64 = 5_000_000
) -> (GitStatusPaneContent, WatcherBox) {
    let box = WatcherBox()
    let content = GitStatusPaneContent(
        directoryPath: "/tmp/example-repo",
        scanner: scanner,
        watcherFactory: { _, onEvent in box.make(onEvent: onEvent) },
        debounceNanoseconds: debounceNanoseconds
    )
    return (content, box)
}

/// Polls until `condition()` is true or a generous deadline elapses — used
/// only to synchronize with `GitStatusPaneContent`'s internally-scheduled
/// `Task`s (the debounce timer, the scan `Task`), which run asynchronously
/// relative to the test's own statements. Not a sleep-and-hope: the loop
/// exits the instant the condition is met.
///
/// 15s, back down from round 2's 30s (review round 3, N1). 30s was this
/// suite's answer to *misattribution* — a starved wait failing on an
/// unrelated downstream `#expect` instead of on itself — but round 2 also
/// added loud `Issue.record` on timeout, which fixes misattribution
/// directly regardless of deadline size. What actually reduces how often
/// this deadline is threatened is `.serialized` (below), confirmed by
/// measurement to remove the specific starvation this suite was hitting.
/// With that lever doing the real work, a large ceiling only taxes the
/// case that matters most for fast feedback: a genuine hang, which this
/// suite's 15 call sites can each cost up to 15s (225s worst case) to
/// report, vs. 30s each (450s) before this change — no run that finishes
/// under load costs anything either way, since this is a ceiling, not a
/// per-call charge.
///
/// Polls every 10ms (not the original 2ms) — review round 2, N4: tight
/// polling on the MainActor is itself a small contributor to the
/// contention this issue is about, and 2ms bought no responsiveness this
/// suite's own workloads (sub-100ms in the typical case) actually needed.
///
/// Records a loud `Issue` on timeout (review round 2, B2's follow-up)
/// rather than silently returning: a caller with a downstream `#expect`
/// after this call used to see that unrelated expectation fail when the
/// real problem was this wait never resolving — under extreme contention,
/// misattributing a starved wait as a behavioral regression is exactly
/// the failure mode this issue exists to eliminate.
@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 15_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
    while !condition(), clock.now < deadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    if !condition() {
        Issue.record(
            "waitUntil timed out after \(timeoutNanoseconds / 1_000_000)ms without the condition becoming true",
            sourceLocation: sourceLocation
        )
    }
}

/// `.serialized` (review round 2, B3): empirically, not on the theory that
/// it protects shared mutable state — this suite and `ProcessStatusPaneContentTests`
/// own no state shared with any other suite, so that specific #0383 finding
/// ("`.serialized` does not protect cross-suite shared state") does not
/// apply here either way. What was measured: under ~30-process CPU
/// contention, this suite (and `ProcessStatusPaneContentTests`) failed the
/// majority of their timing-sensitive tests when running unserialized
/// alongside the rest of the ~1478-test parallel batch, and passed cleanly,
/// repeatedly, once serialized — reducing how many of this suite's own
/// `Task`s can be mid-flight and contending for the MainActor at once is
/// a real, measured lever on the starvation this issue is about, distinct
/// from (and not contradicted by) the shared-state finding.
@Suite(.serialized)
@MainActor
struct GitStatusPaneContentTests {

    // MARK: - Lifecycle: setup

    @Test func createdHiddenNeverAcquiresAWatcherOrScans() async {
        let scanner = RecordingScanner()
        let (content, box) = makeContent(scanner: scanner)
        content.setUp(visible: false)
        // Review round 3, B2: a *synchronous* mutation that makes
        // `setUp(visible: false)` call `activate()` unconditionally is
        // already caught with no wait at all (M1 in this issue's mutation
        // table) — but a *deferred* variant (`Task { self.activate() }`
        // scheduled from the correct-looking synchronous path) is not: it
        // schedules a `Task` this instant-check can't see yet. This real
        // wait is what actually exercises that path; a synchronous-only
        // mutation made round 2's deletion of it look safe when it wasn't.
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(content.lifecyclePhase == .suspended)
        #expect(box.created.isEmpty)
        #expect(scanner.scanCount == 0)
    }

    @Test func createdVisibleAcquiresAWatcherAndScansOnce() async {
        let scanner = RecordingScanner()
        scanner.nextResult = .notARepository
        let (content, box) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        await waitUntil { content.state != .loading }
        #expect(content.lifecyclePhase == .active)
        #expect(box.created.count == 1)
        #expect(box.current?.startCount == 1)
        #expect(scanner.scanCount == 1)
    }

    // MARK: - Lifecycle: show/hide

    @Test func hidingAnActivePaneStopsTheWatcherAndSuspendsToZeroPeriodicWork() async {
        let scanner = RecordingScanner()
        let (content, box) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        await waitUntil { content.state != .loading }

        content.setVisible(false)
        #expect(content.lifecyclePhase == .suspended)
        #expect(box.current?.stopCount == 1)
        #expect(scanner.terminateIfRunningCount == 1)
        #expect(scanner.terminateAndWaitBrieflyCount == 0)

        let scanCountAtHide = scanner.scanCount
        // Zero periodic work while suspended: mirrors
        // `PaneContentLifecycleTests`'s own "count attempted work, observe
        // it doesn't move" pattern. This real wait is load-bearing, not
        // decorative (review round 2, B1): a regression that gives
        // `activate()` an uncancelled periodic poller — the textbook
        // "periodic work survives suspend" bug `docs/pane-view-lifecycle.md`
        // §4 exists to prevent — leaks a `Task` that is not held in
        // `debounceTask`/`scanTask` at all, so no synchronous/structural
        // check on this type's stored properties can ever observe it;
        // letting real time pass and re-reading `scanner.scanCount` can,
        // for any leaked poller whose own period is inside this wait's
        // window (review round 3, N3 — a fixed window is necessarily
        // cadence-dependent: a leaked poller firing slower than this
        // still escapes, the same limit every fixed-window wait in this
        // suite has). Without this wait the assertion below is `x == x`
        // and cannot fail for any reason, regardless of cadence.
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(scanner.scanCount == scanCountAtHide)
    }

    @Test func showingAfterHidingAcquiresAFreshWatcherAndForcesExactlyOneRefresh() async {
        let scanner = RecordingScanner()
        let (content, box) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        await waitUntil { content.state != .loading }
        content.setVisible(false)
        let scanCountAtHide = scanner.scanCount

        content.setVisible(true)
        await waitUntil { box.created.count >= 2 }
        #expect(content.lifecyclePhase == .active)
        // Suspended means fully torn down, not paused — showing again
        // acquires a brand-new watcher instance rather than restarting the
        // released one.
        #expect(box.created.count == 2)
        #expect(box.created[0].stopCount == 1)
        #expect(box.created[1].startCount == 1)
        await waitUntil { scanner.scanCount > scanCountAtHide }
        #expect(scanner.scanCount == scanCountAtHide + 1)
    }

    @Test func redundantShowDoesNotDoubleAcquireOrDoubleRefresh() async {
        let scanner = RecordingScanner()
        let (content, box) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        // Wait on the *full* precondition, not just `state != .loading`:
        // `handleScanResult` sets `isRefreshing = false` before it sets
        // `state`, in the same synchronous call, so this never adds a real
        // race — but folding it into the wait means a starved machine that
        // hasn't finished the initial scan yet fails *here*, on the wait,
        // rather than downstream on `isRefreshing == false` reading like a
        // behavioral regression (review round 2, B2).
        await waitUntil { content.state != .loading && content.isRefreshing == false }

        content.setVisible(true) // already visible — must be a no-op
        // `isRefreshing` is an instant check for a *synchronous*
        // regression: `requestScan()` sets it to `true` synchronously,
        // before ever reaching the `await` inside its scan `Task` — so a
        // no-op path that regressed into calling `activate()` directly
        // flips this immediately, no wait required.
        #expect(content.isRefreshing == false)
        // Review round 3, B2: that instant check alone is not enough — a
        // *deferred* variant of the same regression (`Task { self
        // .activate() }` scheduled from the no-op path, rather than
        // calling it directly) schedules work the instant check above
        // can't see yet. This real wait is what actually exercises that
        // path; round 2 deleted it on the strength of a mutation
        // (synchronous-only) that couldn't have shown the gap.
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(box.created.count == 1)
        #expect(box.current?.startCount == 1)
        #expect(scanner.scanCount == 1)
    }

    // MARK: - Lifecycle: teardown

    @Test func tearDownFromActiveReleasesTheWatcherSynchronouslyAndWaitsOnTheScanner() async {
        let scanner = RecordingScanner()
        let (content, box) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        await waitUntil { content.state != .loading }

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
        await waitUntil { content.state != .loading }

        content.tearDown()
        content.tearDown()
        #expect(box.current?.stopCount == 1)
        #expect(scanner.terminateAndWaitBrieflyCount == 1)
    }

    @Test func setVisibleAfterTearDownIsRejectedAndDoesNothing() async {
        let scanner = RecordingScanner()
        let (content, box) = makeContent(scanner: scanner)
        content.setUp(visible: false)
        content.tearDown()

        content.setVisible(true)
        // Review round 3, B2: `.rejected` taking the synchronous
        // `case .noOp, .rejected: break` branch rules out a *direct*
        // `activate()` call with no wait — but not a *deferred* one
        // (`Task { self.activate() }` scheduled from that branch), which
        // this real wait is what actually exercises.
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(box.created.isEmpty)
        #expect(scanner.scanCount == 0)
        #expect(content.lifecyclePhase == .tornDown)
    }

    // MARK: - Debounce coalescing

    @Test func rapidWatcherEventsCoalesceIntoOneScanAfterTheDebounceWindow() async {
        let scanner = RecordingScanner()
        let (content, box) = makeContent(scanner: scanner, debounceNanoseconds: 60_000_000)
        content.setUp(visible: true)
        await waitUntil { content.state != .loading } // the initial "show" refresh

        let scanCountBeforeBurst = scanner.scanCount
        for _ in 0..<5 {
            box.current?.trigger()
        }
        // Still within the debounce window — nothing new yet.
        #expect(scanner.scanCount == scanCountBeforeBurst)

        // A generous bound — under the full test suite's parallel load,
        // dozens of other `@MainActor` suites contend for the same serial
        // executor this debounce `Task` runs on, so its actual firing can
        // lag well past its 60ms nominal delay. The assertion below is
        // about *coalescing* (exactly one scan, not five), not about
        // hitting a tight deadline.
        await waitUntil { scanner.scanCount > scanCountBeforeBurst }
        #expect(scanner.scanCount == scanCountBeforeBurst + 1)
    }

    @Test func hidingDuringAnInFlightScanDiscardsItsResult() async {
        let scanner = RecordingScanner()
        scanner.scanDelayNanoseconds = 100_000_000
        scanner.nextResult = .notARepository
        let (content, _) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        // The scan is now in flight (100ms delay) — hide before it resolves.
        content.setVisible(false)

        // Await the in-flight scan's actual resolution instead of sleeping
        // longer than its known 100ms delay: `handledScanResultCount`
        // increments at the top of `handleScanResult`, before the
        // generation/phase guard that discards this particular result, so
        // this reliably fires the instant the stale result is (correctly)
        // thrown away — no fixed margin to tune against scheduler jitter.
        await waitUntil { content.handledScanResultCount >= 1 }
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
        await waitUntil {
            if case .snapshot = content.state { return true }
            return false
        }

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
        await waitUntil {
            if case .snapshot = content.state { return true }
            return false
        }

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
        await waitUntil {
            if case .notARepository = content.state { return true }
            return false
        }
        #expect(content.state == .notARepository(path: "/tmp/example-repo"))
    }

    // MARK: - Change Directory…

    @Test func changeDirectoryRetargetsAndForcesAFreshScan() async {
        let scanner = RecordingScanner()
        scanner.nextResult = .notARepository
        let (content, box) = makeContent(scanner: scanner)
        content.setUp(visible: true)
        await waitUntil { content.state != .loading }
        let scanCountBeforeRetarget = scanner.scanCount

        content.changeDirectory(to: "/tmp/other-repo")
        #expect(content.directoryPath == "/tmp/other-repo")
        #expect(content.state == .loading)
        await waitUntil { scanner.scanCount > scanCountBeforeRetarget }
        #expect(box.created.count == 2)
        #expect(box.created[0].stopCount == 1) // old watcher released
        #expect(box.created[1].startCount == 1) // new watcher acquired
    }
}
