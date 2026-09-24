// GitStatusPaneContent.swift

import CoreServices
import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "GitStatusPaneContent")

// MARK: - Injectable seams

/// Watches a directory tree for changes and calls back once per coalesced
/// burst. Production conformer: `FSEventsGitStatusWatcher`. A test double
/// (in `BattyKitTests`) records start/stop calls without touching the
/// filesystem — the same seam-and-ledger shape
/// `PaneContentLifecycleTests.RecordingPaneContent` uses for the generic
/// state machine, applied here to this concrete kind's actual resource.
public protocol GitStatusWatching: AnyObject, Sendable {
    nonisolated func start()
    nonisolated func stop()
}

/// The result of one scan: either the resolved path is not a git
/// repository, a raw scan the caller composes (with
/// `GitStatusPorcelainParser`) into a `GitStatusSnapshot`, or the scan ran
/// but its output could not be trusted (review round 1, B1 — `git status`'s
/// stdout was not decodable as UTF-8). The last case exists specifically so
/// that failure surfaces as a visible, distinct state rather than silently
/// falling back to an empty string and reporting a clean working tree for a
/// repository that is not actually clean.
public nonisolated enum GitStatusScanResult: Sendable, Equatable {
    case notARepository
    case snapshot(GitStatusRawScan)
    case scanFailed(String)
}

/// Everything one scan produces before parsing: the porcelain stdout, plus
/// the cheap one-time-shaped `rev-parse`/marker-file facts
/// (`docs/design/git-status-view.md` §1, §4). Re-derived on every scan
/// rather than cached after the first success — a deliberate simplification
/// from the design's "run once at setup" optimization; see this issue's
/// `## Gotchas` for why that's an acceptable trade (these are cheap
/// `rev-parse` calls and `FileManager` existence checks, not `git status`
/// itself, so the extra cost per refresh is negligible).
public nonisolated struct GitStatusRawScan: Sendable, Equatable {
    public var statusOutput: String
    public var operationMarker: GitOperationMarker
    public var submoduleParentName: String?
    public var isWorktree: Bool
    /// The repository's working-tree root, from `git rev-parse
    /// --show-toplevel` (review round 3, R1). `git status --porcelain=v2`
    /// always reports paths relative to this directory, regardless of
    /// what `-C` was given — a fact the pre-round-3 code missed entirely,
    /// treating the resolved (possibly-subdirectory) `directoryPath` as
    /// the base for every porcelain path it read back. This field is the
    /// correct base for `diff(atPath:)` and for building an absolute file
    /// URL from a `GitStatusFileEntry.path`; `repoName` is derived from
    /// its last path component, not `directoryPath`'s.
    public var repositoryToplevel: String

    public init(statusOutput: String, operationMarker: GitOperationMarker, submoduleParentName: String?, isWorktree: Bool, repositoryToplevel: String) {
        self.statusOutput = statusOutput
        self.operationMarker = operationMarker
        self.submoduleParentName = submoduleParentName
        self.isWorktree = isWorktree
        self.repositoryToplevel = repositoryToplevel
    }
}

/// Runs `git status` (and the cheap shape checks) against a directory and
/// reports the result, off the main thread. Production conformer:
/// `ProcessGitStatusScanner`, spawning the user's real `git` resolved via
/// `$PATH` (`docs/design/git-status-view.md` §4). A test double (in
/// `BattyKitTests`) returns canned results with no subprocess.
public protocol GitStatusScanning: Sendable {
    nonisolated func scan(atPath path: String) async -> GitStatusScanResult
    /// Fetches a diff for one file (`git diff` for unstaged, `git diff
    /// --cached` for staged) — the inline diff peek
    /// (`docs/design/git-status-view.md` §2.4). `nil` on any failure.
    nonisolated func diff(atPath path: String, relativeFilePath: String, staged: Bool) async -> String?
    /// Sends `SIGTERM` to every subprocess currently in flight (a scan, a
    /// diff, or both at once — `diff(atPath:)` can run alongside a scan),
    /// without waiting for any of them to exit. Used by `setVisible(false)`
    /// — hiding carries no synchronous teardown requirement
    /// (`docs/pane-view-lifecycle.md` §5).
    nonisolated func terminateIfRunning()
    /// Sends `SIGTERM` to every subprocess currently in flight, then waits
    /// with a short, fixed bound (not an unbounded `waitUntilExit()`) for
    /// all of them to actually exit. Used by `tearDown()` only — the one
    /// call site that carries the synchronous-teardown obligation
    /// (`docs/pane-view-lifecycle.md` §5's "bounded, deliberately, not
    /// unbounded" reasoning).
    nonisolated func terminateAndWaitBriefly()
}

