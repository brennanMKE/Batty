// LMStudioDashboardWiringTests.swift

import Darwin
import Foundation
import Testing
@testable import BattyKit

/// Covers the model-layer wiring #0313 phase 2 adds, rebased onto #0314's
/// centrally-resolved shape: `PaneRuntime.makeContent(for:)` constructs a
/// real `LMStudioDashboardPaneContent` for `.lmStudioDashboard`, and every
/// non-terminal-content teardown/visibility path — `closePane`,
/// `removeSession`, `closeTab`'s pane-removal branch, and
/// `tearDownAllPaneContent()` (what `RootWindowView.windowWillClose` and
/// `BattyAppDelegate.applicationWillTerminate` both call) — drives it.
///
/// `setUp()` now runs unconditionally inside `PaneRuntime.init` (per
/// `docs/pane-view-lifecycle.md`'s "at Pane creation" requirement, restored
/// by #0314's `contentFactory` injection point). That means constructing a
/// `.lmStudioDashboard` pane through the *default* factory for real would
/// spawn a real subprocess and start polling `localhost:1234` as a side
/// effect of merely building a `PaneRuntime` — unacceptable in a test, and
/// on a machine that actually has LM Studio installed and running (this
/// one), a *real* one. Every test below that needs a live pane threads its
/// own `contentFactory` closure instead, mirroring
/// `NonTerminalPaneTeardownPathsTests`'s `InertPaneContent` pattern but
/// using the real `LMStudioDashboardPaneContent` with its network/CLI
/// dependencies safely stubbed inside the closure *before* `PaneRuntime
/// .init` calls `setUp()` on it — so this suite exercises this kind's own
/// teardown code (including real, if harmless, subprocesses for the B2
/// end-to-end proof below), not a generic stand-in.
@MainActor
struct LMStudioDashboardWiringTests {

    // MARK: - `makeContent` (requirement: the `.lmStudioDashboard` arm
    // constructs the real conformer)

    /// Calls the static factory directly — not through `PaneRuntime.init`
    /// — so this is a pure, side-effect-free check: `makeContent` itself
    /// never calls `setUp()`, only `PaneRuntime.init` does.
    @Test func makeContentConstructsARealConformerForLMStudioDashboard() {
        let content = PaneRuntime.makeContent(for: .lmStudioDashboard)
        let dashboard = content as? LMStudioDashboardPaneContent
        #expect(dashboard != nil)
        #expect(dashboard?.lifecyclePhase == .notSetUp)
    }

    @Test func makeContentReturnsNilForTerminalAndUnshippedKinds() {
        #expect(PaneRuntime.makeContent(for: .terminal) == nil)
        // `.gitStatus` is no longer nil here (#0304 landed its conformer
        // after this test was written) — see
        // `GitStatusPaneContentTests`/`ProcessGitStatusScannerTests` for
        // its own coverage; `.processStatus` is the one case still
        // genuinely unshipped at the time of writing.
        #expect(PaneRuntime.makeContent(for: .processStatus) == nil)
    }

    // MARK: - Test helpers

    /// A `LMStudioDashboardPaneContent` wired for safe, offline use inside
    /// a `contentFactory` closure: `cliExecutableURLProvider` returns `nil`
    /// so no subprocess is ever spawned and `fetchModels` never touches the
    /// network, but the object is otherwise real — its own state machine,
    /// its own `tearDown()` — so tests below exercise the actual conformer,
    /// not a double standing in for it.
    private func makeSafeOfflineContent() -> LMStudioDashboardPaneContent {
        let content = LMStudioDashboardPaneContent()
        content.cliExecutableURLProvider = { nil }
        content.fetchModels = { LMStudioModelsResponse(models: []) }
        return content
    }

    private func makeWindow(paneContent: LMStudioDashboardPaneContent) -> (window: WindowRuntime, session: SessionRuntime, pane: PaneRuntime) {
        let pane = PaneRuntime(kind: .lmStudioDashboard, contentFactory: { _ in paneContent })
        let tree = SplitTree(root: .leaf(pane))
        let session = SessionRuntime(tree: tree)
        let window = WindowRuntime(sessions: [session], bellFeed: BellFeedStore(), nameCache: SessionNameCache())
        return (window, session, pane)
    }

    // MARK: - `setUp` now runs at construction (per docs/pane-view-lifecycle.md)

    @Test func constructionThroughAnInjectedFactoryCallsSetUpImmediately() {
        let content = makeSafeOfflineContent()
        _ = makeWindow(paneContent: content)
        #expect(content.lifecyclePhase == .active)
        #expect(content.connectionState == .notInstalled) // cliExecutableURLProvider returns nil
    }

