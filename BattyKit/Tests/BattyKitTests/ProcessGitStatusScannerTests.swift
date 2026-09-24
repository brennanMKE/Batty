// ProcessGitStatusScannerTests.swift

import Darwin
import Foundation
import Testing
@testable import BattyKit

/// Real, end-to-end tests against `ProcessGitStatusScanner` — spawning the
/// actual `git` binary against real temporary repositories on disk. Filed
/// in review round 1 as a gap: every other test in this area exercises the
/// pure parser or the lifecycle conformer's *seams* (test doubles); nothing
/// exercised the actual `Process`/`rev-parse` plumbing this type owns,
/// which is exactly where both round-1 blocking findings (B1 — path
/// quoting, B2 — worktree detection comparing two differently-shaped
/// paths) lived.
///
/// Each test builds its own temp directory under
/// `FileManager.default.temporaryDirectory` and removes it afterward.
@MainActor
struct ProcessGitStatusScannerTests {

    // MARK: - Fixture helpers

    private static func runGit(_ arguments: [String], in directory: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private static func makeTempDirectory() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitStatusScannerTests-\(UUID().uuidString)")
            .path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A repo with local (not global) user config and one commit, so
    /// `git commit` never depends on the test machine's own git identity.
    private static func makeRepoWithOneCommit() -> String {
        let dir = makeTempDirectory()
        runGit(["init", "-q", "-b", "main"], in: dir)
        runGit(["config", "user.email", "test@example.com"], in: dir)
        runGit(["config", "user.name", "Test"], in: dir)
        FileManager.default.createFile(atPath: dir + "/README.txt", contents: Data("hello\n".utf8))
        runGit(["add", "."], in: dir)
        runGit(["commit", "-q", "-m", "init"], in: dir)
        return dir
    }

    private static func removeTempDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Basic scan

    @Test func scanOfACleanRepoReturnsASnapshotWithTheCorrectBranch() async {
        let dir = Self.makeRepoWithOneCommit()
        defer { Self.removeTempDirectory(dir) }

        let result = await ProcessGitStatusScanner().scan(atPath: dir)
        guard case .snapshot(let raw) = result else {
            Issue.record("expected .snapshot, got \(result)")
            return
        }
        let parsed = GitStatusPorcelainParser.parse(raw.statusOutput)
        #expect(parsed.branch == "main")
        #expect(raw.isWorktree == false)
        #expect(raw.submoduleParentName == nil)
        #expect(raw.operationMarker == .none)
    }

    // MARK: - Defined non-repo / hostile-path states

    @Test func scanOfABareRepositoryReturnsNotARepository() async {
        let dir = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(dir) }
        Self.runGit(["init", "-q", "--bare"], in: dir)

        let result = await ProcessGitStatusScanner().scan(atPath: dir)
        #expect(result == .notARepository)
    }

