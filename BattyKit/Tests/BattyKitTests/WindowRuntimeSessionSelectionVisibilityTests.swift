// WindowRuntimeSessionSelectionVisibilityTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Records every `setVisible` call and the resulting `PaneLifecycleTransitionResult`
/// — the same recording-double role `NonTerminalPaneTeardownPathsTests
/// .InertPaneContent` plays for teardown, used here to prove *which
/// `WindowRuntime` selection-mutation paths actually deliver
/// `setVisible`* (#0349), without spinning up a real conformer's
/// background work.
@MainActor
private final class RecordingVisibilityPaneContent: PaneContentLifecycle {
    private let controller = PaneLifecycleController()
    private(set) var visibilityCalls: [Bool] = []
    private(set) var transitions: [PaneLifecycleTransitionResult] = []

    var lifecyclePhase: PaneLifecyclePhase { controller.phase }

    var hasRejectedTransition: Bool {
        transitions.contains {
            if case .rejected = $0 { return true }
            return false
        }
    }

    func setUp(visible: Bool) {
        transitions.append(controller.apply(.setUp(visible: visible)))
    }

    func setVisible(_ visible: Bool) {
        visibilityCalls.append(visible)
        transitions.append(controller.apply(visible ? .show : .hide))
    }

    func tearDown() {
        transitions.append(controller.apply(.tearDown))
    }
}

/// Pins #0349: switching `WindowRuntime.selectedSessionID` must suspend the
/// deselected Session's non-terminal Pane content and resume the newly
/// selected Session's, for every production path that writes
/// `selectedSessionID` — sidebar click (`setSelectedSession(id:)`),
/// Cmd-1..9 (`selectSession(at:)`), Session close/duplicate/new
/// (`removeSession`/`duplicateSession`/`addSession`), and the CLI focus
/// verbs over XPC (`AppStateStore.focusSessionForXPC`, which itself calls
/// `setSelectedSession(id:)`) — plus composition with the existing
/// `hidePane`/`showPane` path.
@MainActor
struct WindowRuntimeSessionSelectionVisibilityTests {

    /// A single-Session window whose one Session holds a fake-content Pane.
    /// Built with exactly one Session (not several) so the
    /// `sessions.first?.id` branch of `WindowRuntime.init` — which does not
    /// fire `selectedSessionID`'s `didSet` for its own first assignment —
    /// still leaves this Session in the *correct* state: it is trivially
    /// both the only and the selected Session, so `PaneRuntime.init`'s
    /// construction-time `!isHidden` visibility already matches the truth.
    private func makeWindow(paneContent: RecordingVisibilityPaneContent) -> (window: WindowRuntime, session: SessionRuntime, pane: PaneRuntime) {
        let pane = PaneRuntime(kind: .systemMetrics, contentFactory: { _ in paneContent })
        let tree = SplitTree(root: .leaf(pane))
        let session = SessionRuntime(tree: tree)
        let window = WindowRuntime(sessions: [session], bellFeed: BellFeedStore(), nameCache: SessionNameCache())
        return (window, session, pane)
    }

    @Test func contentStartsActiveWhileItsSessionIsTheOnlyAndSelectedOne() {
        let content = RecordingVisibilityPaneContent()
        let (_, _, pane) = makeWindow(paneContent: content)
        #expect(pane.content?.lifecyclePhase == .active)
    }

    // MARK: - addSession / new Session

    @Test func addingAndSelectingANewSessionSuspendsThePreviouslySelectedSessionsContent() {
        let content = RecordingVisibilityPaneContent()
        let (window, session, _) = makeWindow(paneContent: content)

        window.addSession()

        #expect(window.selectedSessionID != session.id)
        #expect(content.lifecyclePhase == .suspended)
        #expect(content.visibilityCalls.last == false)
    }

    // MARK: - setSelectedSession(id:) — the sidebar click / CLI focus entry point

    @Test func reselectingASessionViaSetSelectedSessionResumesItsContent() {
        let content = RecordingVisibilityPaneContent()
        let (window, session, _) = makeWindow(paneContent: content)
        window.addSession()
        #expect(content.lifecyclePhase == .suspended)

        window.setSelectedSession(id: session.id)

        #expect(window.selectedSessionID == session.id)
        #expect(content.lifecyclePhase == .active)
        #expect(content.visibilityCalls.last == true)
    }