// MARK: - Production watcher

/// Real `FSEventStream`-backed conformer of `GitStatusWatching`. Recurses
/// into the whole directory tree under `path` by construction — FSEvents'
/// own behavior, not something this type opts into — coalescing many rapid
/// filesystem changes into batched callbacks at the OS level before this
/// class ever sees them (`docs/design/git-status-view.md` §4). The
/// stream's own `latency` (0.15s) is OS-level micro-batching, layered under
/// `GitStatusPaneContent`'s own 400ms software debounce, not a replacement
/// for it — the two guard against different noise sources.
public nonisolated final class FSEventsGitStatusWatcher: GitStatusWatching, @unchecked Sendable {
    private let path: String
    private let onEvent: @MainActor () -> Void
    private var stream: FSEventStreamRef?

    public init(path: String, onEvent: @escaping @MainActor () -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    public func start() {
        guard stream == nil else { return }
        let pathsToWatch = [path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, clientCallBackInfo, _, _, _, _ in
                guard let clientCallBackInfo else { return }
                let watcher = Unmanaged<FSEventsGitStatusWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
                // FSEventStreamSetDispatchQueue below pins this callback to
                // the main queue, so this is always already running on the
                // main actor's executor — assumeIsolated documents that
                // fact rather than hopping through a Task.
                MainActor.assumeIsolated {
                    watcher.onEvent()
                }
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        ) else {
            logger.error("watcher: FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        stream = created
        logger.info("watcher: started")
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        logger.info("watcher: stopped")
    }

    deinit {
        // Belt-and-suspenders: `GitStatusPaneContent.tearDown()` already
        // calls `stop()` explicitly and synchronously (the #0289 lesson —
        // a conformer must not depend on `deinit` timing), so this should
        // always be a no-op by the time it runs.
        stop()
    }
}

// MARK: - Production scanner

/// Real `git`-subprocess-backed conformer of `GitStatusScanning`. Spawns
/// `git` via `/usr/bin/env` so it resolves through `$PATH` — the user's
/// real `git`, config, and hooks
/// (`docs/design/git-status-view.md` §4's "consistency with the terminal
/// the user is already looking at" reasoning).
public nonisolated final class ProcessGitStatusScanner: GitStatusScanning, @unchecked Sendable {
    /// `stdoutData` is kept raw (not eagerly decoded to `String`) so a
    /// caller that needs to *know* whether decoding failed — the status
    /// scan does, per B1's "make that a failure state" — can distinguish
    /// "decode failed" from "decoded to an empty string" instead of both
    /// collapsing to `""` via a silent `?? ""`.
    private struct ProcessOutcome {
        var exitCode: Int32
        var stdoutData: Data
        var stderr: String
    }

    /// Keyed by identity, not a single slot: `changeDirectory(to:)` can
    /// suspend one scan (fire-and-forget `terminate()`, no wait) and start
    /// a new one before the old subprocess has actually exited, and
    /// `diff(atPath:)` can run alongside a scan (or alongside another
    /// diff, on a quick hide/show), so more than one `run()` call can be
    /// in flight on this scanner at once. Each `run()` removes only its
    /// own entry on exit, so an older call's completion can never clobber
    /// a still-running one's entry.
    private let lock = NSLock()
    private var activeProcesses: [ObjectIdentifier: Process] = [:]

    public init() {}

    public func scan(atPath path: String) async -> GitStatusScanResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                continuation.resume(returning: self.performScan(atPath: path))
            }
        }
    }

    public func diff(atPath path: String, relativeFilePath: String, staged: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                // `--literal-pathspecs` (a one-liner while in here, per
                // review round 3's follow-up list): without it, `--
                // relativeFilePath` is still parsed as a pathspec, not a
                // literal path, so a filename containing `*` or `?` globs
                // instead of naming exactly that file.
                var arguments = ["--literal-pathspecs", "-C", path, "diff", "--no-color"]
                if staged { arguments.append("--cached") }
                arguments.append(contentsOf: ["--", relativeFilePath])
                let outcome = self.run(arguments)
                let text = outcome.exitCode == 0 ? String(data: outcome.stdoutData, encoding: .utf8) : nil
                continuation.resume(returning: text)
            }
        }
    }

    public func terminateIfRunning() {
        for process in snapshotActiveProcesses() where process.isRunning {
            process.terminate()
        }
    }

    public func terminateAndWaitBriefly() {
        let processes = snapshotActiveProcesses().filter { $0.isRunning }
        guard !processes.isEmpty else { return }
        for process in processes {
            process.terminate()
        }
        let deadline = Date().addingTimeInterval(0.3)
        while processes.contains(where: { $0.isRunning }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if processes.contains(where: { $0.isRunning }) {
            logger.warning("teardown: git subprocess did not exit within the bounded wait; abandoning wait rather than blocking indefinitely")
        }
    }

    // MARK: - Off-main-thread scan implementation

    private func performScan(atPath path: String) -> GitStatusScanResult {
        // `--path-format=absolute` (review round 1, B2) is load-bearing for
        // `isWorktree`, not cosmetic. Without it, `--git-dir` prints a path
        // relative to the invocation's cwd (`.git` from the repo root,
        // `../../.git` from a subdirectory two levels down) while
        // `--git-common-dir` — verified on git 2.50.1 — always prints the
        // *same* relative-or-absolute form the working-tree-root case
        // happens to produce for `--git-dir` (`.git`), so a plain-checkout
        // pane split off a terminal `cd`'d into any subdirectory of the
        // repo (the common case — `SplitTree.makePane` inherits the
        // source's cwd) compared two *differently shaped* strings for the
        // same directory and reported a false "Worktree" badge. Forcing
        // both to absolute makes the comparison meaningful: equal for a
        // plain checkout regardless of which subdirectory it was resolved
        // from, unequal only for an actual linked worktree (verified: a
        // linked worktree's `--git-dir` is `<main>/.git/worktrees/<name>`
        // while `--git-common-dir` is `<main>/.git`, absolute or not).
        // `--show-toplevel` (review round 3, R1) is load-bearing, not
        // cosmetic: `git status --porcelain=v2` always reports paths
        // relative to the repository's working-tree root, regardless of
        // what `-C` was given — a fact the pre-round-3 code missed
        // entirely, treating `directoryPath` (which can be a subdirectory
        // of the repo — the common case for a pane split off a terminal
        // `cd`'d below the root) as that base. Measured, same repo, only
        // `directoryPath` differing: from the root, a file's diff was 166
        // bytes and its file URL existed; from a subdirectory, the same
        // file's diff came back empty and the URL didn't exist, because
        // `directoryPath + entry.path` silently doubled the subdirectory
        // into the path. `repositoryToplevel` below is the fix's payload;
        // `GitStatusPaneContent.repositoryToplevelOrDirectoryPath` and the
        // view's `absoluteFileURL(for:)` are what consume it.
        //
        // **Field order is deliberate, not incidental (review round 3's
        // order caveat).** `--show-superproject-working-tree` prints
        // *nothing at all* — not even a blank line — outside a submodule,
        // so whichever flag comes after it shifts position depending on
        // submodule-ness. Placing `--show-toplevel` *before* it keeps
        // `lines[3]` fixed regardless; only the always-last, always-
        // conditionally-present superproject line needs the `lines.count
        // > 4` guard below.
        let shape = run([
            "-C", path, "rev-parse", "--path-format=absolute",
            "--is-inside-work-tree", "--git-dir", "--git-common-dir",
            "--show-toplevel", "--show-superproject-working-tree",
        ])
        guard shape.exitCode == 0, let shapeText = String(data: shape.stdoutData, encoding: .utf8) else {
            return .notARepository
        }
        let lines = shapeText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 4, lines[0] == "true" else { return .notARepository }
        let gitDir = lines[1]
        let gitCommonDir = lines[2]
        let toplevel = lines[3]
        let superprojectPath = lines.count > 4 ? lines[4] : ""

        let isWorktree = gitDir != gitCommonDir
        let submoduleParentName = superprojectPath.isEmpty ? nil : (superprojectPath as NSString).lastPathComponent
        let operationMarker = Self.detectOperationMarker(absoluteGitDir: gitDir)

        // `-z` (review round 1, B1) disables porcelain v2's path quoting
        // entirely and switches every record's terminator to NUL — see
        // `GitStatusPorcelainParser`'s own doc comment for why the
        // un-quoted line-based parsing this replaced was a real defect,
        // not a style choice.
        let status = run(["--no-optional-locks", "-C", path, "status", "--porcelain=v2", "--branch", "--show-stash", "-z"])
        guard status.exitCode == 0 else {
            // Review round 3, R2: a `git status` that fails on a *real*
            // repository (a corrupt index, a permissions problem) must not
            // report `.notARepository` — that is a specific, different
            // claim ("this directory isn't a repo at all") this scan has
            // no basis for once `rev-parse` already confirmed
            // `is-inside-work-tree == true` above. `.scanFailed` — added
            // in round 1 for exactly this "don't silently lie about the
            // tree" class — is the honest answer, carrying the stderr
            // this function already captures but, before this fix, only
            // logged.
            logger.error("scan: git status failed exit=\(status.exitCode, privacy: .public) stderr=\(status.stderr, privacy: .public)")
            let message = status.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .scanFailed(message.isEmpty ? "git status exited \(status.exitCode)" : message)
        }
        // A path byte sequence that isn't valid UTF-8 must surface as a
        // visible failure, not silently decode to "" and report a clean
        // working tree for a repository that is not actually clean
        // (review round 1, B1's second finding).
        guard let statusOutput = String(data: status.stdoutData, encoding: .utf8) else {
            logger.error("scan: git status output was not valid UTF-8")
            return .scanFailed("git status produced output that could not be decoded as UTF-8")
        }

        return .snapshot(GitStatusRawScan(
            statusOutput: statusOutput,
            operationMarker: operationMarker,
            submoduleParentName: submoduleParentName,
            isWorktree: isWorktree,
            repositoryToplevel: toplevel
        ))
    }

    private static func detectOperationMarker(absoluteGitDir: String) -> GitOperationMarker {
        let fm = FileManager.default
        let dir = absoluteGitDir as NSString
        if fm.fileExists(atPath: dir.appendingPathComponent("rebase-merge"))
            || fm.fileExists(atPath: dir.appendingPathComponent("rebase-apply")) {
            return .rebase
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("CHERRY_PICK_HEAD")) {
            return .cherryPick
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("MERGE_HEAD")) {
            return .merge
        }
        return .none
    }

    private func run(_ arguments: [String]) -> ProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        addActiveProcess(process)
        defer { removeActiveProcess(process) }

        do {
            try process.run()
        } catch {
            logger.error("run: failed to launch git \(arguments.joined(separator: " "), privacy: .private): \(String(describing: error), privacy: .public)")
            return ProcessOutcome(exitCode: -1, stdoutData: Data(), stderr: "\(error)")
        }

        // Read fully before waiting: a pipe's buffer can fill while the
        // child blocks on a full write and the parent blocks on
        // waitUntilExit(), a classic Process deadlock. Reading to EOF first
        // (which happens when the child exits and closes its end) avoids it.
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessOutcome(
            exitCode: process.terminationStatus,
            stdoutData: outData,
            // Diagnostic-only — logged, never shown to the user or parsed
            // — so a lossy decode here (unlike stdout's) is acceptable.
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Testability hook only (`internal`, reached via `@testable import` in
    /// `BattyKitTests`) — lets a test register a real, independently-spawned
    /// `Process` (e.g. `/bin/sleep`) as if it were mid-`run()`, so overlap
    /// and compare-and-clear behavior can be exercised deterministically
    /// without racing an actual `git` subprocess's short, nondeterministic
    /// duration.
    func addActiveProcess(_ process: Process) {
        lock.lock()
        activeProcesses[ObjectIdentifier(process)] = process
        lock.unlock()
    }

    /// Testability hook only — see `addActiveProcess(_:)`.
    func removeActiveProcess(_ process: Process) {
        lock.lock()
        activeProcesses.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    private func snapshotActiveProcesses() -> [Process] {
        lock.lock()
        defer { lock.unlock() }
        return Array(activeProcesses.values)
    }
}

// MARK: - GitStatusPaneContent

/// Read-only, live view state for a `.gitStatus` Pane
/// (`docs/design/git-status-view.md`). Model-owned — hung off
/// `PaneRuntime.content` (cast at the read site, `PaneView.nonTerminalContent`)
/// the way `TabRuntime.terminal` hangs off a Tab
/// (`docs/pane-view-lifecycle.md` §5's "the conformer is model-owned,
/// not view-owned") — so it survives SwiftUI view churn and is reachable
/// from `WindowRuntime.hidePane`/`showPane`/`tearDownNonTerminalContent`
/// without depending on any view's lifetime.
///
/// Conforms to `PaneContentLifecycle` via a `PaneLifecycleController`
/// exactly as `docs/pane-view-lifecycle.md` §6 prescribes: `setUp`
/// resolves initial visibility without doing work it would immediately
/// suspend; `setVisible(false)` releases the watcher and debounce timer to
/// true zero, not merely pausing them; `setVisible(true)` re-acquires the
/// watcher and forces exactly one refresh; `tearDown()` releases
/// everything synchronously, idempotently, before returning.
@Observable
public final class GitStatusPaneContent: PaneContentLifecycle {
    /// Frozen at creation (`docs/design/git-status-view.md` §1) — the only
    /// way this changes is `changeDirectory(to:)`, an explicit user action
    /// via the "Change Directory…" picker.
    public private(set) var directoryPath: String

    public private(set) var state: GitStatusPaneState = .loading
    public private(set) var isRefreshing = false

    /// Which file (by `GitStatusFileEntry.id`) has its inline diff peek
    /// open, and the diff text once loaded. `docs/design/git-status-view.md`
    /// §2.4: selecting a different file replaces the peek rather than
    /// stacking multiple.
    public private(set) var selectedEntryID: String?
    public private(set) var diffText: String?
    public private(set) var isDiffLoading = false

    private let controller = PaneLifecycleController()
    public var lifecyclePhase: PaneLifecyclePhase { controller.phase }

    private let scanner: any GitStatusScanning
    private let watcherFactory: (String, @escaping @MainActor () -> Void) -> any GitStatusWatching
    /// Debounce window (`docs/design/git-status-view.md` §4: 400ms).
    /// Injectable so `GitStatusPaneContentTests` can exercise real
    /// debounce-coalescing behavior without a real 400ms wait per test.
    private let debounceNanoseconds: UInt64
    private var watcher: (any GitStatusWatching)?
    private var debounceTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var isScanning = false
    private var pendingRescanRequested = false

    /// Testability hook only (`internal`, reached via `@testable import` in
    /// `BattyKitTests`) — counts every `handleScanResult` call, including
    /// ones the generation/phase guard below discards. Lets a test that
    /// hides the pane mid-scan await the in-flight scan's actual
    /// resolution deterministically (`await waitUntil { content
    /// .handledScanResultCount >= 1 }`) instead of sleeping a fixed real
    /// duration chosen to outlast the scanner double's injected delay,
    /// which either over-waits on a fast machine or under-waits on a
    /// loaded one.
    @ObservationIgnored private(set) var handledScanResultCount = 0

    /// Bumped on every `activate`/`suspend`/`changeDirectory` so a
    /// debounce/scan `Task` scheduled before a phase change can recognize
    /// it's stale and decline to act on a result nobody wants anymore.
    private var generation = 0

    public init(
        directoryPath: String,
        scanner: any GitStatusScanning = ProcessGitStatusScanner(),
        watcherFactory: @escaping (String, @escaping @MainActor () -> Void) -> any GitStatusWatching = { path, onEvent in
            FSEventsGitStatusWatcher(path: path, onEvent: onEvent)
        },
        debounceNanoseconds: UInt64 = 400_000_000
    ) {
        self.directoryPath = directoryPath
        self.scanner = scanner
        self.watcherFactory = watcherFactory
        self.debounceNanoseconds = debounceNanoseconds
    }

    // MARK: PaneContentLifecycle

    public func setUp(visible: Bool) {
        let result = controller.apply(.setUp(visible: visible))
        guard case .applied(_, let to) = result else { return }
        logger.info("setUp path=\(self.directoryPath, privacy: .private) visible=\(visible, privacy: .public) phase=\(to.rawValue, privacy: .public)")
        if to == .active {
            activate()
        }
    }

    public func setVisible(_ visible: Bool) {
        let result = controller.apply(visible ? .show : .hide)
        switch result {
        case .applied(_, let to):
            logger.info("setVisible=\(visible, privacy: .public) phase=\(to.rawValue, privacy: .public)")
            if to == .active {
                activate()
            } else if to == .suspended {
                suspend(waitForInFlightScan: false)
            }
        case .noOp, .rejected:
            break
        }
    }

    public func tearDown() {
        let result = controller.apply(.tearDown)
        guard case .applied = result else { return }
        logger.info("tearDown path=\(self.directoryPath, privacy: .private)")
        suspend(waitForInFlightScan: true)
    }

    // MARK: Activation / suspension

    private func activate() {
        generation += 1
        if watcher == nil {
            let acquired = watcherFactory(directoryPath) { [weak self] in
                self?.scheduleDebouncedRefresh()
            }
            acquired.start()
            watcher = acquired
        }
        requestScan()
    }

    private func suspend(waitForInFlightScan: Bool) {
        generation += 1
        watcher?.stop()
        watcher = nil
        debounceTask?.cancel()
        debounceTask = nil
        scanTask?.cancel()
        scanTask = nil
        pendingRescanRequested = false
        isScanning = false
        isRefreshing = false
        if waitForInFlightScan {
            scanner.terminateAndWaitBriefly()
        } else {
            scanner.terminateIfRunning()
        }
    }

    private func scheduleDebouncedRefresh() {
        guard lifecyclePhase == .active else { return }
        let requestGeneration = generation
        debounceTask?.cancel()
        let nanoseconds = debounceNanoseconds
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.requestScanIfCurrent(generation: requestGeneration)
        }
    }

    private func requestScanIfCurrent(generation requestGeneration: Int) {
        guard generation == self.generation else { return }
        requestScan()
    }

    private func requestScan() {
        guard lifecyclePhase == .active else { return }
        if isScanning {
            pendingRescanRequested = true
            return
        }
        isScanning = true
        isRefreshing = true
        let path = directoryPath
        let requestGeneration = generation
        scanTask = Task { [weak self] in
            let result = await self?.scanner.scan(atPath: path)
            self?.handleScanResult(result, generation: requestGeneration)
        }
    }

    private func handleScanResult(_ result: GitStatusScanResult?, generation resultGeneration: Int) {
        handledScanResultCount += 1
        guard resultGeneration == generation, lifecyclePhase == .active else { return }
        isScanning = false
        isRefreshing = false
        guard let result else { return }

        switch result {
        case .notARepository:
            state = .notARepository(path: directoryPath)
        case .scanFailed(let message):
            state = .scanFailed(message)
        case .snapshot(let raw):
            let parsed = GitStatusPorcelainParser.parse(raw.statusOutput)
            let operationState: GitRepositoryOperationState
            switch raw.operationMarker {
            case .none: operationState = .none
            case .rebase: operationState = .rebase
            case .cherryPick: operationState = .cherryPick
            case .merge: operationState = .merge(conflictCount: parsed.conflicted.count)
            }
            let snapshot = GitStatusSnapshot(
                repoName: (raw.repositoryToplevel as NSString).lastPathComponent,
                repositoryToplevel: raw.repositoryToplevel,
                branch: parsed.branch,
                detachedSHA: parsed.isDetached ? String((parsed.oid ?? "").prefix(7)) : nil,
                ahead: parsed.ahead,
                behind: parsed.behind,
                hasUpstream: parsed.hasUpstream,
                stashCount: parsed.stashCount,
                submoduleParentName: raw.submoduleParentName,
                isWorktree: raw.isWorktree,
                operationState: operationState,
                conflicted: parsed.conflicted,
                staged: parsed.staged,
                unstaged: parsed.unstaged,
                untracked: parsed.untracked
            )
            state = .snapshot(snapshot)
        }

        if pendingRescanRequested {
            pendingRescanRequested = false
            requestScan()
        }
    }

    /// The rare-case "force a re-scan" button (`docs/design/git-status-view.md`
    /// §2.1) — same coalescing path a debounced refresh uses.
    public func refreshNow() {
        guard lifecyclePhase == .active else { return }
        requestScan()
    }

    // MARK: Selection / diff peek

    public func selectEntry(_ entry: GitStatusFileEntry, staged: Bool) {
        diffTask?.cancel()
        if selectedEntryID == entry.id {
            selectedEntryID = nil
            diffText = nil
            isDiffLoading = false
            return
        }
        selectedEntryID = entry.id
        diffText = nil
        isDiffLoading = true
        // Review round 3, R1: `git diff`'s own path resolution follows
        // the same repo-root-relative contract `git status` does, so the
        // base directory here must be the repository toplevel, not
        // `directoryPath` (which can be a subdirectory of the repo) —
        // falling back to `directoryPath` only in the (unreachable in
        // practice) case a diff is requested before any scan has ever
        // succeeded.
        let path = repositoryToplevelOrDirectoryPath
        let relativePath = entry.path
        let requestGeneration = generation
        diffTask = Task { [weak self] in
            let text = await self?.scanner.diff(atPath: path, relativeFilePath: relativePath, staged: staged)
            self?.handleDiffResult(text, forEntryID: entry.id, generation: requestGeneration)
        }
    }

    /// The most recently observed repository toplevel, or `directoryPath`
    /// if no scan has produced a snapshot yet (review round 3, R1). Also
    /// the base the view uses for building an absolute file URL from a
    /// `GitStatusFileEntry.path` — see `GitStatusPaneView`'s context-menu
    /// actions.
    public var repositoryToplevelOrDirectoryPath: String {
        if case .snapshot(let snapshot) = state {
            return snapshot.repositoryToplevel
        }
        return directoryPath
    }

    public func clearSelection() {
        diffTask?.cancel()
        selectedEntryID = nil
        diffText = nil
        isDiffLoading = false
    }

    private func handleDiffResult(_ text: String?, forEntryID entryID: String, generation resultGeneration: Int) {
        guard resultGeneration == generation, selectedEntryID == entryID else { return }
        diffText = text
        isDiffLoading = false
    }

    // MARK: Retargeting ("Change Directory…")

    /// `docs/design/git-status-view.md` §1: tears down the current watcher
    /// and re-runs setup against the new path — the same "one-time
    /// resolution, explicit re-trigger" shape as creation, just
    /// user-initiated.
    public func changeDirectory(to newPath: String) {
        let wasActive = lifecyclePhase == .active
        suspend(waitForInFlightScan: false)
        directoryPath = newPath
        state = .loading
        selectedEntryID = nil
        diffText = nil
        isDiffLoading = false
        if wasActive {
            activate()
        }
    }
}