    @Test func scanOfAMissingDirectoryReturnsNotARepository() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitStatusScannerTests-missing-\(UUID().uuidString)")
            .path
        let result = await ProcessGitStatusScanner().scan(atPath: missing)
        #expect(result == .notARepository)
    }

    @Test func scanOfAPlainDirectoryThatIsNotARepositoryReturnsNotARepository() async {
        let dir = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(dir) }
        // No `git init` — just an ordinary empty directory.
        let result = await ProcessGitStatusScanner().scan(atPath: dir)
        #expect(result == .notARepository)
    }

    // MARK: - Worktree detection (review round 1, B2)

    /// The exact regression: a `.gitStatus` pane split off a terminal
    /// `cd`'d into any subdirectory of a plain (non-worktree) checkout —
    /// the common case, since `SplitTree.makePane` inherits the source
    /// pane's cwd — must not report a false "Worktree" badge.
    @Test func scanOfAPlainSubdirectoryIsNotMisidentifiedAsAWorktree() async {
        let dir = Self.makeRepoWithOneCommit()
        defer { Self.removeTempDirectory(dir) }
        let subdir = dir + "/a/b"
        try? FileManager.default.createDirectory(atPath: subdir, withIntermediateDirectories: true)

        let rootResult = await ProcessGitStatusScanner().scan(atPath: dir)
        let subdirResult = await ProcessGitStatusScanner().scan(atPath: subdir)
        guard case .snapshot(let rootRaw) = rootResult, case .snapshot(let subdirRaw) = subdirResult else {
            Issue.record("expected both scans to succeed: root=\(rootResult) subdir=\(subdirResult)")
            return
        }
        #expect(rootRaw.isWorktree == false)
        #expect(subdirRaw.isWorktree == false)
    }

    /// Review round 3, R1 (blocking): `git status --porcelain=v2` always
    /// reports paths relative to the repository's *toplevel*, never the
    /// directory `-C` targeted. Scanning from a subdirectory and then
    /// building an absolute path from `directoryPath` (the subdirectory)
    /// instead of `raw.repositoryToplevel` silently doubles the
    /// subdirectory into the path — measured before this fix: a real
    /// 166-byte diff became 0 bytes, and a real file's composed URL
    /// stopped existing. This test scans from a subdirectory and pins
    /// both halves of the fix: `diff(atPath:)` using the resolved
    /// toplevel returns the real diff, and the toplevel-based absolute
    /// URL for the changed file actually exists on disk.
    @Test func scanFromASubdirectoryResolvesPathsRelativeToTheRepositoryToplevel() async {
        let dir = Self.makeRepoWithOneCommit()
        defer { Self.removeTempDirectory(dir) }
        let srcDir = dir + "/src"
        try? FileManager.default.createDirectory(atPath: srcDir, withIntermediateDirectories: true)
        let filePath = srcDir + "/nested.txt"
        FileManager.default.createFile(atPath: filePath, contents: Data("original\n".utf8))
        Self.runGit(["add", "."], in: dir)
        Self.runGit(["commit", "-q", "-m", "add nested file"], in: dir)
        try? "original\nmodified\n".write(toFile: filePath, atomically: true, encoding: .utf8)

        // Scan FROM the subdirectory — directoryPath would be `srcDir`,
        // not the repo root, in a real `.gitStatus` pane targeting it.
        let result = await ProcessGitStatusScanner().scan(atPath: srcDir)
        guard case .snapshot(let raw) = result else {
            Issue.record("expected .snapshot, got \(result)")
            return
        }
        let parsed = GitStatusPorcelainParser.parse(raw.statusOutput)
        guard let entry = parsed.unstaged.first(where: { $0.path.hasSuffix("nested.txt") }) else {
            Issue.record("expected an unstaged entry for the nested file; parsed unstaged=\(parsed.unstaged)")
            return
        }

        // `entry.path` is relative to `raw.repositoryToplevel`, not
        // `srcDir` — the scan's own base directory is irrelevant to how
        // porcelain paths are expressed.
        let diff = await ProcessGitStatusScanner().diff(atPath: raw.repositoryToplevel, relativeFilePath: entry.path, staged: false)
        #expect(diff?.isEmpty == false, "expected a non-empty diff using the resolved toplevel as the base; got \(String(describing: diff))")

        let composedURL = URL(fileURLWithPath: raw.repositoryToplevel).appendingPathComponent(entry.path)
        #expect(FileManager.default.fileExists(atPath: composedURL.path), "composed absolute file URL must exist: \(composedURL.path)")

        // The bug this guards against, made explicit: building the same
        // URL from the *subdirectory* `git` was invoked in (the pre-fix
        // behavior) must NOT resolve to a real file — if it did, this
        // test would not actually be exercising the regression.
        let wrongURL = URL(fileURLWithPath: srcDir).appendingPathComponent(entry.path)
        #expect(!FileManager.default.fileExists(atPath: wrongURL.path), "sanity check: the pre-fix (directoryPath-based) URL must not exist, or this test isn't exercising R1")
    }

    @Test func scanOfALinkedWorktreeIsIdentifiedAsAWorktreeAtRootAndInASubdirectory() async {
        let main = Self.makeRepoWithOneCommit()
        defer { Self.removeTempDirectory(main) }
        let worktreeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitStatusScannerTests-worktree-\(UUID().uuidString)")
            .path
        defer { Self.removeTempDirectory(worktreeDir) }
        Self.runGit(["worktree", "add", "-q", worktreeDir, "-b", "wt-branch"], in: main)

        let rootResult = await ProcessGitStatusScanner().scan(atPath: worktreeDir)
        guard case .snapshot(let rootRaw) = rootResult else {
            Issue.record("expected .snapshot at worktree root, got \(rootResult)")
            return
        }
        #expect(rootRaw.isWorktree == true)

        let subdir = worktreeDir + "/sub"
        try? FileManager.default.createDirectory(atPath: subdir, withIntermediateDirectories: true)
        let subdirResult = await ProcessGitStatusScanner().scan(atPath: subdir)
        guard case .snapshot(let subdirRaw) = subdirResult else {
            Issue.record("expected .snapshot in worktree subdirectory, got \(subdirResult)")
            return
        }
        #expect(subdirRaw.isWorktree == true)
    }

    @Test func scanOfASubmoduleReportsTheSuperprojectName() async {
        let parent = Self.makeRepoWithOneCommit()
        defer { Self.removeTempDirectory(parent) }
        let childSource = Self.makeRepoWithOneCommit()
        defer { Self.removeTempDirectory(childSource) }

        Self.runGit(["-c", "protocol.file.allow=always", "submodule", "add", "-q", childSource, "child"], in: parent)
        let submodulePath = parent + "/child"

        let result = await ProcessGitStatusScanner().scan(atPath: submodulePath)
        guard case .snapshot(let raw) = result else {
            Issue.record("expected .snapshot inside submodule, got \(result)")
            return
        }
        #expect(raw.submoduleParentName == (parent as NSString).lastPathComponent)
    }

    /// Review round 3, R2: a `git status` that fails on a *real*
    /// repository (a corrupt index, a permissions problem) must not
    /// report `.notARepository` — `rev-parse --is-inside-work-tree`
    /// already confirmed this directory *is* one; `.scanFailed` (added in
    /// round 1 for exactly this "don't lie about the tree" class) is the
    /// honest answer, carrying the captured stderr.
    @Test func scanOfARepositoryWithACorruptIndexReturnsScanFailedNotNotARepository() async {
        let dir = Self.makeRepoWithOneCommit()
        defer { Self.removeTempDirectory(dir) }
        // A truncated/corrupt index makes `git status` fail with exit 128
        // while `rev-parse --is-inside-work-tree` still succeeds — the
        // exact split this fix depends on.
        try? "corrupt".write(toFile: dir + "/.git/index", atomically: true, encoding: .utf8)

        let result = await ProcessGitStatusScanner().scan(atPath: dir)
        guard case .scanFailed(let message) = result else {
            Issue.record("expected .scanFailed for a real repo with a corrupt index, got \(result)")
            return
        }
        #expect(!message.isEmpty)
    }

    // MARK: - Real filesystem bytes (review round 1, B1)

    /// A real, on-disk non-ASCII filename, scanned end to end through the
    /// actual subprocess and parser — not just the pure-parser fixture
    /// test, which can't catch a decode step this class itself owns.
    @Test func scanHandlesARealNonASCIIFilenameEndToEnd() async {
        let dir = Self.makeRepoWithOneCommit()
        defer { Self.removeTempDirectory(dir) }
        let fileName = "café.txt"
        #expect(fileName.utf8.contains(0xC3)) // sanity: genuinely non-ASCII bytes, not literal backslash text
        FileManager.default.createFile(atPath: dir + "/" + fileName, contents: Data("x".utf8))

        let result = await ProcessGitStatusScanner().scan(atPath: dir)
        guard case .snapshot(let raw) = result else {
            Issue.record("expected .snapshot, got \(result)")
            return
        }
        let parsed = GitStatusPorcelainParser.parse(raw.statusOutput)
        #expect(parsed.untracked == [GitStatusFileEntry(path: fileName, statusKind: .untracked)])
    }

    // MARK: - diff()

    @Test func diffReturnsTheUnstagedDiffForAModifiedFile() async {
        let dir = Self.makeRepoWithOneCommit()
        defer { Self.removeTempDirectory(dir) }
        try? "hello\nworld\n".write(toFile: dir + "/README.txt", atomically: true, encoding: .utf8)

        let diff = await ProcessGitStatusScanner().diff(atPath: dir, relativeFilePath: "README.txt", staged: false)
        #expect(diff?.contains("+world") == true)
    }

    @Test func diffReturnsNilForAPathNotInTheRepo() async {
        let dir = Self.makeRepoWithOneCommit()
        defer { Self.removeTempDirectory(dir) }

        let diff = await ProcessGitStatusScanner().diff(atPath: dir, relativeFilePath: "does-not-exist.txt", staged: false)
        #expect(diff == "" || diff == nil) // git diff on a nonexistent path exits 0 with empty output
    }

    // MARK: - terminate*() are safe no-ops when nothing is running

    @Test func terminateIfRunningIsASafeNoOpWhenNothingHasEverRun() {
        let scanner = ProcessGitStatusScanner()
        scanner.terminateIfRunning() // must not crash / raise NSInvalidArgumentException
    }

    @Test func terminateAndWaitBrieflyIsASafeNoOpWhenNothingHasEverRun() {
        let scanner = ProcessGitStatusScanner()
        scanner.terminateAndWaitBriefly() // must not crash and must not block
    }

    @Test func terminateIfRunningAfterAScanCompletedIsASafeNoOp() async {
        let dir = Self.makeRepoWithOneCommit()
        defer { Self.removeTempDirectory(dir) }
        let scanner = ProcessGitStatusScanner()
        _ = await scanner.scan(atPath: dir)
        scanner.terminateIfRunning() // the process has already exited — must not crash
    }

    // MARK: - Overlapping scans
    //
    // `changeDirectory(to:)` suspends the current scan without waiting for
    // its subprocess to exit (fire-and-forget `terminateIfRunning()`) and
    // immediately starts a new one, so two `run()` calls can genuinely be
    // in flight on the same `ProcessGitStatusScanner` at once. These tests
    // register real, independently-spawned `/bin/sleep` processes through
    // the `addActiveProcess`/`removeActiveProcess` testability hooks —
    // exactly the calls `run()` itself makes around a real `git`
    // subprocess — so the tracking behavior is exercised deterministically
    // instead of racing an actual git subprocess's short, nondeterministic
    // duration.

    /// A process that runs long enough to still be alive when the test
    /// asserts on it, but that dies immediately on `SIGTERM`: `sleep` has
    /// no handler for it, so the default disposition (terminate) applies
    /// — so assertions check final state, not timing.
    private static func makeSleepProcess(seconds: Int = 30) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [String(seconds)]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        return process
    }

    @Test func terminateAndWaitBrieflyTerminatesEveryOverlappingTrackedProcess() async throws {
        let scanner = ProcessGitStatusScanner()
        let processA = Self.makeSleepProcess()
        let processB = Self.makeSleepProcess()
        try processA.run()
        try processB.run()
        defer {
            if processA.isRunning { processA.terminate() }
            if processB.isRunning { processB.terminate() }
        }

        // Simulates the exact interleaving that overlaps scans: scan B's
        // `run()` registers its process while scan A's is still tracked too.
        scanner.addActiveProcess(processA)
        scanner.addActiveProcess(processB)

        scanner.terminateAndWaitBriefly()
        // #0422: the bounded wait no longer happens synchronously inside
        // `terminateAndWaitBriefly()` — it's deferred to a background task
        // per process, so this test awaits that task deterministically
        // instead of asserting immediately after the call returns.
        await scanner.awaitPendingTeardownReapsForTesting()

        #expect(!processA.isRunning, "an older scan's process must not survive teardown")
        #expect(!processB.isRunning, "a newer, overlapping scan's process must not survive teardown")
    }

    // MARK: - #0422: teardown must not block the caller

    /// The regression this issue is about, pinned directly: a process that
    /// ignores `SIGTERM` entirely (`trap '' TERM`) used to keep
    /// `terminateAndWaitBriefly()` blocking its caller for the full 0.3s
    /// bound — and, pre-#0360, could silently escape signaling altogether.
    /// A single process, no grandchild (`exec` replaces the shell rather
    /// than leaving it as a parent of `sleep`), so there is exactly one PID
    /// for this test to track and reap — no orphan-detection subtlety about
    /// signaling a process group.
    ///
    /// `echo ready` before the `exec`, with stdout on a pipe the caller
    /// reads via `ChildProcessReadiness.waitForData(on:)`, closes a real
    /// race — without it, a
    /// test could call `terminateAndWaitBriefly()` (sending `SIGTERM`)
    /// before `sh` finished installing `trap '' TERM`, in which case the
    /// child died normally on the signal like any other process and every
    /// assertion in these tests about ignoring `SIGTERM` passed vacuously.
    private static func makeStubbornProcess() -> (process: Process, readyPipe: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; echo ready; exec sleep 60"]
        let readyPipe = Pipe()
        process.standardOutput = readyPipe
        process.standardError = Pipe()
        return (process, readyPipe)
    }

    @Test func terminateAndWaitBrieflyReturnsImmediatelyEvenWhenTheProcessIgnoresSIGTERM() async throws {
        // #0428's reap gate: held closed, the deferred reap's
        // `Task.detached` can't even start `reapAfterTerminate`, so the
        // child being alive right after `terminateAndWaitBriefly()`
        // returns is a *structural* proof the call didn't wait on the
        // reap — not a timing guess like the `elapsed < .milliseconds(50)`
        // this replaces, which could pass on a fast machine even if the
        // call secretly blocked a little.
        let gate = TestTeardownReapGate()
        defer { gate.open() } // safety net: never leave a parked waiter behind, even if an assertion above fails first
        let scanner = ProcessGitStatusScanner(teardownWaitBound: 0.2, reapGate: gate)
        let (process, readyPipe) = Self.makeStubbornProcess()
        try process.run()
        guard await ChildProcessReadiness.waitForData(on: readyPipe) else {
            Issue.record("child never signaled readiness")
            // No `defer` is registered yet at this point — release the
            // child directly so an early return here can't orphan it.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return
        }
        let pid = process.processIdentifier
        defer {
            if process.isRunning { kill(pid, SIGKILL) }
        }
        scanner.addActiveProcess(process)

        scanner.terminateAndWaitBriefly()

        // The gate's closed state is only load-bearing proof if something
        // is actually parked on it — awaiting this confirms a caller has
        // actually reached `waitUntilOpen()`, rather than assuming the
        // detached reap task got there the instant
        // `terminateAndWaitBriefly()` returns.
        guard await gate.waitForParkedWaiter() else {
            Issue.record("waitForParkedWaiter() never reached its threshold")
            return
        }

        #expect(process.isRunning, "sanity check: the child must still be alive immediately after SIGTERM, or this isn't exercising the ignore-SIGTERM path")

        gate.open()

        // The deferred reap must still actually kill it (SIGKILL
        // escalation) — teardown's "verifiably reaps its subprocesses"
        // guarantee must not be weakened by moving the wait off-main.
        await scanner.awaitPendingTeardownReapsForTesting()
        #expect(!process.isRunning, "the deferred reap must SIGKILL a process that ignored SIGTERM")

        // No orphan: confirm the OS has actually reaped the pid, not just
        // that `Process.isRunning` (a Foundation-side flag) flipped. A
        // single check, no poll: `docs/async-test-seams.md` §5 Q3 found
        // (10/10, a standalone experiment mirroring this exact reap loop)
        // that once a `Process.isRunning`-polling reap loop like
        // `reapAfterTerminate` returns, the child has already been
        // `waitpid`-ed, so `kill(pid, 0)` fails immediately with no extra
        // wait — `awaitPendingTeardownReapsForTesting()` above already
        // awaited that reap.
        #expect(kill(pid, 0) != 0, "pid \(pid) must not still be signalable after reap — orphaned process")
    }

    /// The quit-path variant: `waitForPendingTeardownSynchronously()` must
    /// itself block until the stubborn process is actually reaped (an
    /// acceptable brief block only because the app is quitting) rather than
    /// returning while the child is still alive.
    @Test func waitForPendingTeardownSynchronouslyBlocksUntilAStubbornProcessIsReaped() async throws {
        let scanner = ProcessGitStatusScanner(teardownWaitBound: 0.1)
        let (process, readyPipe) = Self.makeStubbornProcess()
        try process.run()
        guard await ChildProcessReadiness.waitForData(on: readyPipe) else {
            Issue.record("child never signaled readiness")
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return
        }
        let pid = process.processIdentifier
        defer {
            if process.isRunning { kill(pid, SIGKILL) }
        }
        scanner.addActiveProcess(process)

        scanner.terminateAndWaitBriefly()
        scanner.waitForPendingTeardownSynchronously()

        #expect(!process.isRunning, "waitForPendingTeardownSynchronously() must not return before the process is reaped")
    }

    // MARK: - #0425: the scanner registers into the shared reap registry too

    /// `waitForPendingTeardownSynchronously()` above only helps a caller
    /// that still holds a reference to this `GitStatusPaneContent`/scanner
    /// — reachable only while the owning pane is still in
    /// `AppStateStore.windows`. #0425's actual gap is a pane, tab, session,
    /// or window closed moments before quit, which has already left that
    /// tree; nothing is left to call `waitForPendingTeardownSynchronously()`
    /// on. This proves `scheduleTeardownReap` also registers with
    /// `PendingTeardownReapRegistry` (injected here, not `.shared`), so
    /// `drainSynchronously()` alone — with no `waitForPendingTeardownSynchronously()`
    /// call at all — still reaps the stubborn process.
    @Test func registryDrainReapsAStubbornProcessWithNoWaitForPendingTeardownCall() async throws {
        let registry = PendingTeardownReapRegistry()
        let scanner = ProcessGitStatusScanner(teardownWaitBound: 0.2, teardownReapRegistry: registry)
        let (process, readyPipe) = Self.makeStubbornProcess()
        try process.run()
        guard await ChildProcessReadiness.waitForData(on: readyPipe) else {
            Issue.record("child never signaled readiness")
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return
        }
        let pid = process.processIdentifier
        defer {
            if process.isRunning { kill(pid, SIGKILL) }
        }
        scanner.addActiveProcess(process)

        scanner.terminateAndWaitBriefly()
        #expect(process.isRunning, "sanity check: the child must still be alive immediately after SIGTERM, or this isn't exercising the ignore-SIGTERM path")

        registry.drainSynchronously()

        #expect(!process.isRunning, "drainSynchronously() must reap a process this scanner scheduled, even with no waitForPendingTeardownSynchronously() call")
    }

    @Test func terminateIfRunningSignalsEveryOverlappingTrackedProcess() throws {
        let scanner = ProcessGitStatusScanner()
        let processA = Self.makeSleepProcess()
        let processB = Self.makeSleepProcess()
        try processA.run()
        try processB.run()
        defer {
            if processA.isRunning { processA.terminate() }
            if processB.isRunning { processB.terminate() }
        }

        scanner.addActiveProcess(processA)
        scanner.addActiveProcess(processB)

        scanner.terminateIfRunning()
        processA.waitUntilExit()
        processB.waitUntilExit()

        #expect(!processA.isRunning)
        #expect(!processB.isRunning)
    }

    /// The root-cause scenario, pinned directly: a scan that finishes and
    /// clears its own slot (`removeActiveProcess`, mirroring `run()`'s own
    /// `defer`) must not clobber a different, still-running scan's entry.
    @Test func aCompletedScansCleanupDoesNotClobberAnotherStillRunningScan() throws {
        let scanner = ProcessGitStatusScanner()
        let processA = Self.makeSleepProcess()
        let processB = Self.makeSleepProcess()
        try processA.run()
        try processB.run()
        defer {
            if processA.isRunning { processA.terminate() }
            if processB.isRunning { processB.terminate() }
        }

        scanner.addActiveProcess(processA)
        scanner.addActiveProcess(processB)

        // Scan A "finishes" and its own `run()` clears only its own entry.
        scanner.removeActiveProcess(processA)

        scanner.terminateIfRunning()
        processB.waitUntilExit()

        #expect(!processB.isRunning, "the still-tracked process must still be signaled")
        #expect(processA.isRunning, "the untracked (already-cleared) process must be untouched by terminate calls")
    }
}