    @Test func setSelectedSessionReassertingTheCurrentSelectionDoesNotReSweep() {
        let content = RecordingVisibilityPaneContent()
        let (window, session, _) = makeWindow(paneContent: content)
        let callsBefore = content.visibilityCalls.count

        window.setSelectedSession(id: session.id)

        #expect(content.visibilityCalls.count == callsBefore, "re-asserting the already-selected Session must not re-sweep visibility")
    }

    // MARK: - selectSession(at:) — the Cmd-1..9 entry point

    @Test func selectSessionAtIndexSuspendsAndResumesAcrossTheCmdNumberPath() {
        let content = RecordingVisibilityPaneContent()
        let (window, session, _) = makeWindow(paneContent: content)
        window.addSession()
        #expect(content.lifecyclePhase == .suspended)
        let sessionIndex = window.sessions.firstIndex { $0.id == session.id }!

        window.selectSession(at: sessionIndex)

        #expect(content.lifecyclePhase == .active)
    }

    // MARK: - removeSession

    @Test func removingTheSelectedSessionResumesTheNewlySelectedSession() {
        let contentA = RecordingVisibilityPaneContent()
        let paneA = PaneRuntime(kind: .systemMetrics, contentFactory: { _ in contentA })
        let sessionA = SessionRuntime(tree: SplitTree(root: .leaf(paneA)))
        let contentB = RecordingVisibilityPaneContent()
        // `sessionB` will not be the selected Session in the `WindowRuntime`
        // built below (`init(sessions:)` selects `sessions.first`, i.e.
        // `sessionA`) — `isSessionSelected: false` (#0349) is how a Pane
        // constructed directly into a background Session reports that fact
        // up front, the same way `AppStateStore.splitPane` computes it for
        // a real background-Session split, so `paneB`'s content starts
        // `.suspended` rather than `.active` from construction.
        let paneB = PaneRuntime(kind: .systemMetrics, isSessionSelected: false, contentFactory: { _ in contentB })
        let sessionB = SessionRuntime(tree: SplitTree(root: .leaf(paneB)))
        let window = WindowRuntime(sessions: [sessionA, sessionB], bellFeed: BellFeedStore(), nameCache: SessionNameCache())
        #expect(contentA.lifecyclePhase == .active)
        #expect(contentB.lifecyclePhase == .suspended)

        window.removeSession(id: sessionA.id)

        #expect(window.selectedSessionID == sessionB.id)
        #expect(contentB.lifecyclePhase == .active, "removing the selected Session must resume the newly-selected Session's content")
        #expect(contentA.lifecyclePhase == .tornDown)
        #expect(!contentA.hasRejectedTransition, "the removed Session's already-torn-down content must not receive a late setVisible")
    }

    // MARK: - duplicateSession

    @Test func duplicatingTheSelectedSessionSuspendsTheSourcesContent() {
        let content = RecordingVisibilityPaneContent()
        let (window, session, _) = makeWindow(paneContent: content)

        let copy = window.duplicateSession(id: session.id)

        #expect(copy != nil)
        #expect(window.selectedSessionID == copy?.id)
        #expect(content.lifecyclePhase == .suspended, "duplicating the selected Session must suspend the source Session's content")
    }

    // MARK: - hidePane / showPane composition

    @Test func hiddenPaneStaysSuspendedAcrossReselection() {
        let content = RecordingVisibilityPaneContent()
        let (window, session, pane) = makeWindow(paneContent: content)
        session.tree.splitFocusedPane(direction: .horizontal)
        window.hidePane(id: pane.id)
        #expect(content.lifecyclePhase == .suspended)

        window.addSession()
        window.setSelectedSession(id: session.id)

        #expect(content.lifecyclePhase == .suspended, "a Pane hidden in a selected Session must stay suspended after re-selecting the Session")
    }

    @Test func showingAPaneInANonSelectedSessionDoesNotResumeIt() {
        let content = RecordingVisibilityPaneContent()
        let (window, session, pane) = makeWindow(paneContent: content)
        session.tree.splitFocusedPane(direction: .horizontal)
        window.hidePane(id: pane.id)
        window.addSession()
        #expect(window.selectedSessionID != session.id)

        window.showPane(id: pane.id)

        #expect(pane.isHidden == false)
        #expect(content.lifecyclePhase == .suspended, "un-hiding a Pane in a non-selected Session must not resume its content")

        window.setSelectedSession(id: session.id)

        #expect(content.lifecyclePhase == .active, "re-selecting the Session resumes the now-unhidden Pane")
    }

    // MARK: - CLI focus verb (XPC `session focus`)

