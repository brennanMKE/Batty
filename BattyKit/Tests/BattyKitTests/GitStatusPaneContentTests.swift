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
// `ProcessGitStatusScanner`'s lock-guarded `activeProcess` provides.

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

/// Polls until `condition()` is true or a short deadline elapses — used
/// only to synchronize with `GitStatusPaneContent`'s internally-scheduled
/// `Task`s (the debounce timer, the scan `Task`), which run asynchronously
/// relative to the test's own statements. Not a sleep-and-hope: the loop
/// exits the instant the condition is met.
@MainActor
private func waitUntil(timeoutNanoseconds: UInt64 = 15_000_000_000, _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
    while !condition(), clock.now < deadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

@MainActor
struct GitStatusPaneContentTests {

    // MARK: - Lifecycle: setup

    @Test func createdHiddenNeverAcquiresAWatcherOrScans() async {
        let scanner = RecordingScanner()
        let (content, box) = makeContent(scanner: scanner)
        content.setUp(visible: false)
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
        // it doesn't move" pattern — no further scan happens without an
        // explicit `show`, even after waiting past the debounce window.
        try? await Task.sleep(nanoseconds: 20_000_000)
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
        await waitUntil { content.state != .loading }

        content.setVisible(true) // already visible — must be a no-op
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
        await waitUntil(timeoutNanoseconds: 15_000_000_000) { scanner.scanCount > scanCountBeforeBurst }
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

        try? await Task.sleep(nanoseconds: 150_000_000)
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
