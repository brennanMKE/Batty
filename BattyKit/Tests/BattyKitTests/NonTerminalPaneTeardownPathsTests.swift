// NonTerminalPaneTeardownPathsTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Records lifecycle calls without doing any real work — the same
/// role `PaneContentLifecycleTests.RecordingPaneContent` plays for the
/// pure state-machine contract, used here to prove *which WindowRuntime
/// call sites actually invoke `tearDown()`* on a non-terminal pane's
/// content, without spinning up a real `SystemMetricsPaneContent`'s
/// background sampling `Task` during these tests.
@MainActor
private final class InertPaneContent: PaneContentLifecycle {
    private let controller = PaneLifecycleController()
    private(set) var tearDownCallCount = 0

    var lifecyclePhase: PaneLifecyclePhase { controller.phase }

    func setUp(visible: Bool) {
        controller.apply(.setUp(visible: visible))
    }

    func setVisible(_ visible: Bool) {
        controller.apply(visible ? .show : .hide)
    }

    func tearDown() {
        let result = controller.apply(.tearDown)
        if case .applied = result {
            tearDownCallCount += 1
        }
    }
}

/// Review round 1 on #0314 found `docs/pane-view-lifecycle.md`'s "closePane
/// is the single choke point every close path funnels through" claim false
/// in this tree: `removeSession` and `closeTab` both remove panes without
/// ever calling `closePane`, and — found by a second review pass on a
/// sibling issue — `RootWindowView.windowWillClose` and
/// `BattyAppDelegate.applicationWillTerminate` remove whole windows/the
/// whole app without going through any of the three pane-level paths at
/// all. This suite pins `tearDown()` actually firing on every path a
/// non-terminal pane's content can be removed through, using a plain
/// `WindowRuntime` built directly (not through `AppStateStore`, so the
/// pane's `PaneContentLifecycle` conformer is an injected test double, not
/// the real sampler).
@MainActor
struct NonTerminalPaneTeardownPathsTests {

    private func makeWindow(paneContent: InertPaneContent) -> (window: WindowRuntime, session: SessionRuntime, pane: PaneRuntime) {
        let pane = PaneRuntime(kind: .systemMetrics, contentFactory: { _ in paneContent })
        let tree = SplitTree(root: .leaf(pane))
        let session = SessionRuntime(tree: tree)
        let window = WindowRuntime(sessions: [session], bellFeed: BellFeedStore(), nameCache: SessionNameCache())
        return (window, session, pane)
    }

    @Test func contentIsActiveImmediatelyAfterConstruction() {
        let content = InertPaneContent()
        let (_, _, pane) = makeWindow(paneContent: content)
        #expect(pane.content?.lifecyclePhase == .active)
        #expect(content.tearDownCallCount == 0)
    }

    @Test func closePaneTearsDownTheContent() {
        let content = InertPaneContent()
        let (window, session, pane) = makeWindow(paneContent: content)
        // A second, sibling pane so closePane doesn't refuse for being the
        // window's last one and so removePane doesn't also empty the
        // session (keeping this test scoped to closePane's own teardown
        // call, not removeSession's).
        session.tree.splitFocusedPane(direction: .horizontal)

        let outcome = window.closePane(id: pane.id, refuseIfAppsLastPane: false)

        #expect(outcome == .closed)
        #expect(content.tearDownCallCount == 1)
        #expect(pane.content?.lifecyclePhase == .tornDown)
    }

    @Test func removeSessionTearsDownEveryPanesContent() {
        // The bug this pins: removeSession never called closePane, so a
        // Session closed directly (the sidebar's "close session" control)
        // left every non-terminal pane's content running.
        let content = InertPaneContent()
        let (window, session, _) = makeWindow(paneContent: content)

        window.removeSession(id: session.id)

        #expect(content.tearDownCallCount == 1)
    }

    @Test func closeTabTearsDownTheEmptiedPanesContent() {
        // Every PaneRuntime holds at least one TabRuntime (its own
        // precondition), including a .systemMetrics pane's structural
        // phantom tab — closing that one tab is a real, reachable path,
        // not a hypothetical.
        let content = InertPaneContent()
        let (window, session, pane) = makeWindow(paneContent: content)
        session.tree.splitFocusedPane(direction: .horizontal)
        let onlyTabID = pane.tabs[0].id

        window.closeTab(id: onlyTabID)

        #expect(content.tearDownCallCount == 1)
    }

    @Test func closeTabEmptyingTheOnlySessionAlsoTearsDownExactlyOnce() {
        // closeTab's own pane-removal branch tears the pane down directly,
        // then (because this empties the tree) calls removeSession, whose
        // own sweep must not double-tear-down the same, already-removed
        // pane — tearDown() is idempotent, so even if it did, the ledger
        // below would still read 1, not more.
        let content = InertPaneContent()
        let (window, session, pane) = makeWindow(paneContent: content)
        let onlyTabID = pane.tabs[0].id

        window.closeTab(id: onlyTabID)

        #expect(content.tearDownCallCount == 1)
        #expect(window.sessions.isEmpty)
    }

    @Test func windowWillCloseEquivalentTearsDownEveryPaneAcrossEverySession() {
        // Pins the gap a sibling issue's review found: window-close (and,
        // by the same call, app-quit) removes the whole window without
        // going through closePane/removeSession/closeTab at all.
        // WindowRuntime.tearDownAllPaneContent() is what
        // RootWindowView.windowWillClose and
        // BattyAppDelegate.applicationWillTerminate both call.
        let firstContent = InertPaneContent()
        let secondContent = InertPaneContent()
        let firstPane = PaneRuntime(kind: .systemMetrics, contentFactory: { _ in firstContent })
        let secondPane = PaneRuntime(kind: .systemMetrics, contentFactory: { _ in secondContent })
        let firstSession = SessionRuntime(tree: SplitTree(root: .leaf(firstPane)))
        let secondSession = SessionRuntime(tree: SplitTree(root: .leaf(secondPane)))
        let window = WindowRuntime(
            sessions: [firstSession, secondSession],
            bellFeed: BellFeedStore(),
            nameCache: SessionNameCache()
        )

        window.tearDownAllPaneContent()

        #expect(firstContent.tearDownCallCount == 1)
        #expect(secondContent.tearDownCallCount == 1)
    }

    @Test func terminalPanesAreUnaffectedByTheNewTeardownCalls() {
        // pane.content is nil for .terminal panes — every new call site
        // must be a no-op there, not a crash or a spurious call.
        let store = AppStateStore()
        let session = store.sessions[0]
        #expect(session.tree.allPanes[0].content == nil)

        store.removeSession(id: session.id)
        // No assertion beyond "didn't crash" — there is no content to
        // observe on a terminal pane.
        #expect(store.sessions.isEmpty)
    }
}
