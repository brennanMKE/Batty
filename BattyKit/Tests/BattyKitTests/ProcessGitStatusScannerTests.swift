// ProcessGitStatusScannerTests.swift

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

    @Test func terminateAndWaitBrieflyTerminatesEveryOverlappingTrackedProcess() throws {
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

        #expect(!processA.isRunning, "an older scan's process must not survive teardown")
        #expect(!processB.isRunning, "a newer, overlapping scan's process must not survive teardown")
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
