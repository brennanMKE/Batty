// WindowRuntimeOcclusionVisibilityTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
private final class RecordingVisibilityPaneContent: PaneContentLifecycle {
    private let controller = PaneLifecycleController()
    private(set) var visibilityCalls: [Bool] = []
    private var baseline = 0

    /// Calls since `markBaseline()`, so fixture setup (the window's own
    /// first selection sweep, `hidePane`) is not part of what a test asserts.
    var callsSinceBaseline: [Bool] { Array(visibilityCalls.dropFirst(baseline)) }

    func markBaseline() {
        baseline = visibilityCalls.count
    }

    var lifecyclePhase: PaneLifecyclePhase { controller.phase }

    func setUp(visible: Bool) {
        _ = controller.apply(.setUp(visible: visible))
    }

    func setVisible(_ visible: Bool) {
        visibilityCalls.append(visible)
        _ = controller.apply(visible ? .show : .hide)
    }

    func tearDown() {
        _ = controller.apply(.tearDown)
    }
}

/// #0601: an occluded, minimized or hidden window suspends the non-terminal
/// Pane content of its selected Session, the way `TerminalHostStore`
/// occludes terminal surfaces, and nothing resumes it until the window can
/// be seen again.
@MainActor
struct WindowRuntimeOcclusionVisibilityTests {

    private struct Fixture {
        let window: WindowRuntime
        let selected: SessionRuntime
        let background: SessionRuntime
        let visible: RecordingVisibilityPaneContent
        let hidden: RecordingVisibilityPaneContent
        let backgroundContent: RecordingVisibilityPaneContent
        let hiddenPane: PaneRuntime
        let backgroundPane: PaneRuntime
    }

    /// The selected Session holds a visible and a hidden content Pane; a
    /// second, non-selected Session holds a third.
    private func makeFixture() -> Fixture {
        let visible = RecordingVisibilityPaneContent()
        let hidden = RecordingVisibilityPaneContent()
        let backgroundContent = RecordingVisibilityPaneContent()
        let visiblePane = PaneRuntime(kind: .systemMetrics, contentFactory: { _ in visible })
        let hiddenPane = PaneRuntime(kind: .systemMetrics, contentFactory: { _ in hidden })
        let selected = SessionRuntime(tree: SplitTree(root: .split(
            id: UUID(), direction: .horizontal, ratio: SplitRatio(0.5),
            left: .leaf(visiblePane), right: .leaf(hiddenPane)
        )))
        let backgroundPane = PaneRuntime(kind: .systemMetrics, isSessionSelected: false, contentFactory: { _ in backgroundContent })
        let background = SessionRuntime(tree: SplitTree(root: .leaf(backgroundPane)))
        let window = WindowRuntime(sessions: [selected, background], bellFeed: BellFeedStore(), nameCache: SessionNameCache())
        window.hidePane(id: hiddenPane.id)
        for content in [visible, hidden, backgroundContent] {
            content.markBaseline()
        }
        return Fixture(
            window: window, selected: selected, background: background,
            visible: visible, hidden: hidden, backgroundContent: backgroundContent,
            hiddenPane: hiddenPane, backgroundPane: backgroundPane
        )
    }

    @Test func occludingTheWindowSuspendsTheSelectedSessionsVisiblePanes() {
        let fixture = makeFixture()
        #expect(fixture.visible.lifecyclePhase == .active)

        fixture.window.setWindowVisible(false)

        #expect(fixture.visible.callsSinceBaseline == [false])
        #expect(fixture.visible.lifecyclePhase == .suspended)
    }

    @Test func unoccludingResumesThemOnce() {
        let fixture = makeFixture()
        fixture.window.setWindowVisible(false)
        fixture.window.setWindowVisible(false)
        fixture.window.setWindowVisible(true)
        fixture.window.setWindowVisible(true)

        #expect(fixture.visible.callsSinceBaseline == [false, true])
        #expect(fixture.visible.lifecyclePhase == .active)
    }

    @Test func occlusionLeavesHiddenPanesAndBackgroundSessionsAlone() {
        let fixture = makeFixture()
        #expect(fixture.hidden.lifecyclePhase == .suspended)
        #expect(fixture.backgroundContent.lifecyclePhase == .suspended)

        fixture.window.setWindowVisible(false)
        fixture.window.setWindowVisible(true)

        #expect(fixture.hidden.callsSinceBaseline.isEmpty)
        #expect(fixture.hidden.lifecyclePhase == .suspended)
        #expect(fixture.backgroundContent.callsSinceBaseline.isEmpty)
        #expect(fixture.backgroundContent.lifecyclePhase == .suspended)
    }

    @Test func selectingASessionWhileOccludedDoesNotResumeIt() {
        let fixture = makeFixture()
        fixture.window.setWindowVisible(false)

        fixture.window.setSelectedSession(id: fixture.background.id)

        #expect(fixture.backgroundContent.callsSinceBaseline.isEmpty)
        #expect(fixture.backgroundContent.lifecyclePhase == .suspended)

        fixture.window.setWindowVisible(true)

        #expect(fixture.backgroundContent.callsSinceBaseline == [true])
        #expect(fixture.backgroundContent.lifecyclePhase == .active)
        #expect(fixture.visible.lifecyclePhase == .suspended)
    }

    @Test func showingAPaneWhileOccludedDoesNotResumeIt() {
        let fixture = makeFixture()
        fixture.window.setWindowVisible(false)

        fixture.window.showPane(id: fixture.hiddenPane.id)

        #expect(fixture.hidden.callsSinceBaseline.isEmpty)
        #expect(fixture.hidden.lifecyclePhase == .suspended)

        fixture.window.setWindowVisible(true)

        #expect(fixture.hidden.callsSinceBaseline == [true])
        #expect(fixture.hidden.lifecyclePhase == .active)
    }

    @Test func splittingAViewPaneWhileOccludedStartsSuspended() throws {
        let store = AppStateStore()
        let window = store.windows[0]
        let paneID = try #require(window.selectedSession?.tree.allPanes.first?.id)
        window.setWindowVisible(false)
        let content = RecordingVisibilityPaneContent()

        let split = store.splitPane(id: paneID, direction: .horizontal, kind: .systemMetrics, contentFactory: { _ in content })

        #expect(split != nil)
        #expect(content.lifecyclePhase == .suspended)

        window.setWindowVisible(true)

        #expect(content.visibilityCalls == [true])
        #expect(content.lifecyclePhase == .active)
    }

    @Test func creatingAViewPaneWhileOccludedStartsSuspended() {
        let store = AppStateStore()
        let window = store.windows[0]
        window.setWindowVisible(false)
        let content = RecordingVisibilityPaneContent()

        let pane = window.createPane(kind: .systemMetrics, contentFactory: { _ in content })

        #expect(pane != nil)
        #expect(content.lifecyclePhase == .suspended)
    }
}