    // MARK: - Hide / show

    @Test func hideAndShowDriveTheConformer() {
        let content = makeSafeOfflineContent()
        let (window, session, pane) = makeWindow(paneContent: content)
        // hidePane refuses to hide a session's last visible pane (the ≥1
        // visible-pane invariant) — a sibling pane makes hiding legal.
        session.tree.splitFocusedPane(direction: .horizontal)

        window.hidePane(id: pane.id)
        #expect(content.lifecyclePhase == .suspended)

        window.showPane(id: pane.id)
        #expect(content.lifecyclePhase == .active)
    }

    // MARK: - The three model-layer pane-removal paths

    @Test func closePaneTearsDownTheConformer() {
        let content = makeSafeOfflineContent()
        let (window, session, pane) = makeWindow(paneContent: content)
        // A sibling pane so closePane doesn't refuse for being the
        // window's last one, keeping this scoped to closePane's own
        // teardown call.
        session.tree.splitFocusedPane(direction: .horizontal)

        let outcome = window.closePane(id: pane.id, refuseIfAppsLastPane: false)

        #expect(outcome == .closed)
        #expect(content.lifecyclePhase == .tornDown)
    }

    @Test func removeSessionTearsDownTheConformer() {
        let content = makeSafeOfflineContent()
        let (window, session, _) = makeWindow(paneContent: content)

        window.removeSession(id: session.id)

        #expect(content.lifecyclePhase == .tornDown)
    }

    @Test func closeTabTearsDownTheConformer() {
        let content = makeSafeOfflineContent()
        let (window, session, pane) = makeWindow(paneContent: content)
        session.tree.splitFocusedPane(direction: .horizontal)
        let onlyTabID = pane.tabs[0].id

        window.closeTab(id: onlyTabID)

        #expect(content.lifecyclePhase == .tornDown)
    }

    // MARK: - B2 end to end, for this kind specifically: window-close /
    // app-quit teardown actually kills real subprocesses, not just flips a
    // state-machine flag

    /// `tearDownAllPaneContent()` is the exact call
    /// `RootWindowView.windowWillClose` and
    /// `BattyAppDelegate.applicationWillTerminate` both make (see that
    /// method's own doc comment, which names this issue's own orphaned-
    /// subprocess finding as the reason it exists). This test is this
    /// kind's own mutation-provable proof — mirroring the earlier
    /// `tearDownActuallyTerminatesBothSubprocesses` proof for `tearDown()`
    /// directly — that routing through *this* shared call site also
    /// actually kills the real `lms log stream` subprocesses, not merely
    /// transitions `lifecyclePhase`. `LMStudioDashboardPaneContentTests`
    /// already proves `tearDown()` itself kills real subprocesses; this
    /// test closes the specific gap #0314's reviewer flagged — that
    /// nothing proved the *new, shared* call site actually reaches this
    /// kind's `tearDown()` at all.
    @Test func tearDownAllPaneContentActuallyKillsRealSubprocesses() async throws {
        final class ProcessBox {
            var model: Process?
            var runtime: Process?
        }
        let box = ProcessBox()

        let content = LMStudioDashboardPaneContent()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { LMStudioModelsResponse(models: []) }
        content.makeModelStreamProcess = { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // `exec` (not a bare `sleep 60`) keeps this a single process, so
            // `terminate()`'s `SIGTERM` reaches `sleep` directly instead of
            // only `sh`, which would otherwise die and orphan `sleep` for up
            // to its own 60s lifetime.
            process.arguments = ["-c", "exec sleep 60"]
            box.model = process
            return process
        }
        content.makeRuntimeStreamProcess = { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exec sleep 60"]
            box.runtime = process
            return process
        }

        // `PaneRuntime.init` calls `content.setUp(visible:)` synchronously,
        // and `setUp(visible: true)` spawns both streams synchronously too
        // (`startActiveWork()`, called inline, not from a `Task`) — so both
        // subprocesses are already running by the time `makeWindow` returns;
        // no wait needed (`docs/async-test-seams.md` §5.1's `posix_spawn`
        // finding: `Process.run()` itself returns only once the child image
        // is live).
        let (window, _, _) = makeWindow(paneContent: content)

        let model = try #require(box.model)
        let runtime = try #require(box.runtime)
        #expect(model.isRunning)
        #expect(runtime.isRunning)

        window.tearDownAllPaneContent()
        // #0354: `tearDown()` no longer blocks the main actor until the
        // subprocess exits — the wait/SIGKILL-escalation happens on a
        // detached task. Await it before checking `isRunning`.
        await content.awaitPendingTeardownReapsForTesting()

        #expect(model.isRunning == false)
        #expect(runtime.isRunning == false)
        #expect(content.lifecyclePhase == .tornDown)
    }