    @Test func cliSessionFocusVerbResumesABackgroundSessionsContent() {
        let store = AppStateStore()
        let session1 = store.sessions[0]
        let content = RecordingVisibilityPaneContent()
        let terminalPane = session1.tree.focusedPane
        let newPaneID = store.splitPane(id: terminalPane.id, direction: .horizontal, kind: .systemMetrics, contentFactory: { _ in content })
        #expect(newPaneID != nil)
        #expect(content.lifecyclePhase == .active)

        store.addSession()
        #expect(store.selectedSessionID != session1.id)
        #expect(content.lifecyclePhase == .suspended, "creating and selecting a new Session must suspend the background Session's content")

        let outcome = store.focusSessionForXPC(id: session1.id)

        #expect(outcome == .focused)
        #expect(store.selectedSessionID == session1.id)
        #expect(content.lifecyclePhase == .active, "the CLI `session focus` verb must resume a background Session's suspended content")
    }

    // MARK: - Multi-window independence

    @Test func selectionChangesInOneWindowDoNotAffectAnotherWindowsContent() {
        let contentInWindowOne = RecordingVisibilityPaneContent()
        let (windowOne, sessionOne, _) = makeWindow(paneContent: contentInWindowOne)
        let contentInWindowTwo = RecordingVisibilityPaneContent()
        let (windowTwo, _, _) = makeWindow(paneContent: contentInWindowTwo)

        windowTwo.addSession()

        #expect(contentInWindowTwo.lifecyclePhase == .suspended)
        #expect(contentInWindowOne.lifecyclePhase == .active, "a selection change in one window must not touch another window's Session content")
        #expect(windowOne.selectedSessionID == sessionOne.id)
    }

    // MARK: - Pane creation directly into a background Session

    /// Pins the construction-time half of #0349: `applySelectionVisibility`
    /// only fires when `selectedSessionID` changes, so it can never reach a
    /// Pane created *into* an already-non-selected Session (no selection
    /// change happens). `AppStateStore.splitPane(id:...)` — the XPC
    /// `pane split` verb — is the one production path that can create a
    /// Pane in a Session other than the caller's own selected one; it now
    /// computes `isSessionSelected` itself and threads it down to
    /// `PaneRuntime.init`'s `setUp(visible:)` through `SplitTree.splitPane`/
    /// `makePane`.
    @Test func cliPaneSplitIntoABackgroundSessionStartsItsContentSuspended() {
        let store = AppStateStore()
        let backgroundSession = store.sessions[0]
        store.addSession()
        #expect(store.selectedSessionID != backgroundSession.id)

        let content = RecordingVisibilityPaneContent()
        let targetPane = backgroundSession.tree.focusedPane
        let newPaneID = store.splitPane(id: targetPane.id, direction: .horizontal, kind: .systemMetrics, contentFactory: { _ in content })

        #expect(newPaneID != nil)
        #expect(content.lifecyclePhase == .suspended, "a Pane split into a non-selected Session's tree must not start its periodic work")

        let outcome = store.focusSessionForXPC(id: backgroundSession.id)

        #expect(outcome == .focused)
        #expect(content.lifecyclePhase == .active, "focusing the background Session resumes the newly-created Pane's content")
    }

    @Test func splittingIntoTheSelectedSessionStillStartsContentActive() {
        let store = AppStateStore()
        let selectedSession = store.sessions[0]
        let content = RecordingVisibilityPaneContent()
        let targetPane = selectedSession.tree.focusedPane

        let newPaneID = store.splitPane(id: targetPane.id, direction: .horizontal, kind: .systemMetrics, contentFactory: { _ in content })

        #expect(newPaneID != nil)
        #expect(content.lifecyclePhase == .active, "splitting into the already-selected Session must not suspend the new Pane's content")
    }

    // MARK: - Equal-value writes

    /// `setSelectedSession(id:)` has its own `if selectedSessionID != id`
    /// guard, so a test that only ever goes through it can't tell that
    /// guard apart from `selectedSessionID`'s own `didSet` guard. This test
    /// writes the property directly (bypassing `setSelectedSession`
    /// entirely) to pin the `didSet`'s own equal-value guard.
    @Test func directEqualValueWriteToSelectedSessionIDDoesNotResweep() {
        let content = RecordingVisibilityPaneContent()
        let (window, session, _) = makeWindow(paneContent: content)
        let callsBefore = content.visibilityCalls.count

        window.selectedSessionID = session.id

        #expect(content.visibilityCalls.count == callsBefore, "an equal-value direct write to selectedSessionID must not re-sweep visibility")
    }
}
