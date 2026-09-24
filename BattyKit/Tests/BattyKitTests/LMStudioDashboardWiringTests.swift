// LMStudioDashboardWiringTests.swift

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
            process.arguments = ["-c", "sleep 60"]
            box.model = process
            return process
        }
        content.makeRuntimeStreamProcess = { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 60"]
            box.runtime = process
            return process
        }

        let (window, _, _) = makeWindow(paneContent: content)
        try await Task.sleep(for: .milliseconds(200))

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

        // `exec` replaces the shell's own process image with `sleep` rather
        // than forking it; `SIG_IGN` survives `exec`, so the ignored
        // disposition `trap` set carries over to `sleep` directly — exactly
        // one process exists at any point, so `SIGKILL` on that single pid
        // leaves nothing behind.
        func makeIgnoringSIGTERMProcess(_ url: URL) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "trap '' TERM; exec sleep 60"]
            return process
        }

        let content = LMStudioDashboardPaneContent()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { LMStudioModelsResponse(models: []) }
        content.teardownWaitBound = 0.2
        content.makeModelStreamProcess = { url in
            let process = makeIgnoringSIGTERMProcess(url)
            box.model = process
            return process
        }
        content.makeRuntimeStreamProcess = { url in
            let process = makeIgnoringSIGTERMProcess(url)
            box.runtime = process
            return process
        }

        let (window, _, _) = makeWindow(paneContent: content)
        try await Task.sleep(for: .milliseconds(200))

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