    // MARK: - Quit path: synchronous wait for deferred teardown (#0354 review round 1)

    /// `BattyAppDelegate.applicationWillTerminate` calls this variant
    /// instead of `tearDownAllPaneContent()`: `tearDown()`'s own subprocess
    /// reap is a detached task (#0354), which keeps an ordinary window
    /// close responsive, but is wrong for quitting — the app process exits
    /// shortly after `applicationWillTerminate` returns, so a detached task
    /// scheduled inside it may never run at all. This proves the quit
    /// variant blocks synchronously until a `SIGTERM`-ignoring subprocess is
    /// actually dead, with no separate `await` needed afterward — unlike
    /// `tearDownAllPaneContentActuallyKillsRealSubprocesses` above.
    @Test func tearDownAllPaneContentSynchronouslyForQuitKillsATermIgnoringSubprocess() async throws {
        final class ProcessBox {
            var model: Process?
            var runtime: Process?
        }
        let box = ProcessBox()

        // #0424: a fixed sleep after spawn can't prove the trap is
        // installed before `tearDownAllPaneContentSynchronouslyForQuit()`
        // sends `SIGTERM` — under host load `sh` might not have parsed
        // `trap '' TERM` yet, which would kill the child on the default
        // disposition and let this test pass without ever reaching the
        // `SIGKILL` escalation it means to prove. Wait on the shared
        // fixture's ready-file handshake instead.
        let (readyDirectory, cleanupReadyDirectory) = try LMStudioSIGTERMIgnoringFixture.makeReadyDirectory(
            callerTag: "quit-kills-term-ignoring"
        )
        defer { cleanupReadyDirectory() }
        let modelReadyURL = readyDirectory.appendingPathComponent("model-ready")
        let runtimeReadyURL = readyDirectory.appendingPathComponent("runtime-ready")

        let content = LMStudioDashboardPaneContent()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { LMStudioModelsResponse(models: []) }
        content.teardownWaitBound = 0.2
        content.makeModelStreamProcess = { _ in
            let process = LMStudioSIGTERMIgnoringFixture.makeProcess(readyFileURL: modelReadyURL)
            box.model = process
            return process
        }
        content.makeRuntimeStreamProcess = { _ in
            let process = LMStudioSIGTERMIgnoringFixture.makeProcess(readyFileURL: runtimeReadyURL)
            box.runtime = process
            return process
        }

        let (window, _, _) = makeWindow(paneContent: content)

        // A safety net for any exit from here on (a failed readiness guard,
        // a throwing `#require`, falling off the end) — killing an
        // already-dead process is a harmless no-op, so this runs safely
        // even after the success path's own assertions already confirm
        // both children are dead.
        defer {
            killAndReap(box.model)
            killAndReap(box.runtime)
        }

        guard await LMStudioSIGTERMIgnoringFixture.waitForReadyFile(modelReadyURL) else {
            Issue.record("model-stream never installed its SIGTERM trap")
            content.tearDown()
            return
        }
        guard await LMStudioSIGTERMIgnoringFixture.waitForReadyFile(runtimeReadyURL) else {
            Issue.record("runtime-stream never installed its SIGTERM trap")
            content.tearDown()
            return
        }

        let model = try #require(box.model)
        let runtime = try #require(box.runtime)
        #expect(model.isRunning)
        #expect(runtime.isRunning)

        window.tearDownAllPaneContentSynchronouslyForQuit()

        // No `await` at all here — the quit variant has already blocked
        // until both children are confirmed dead by the time it returns.
        #expect(model.isRunning == false)
        #expect(runtime.isRunning == false)
        #expect(content.lifecyclePhase == .tornDown)
    }

    // MARK: - #0425: a reap left by a pane already gone from the model

    /// The quit-path test above proves `DeferredTeardownWaiting`'s walk
    /// reaches a pane still in this window's `sessions` tree. That walk
    /// cannot reach a pane closed moments before quit — `closePane` removes
    /// it from the tree before any later walk could find it — so a
    /// `SIGTERM`-ignoring child's reap in that case is reachable only
    /// through `PendingTeardownReapRegistry`, independent of the model
    /// entirely (#0425). This pins that: close the pane (tearing down and
    /// removing it from the model), then drain the same registry
    /// `applicationWillTerminate` drains. It does not prove
    /// `drainSynchronously()` is the one that sends the killing `SIGKILL` —
    /// `tearDown()`'s own detached task starts with the same bound and may
    /// get there first. What it proves is that `drainSynchronously()`
    /// doesn't return until both children are actually dead: the assertions
    /// run immediately after it returns, with no `await` or extra wait of
    /// their own, so passing requires `drainSynchronously()`'s own blocking
    /// wait to have covered the outcome — the detached task alone, left to
    /// run on its own schedule, cannot guarantee that within this
    /// assertion window.
    ///
    /// A temp-file readiness handshake, not a stdout `Pipe` (#0424's
    /// caveat): `spawnModelStream`/`spawnRuntimeStream` replace the
    /// process's own `standardOutput`/`standardError` with pipes and
    /// readability handlers they own, so a test-owned pipe on the same
    /// process would race the content's own handler for the same bytes.
    /// `LMStudioSIGTERMIgnoringFixture` (#0424) is the shared implementation
    /// of that handshake — also used by
    /// `tearDownAllPaneContentSynchronouslyForQuitKillsATermIgnoringSubprocess`
    /// above and by `LMStudioDashboardPaneContentTests`, so the three can't
    /// drift back into three different (and possibly racy) copies.
    @Test func registryDrainReapsATermIgnoringSubprocessLeftByAClosedPane() async throws {
        final class ProcessBox {
            var model: Process?
            var runtime: Process?
        }
        let box = ProcessBox()
        let registry = PendingTeardownReapRegistry()

        let (readyDirectory, cleanupReadyDirectory) = try LMStudioSIGTERMIgnoringFixture.makeReadyDirectory(
            callerTag: "registry-drain"
        )
        defer { cleanupReadyDirectory() }
        let modelReadyURL = readyDirectory.appendingPathComponent("model-ready")
        let runtimeReadyURL = readyDirectory.appendingPathComponent("runtime-ready")

        let content = LMStudioDashboardPaneContent()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { LMStudioModelsResponse(models: []) }
        content.teardownWaitBound = 0.2
        content.teardownReapRegistry = registry
        content.makeModelStreamProcess = { _ in
            let process = LMStudioSIGTERMIgnoringFixture.makeProcess(readyFileURL: modelReadyURL)
            box.model = process
            return process
        }
        content.makeRuntimeStreamProcess = { _ in
            let process = LMStudioSIGTERMIgnoringFixture.makeProcess(readyFileURL: runtimeReadyURL)
            box.runtime = process
            return process
        }

        let (window, session, pane) = makeWindow(paneContent: content)
        // A sibling pane so `closePane` doesn't refuse for being the
        // window's last one, exactly like this suite's other `closePane`
        // tests.
        session.tree.splitFocusedPane(direction: .horizontal)

        // A safety net for any exit from here on (a failed readiness guard,
        // a throwing `#require`, falling off the end) — placed before the
        // readiness guards below, unlike the success path's own later
        // assertions, so it covers them too. Killing an already-dead
        // process is a harmless no-op.
        defer {
            killAndReap(box.model)
            killAndReap(box.runtime)
        }

        guard await LMStudioSIGTERMIgnoringFixture.waitForReadyFile(modelReadyURL) else {
            Issue.record("model-stream never installed its SIGTERM trap")
            content.tearDown()
            return
        }
        guard await LMStudioSIGTERMIgnoringFixture.waitForReadyFile(runtimeReadyURL) else {
            Issue.record("runtime-stream never installed its SIGTERM trap")
            content.tearDown()
            return
        }

        let model = try #require(box.model)
        let runtime = try #require(box.runtime)
        #expect(model.isRunning)
        #expect(runtime.isRunning)

        let outcome = window.closePane(id: pane.id, refuseIfAppsLastPane: false)
        #expect(outcome == .closed)
        #expect(!session.tree.allPanes.contains { $0.id == pane.id }, "sanity check: the pane must actually be gone from the model, or this isn't exercising the #0425 gap")

        registry.drainSynchronously()

        #expect(model.isRunning == false)
        #expect(runtime.isRunning == false)
    }

    @Test func terminalPanesAreUnaffectedByTearDownAllPaneContent() {
        let store = AppStateStore()
        let session = store.sessions[0]
        #expect(session.tree.allPanes[0].content == nil)

        store.windows[0].tearDownAllPaneContent()
        // No assertion beyond "didn't crash" — there is no content to
        // observe on a terminal pane.
        #expect(store.sessions[0].tree.allPanes[0].content == nil)
    }
}

/// A test's own failure-branch cleanup, not the normal path. Forwards to
/// `ChildProcessFixture.killAndReap(_:)` (#0441), which replaced this file's
/// own copy (previously duplicated from `LMStudioDashboardPaneContentTests.swift`)
/// — kept as a thin wrapper so call sites here don't need to change.
@MainActor
private func killAndReap(_ process: Process?) {
    ChildProcessFixture.killAndReap(process)
}
