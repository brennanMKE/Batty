// TerminalHostStoreTabVisibilityTests.swift

import AppKit
import GhosttyTerminal
import Testing
@testable import BattyKit

/// #0605: which terminals are shown is pushed to `TerminalHostStore` by the
/// actions that change Tab, Session or Pane visibility, synchronously, and
/// the placeholder's frame report never hides a view. Every assertion right
/// after an action runs with no layout or main-queue turn in between.
@MainActor
@Suite(.serialized)
struct TerminalHostStoreTabVisibilityTests {

    @MainActor
    private final class Harness {
        let store = AppStateStore()
        let window: NSWindow
        private var nextOrigin: CGFloat = 0

        var windowRuntime: WindowRuntime { store.windows[0] }
        var hostStore: TerminalHostStore { TerminalHostStore.shared }

        init() {
            window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
                styleMask: [.borderless],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            window.contentView = TerminalHostStore.shared.hostView(forWindowID: store.windows[0].id)
        }

        @discardableResult
        func mount(_ tab: TabRuntime) -> AppTerminalView? {
            hostStore.terminalView(for: tab, windowID: windowRuntime.id)
        }

        /// A non-zero frame distinct from every earlier one.
        func nextFrame() -> CGRect {
            nextOrigin += 10
            return CGRect(x: nextOrigin, y: nextOrigin, width: 300, height: 200)
        }

        func report(_ tab: TabRuntime, frame: CGRect) {
            hostStore.reportFrame(frame, forTabID: tab.id)
        }

        /// Mounts every terminal Tab in `session` and reports a distinct frame
        /// for each, as the mounted placeholders do.
        func mountAndReport(_ session: SessionRuntime) {
            for pane in session.tree.allPanes where pane.kind == .terminal {
                mountAndReport(pane)
            }
        }

        func mountAndReport(_ pane: PaneRuntime) {
            for tab in pane.tabs {
                mount(tab)
                report(tab, frame: nextFrame())
            }
        }

        /// The Tabs that should be shown: each non-hidden terminal Pane's
        /// active Tab in the selected Session.
        func expectedShownTabIDs() -> Set<UUID> {
            guard let session = windowRuntime.selectedSession else { return [] }
            var ids: Set<UUID> = []
            for pane in session.tree.allPanes where pane.kind == .terminal && !pane.isHidden {
                ids.insert(pane.activeTabID)
            }
            return ids
        }

        func allTabs() -> [TabRuntime] {
            windowRuntime.sessions.flatMap { $0.tree.allPanes.flatMap(\.tabs) }
        }

        func tearDown() {
            for tab in allTabs() {
                hostStore.releaseTerminalView(forTabID: tab.id)
            }
            for session in windowRuntime.sessions {
                for pane in session.tree.allPanes {
                    pane.content?.tearDown()
                }
            }
            hostStore.releaseHost(forWindowID: windowRuntime.id)
            window.close()
        }
    }

    // MARK: - Tab switch

    @Test func selectingATabHidesTheOutgoingTerminalInTheAction() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let pane = try #require(harness.windowRuntime.selectedSession?.tree.focusedPane)
        let first = try #require(pane.activeTab)
        let second = pane.addTab()
        pane.activeTabID = first.id
        harness.mountAndReport(pane)
        let firstView = try #require(first.terminalNSView)
        let secondView = try #require(second.terminalNSView)
        let secondFrame = try #require(harness.hostStore.reportedFrame(forTabID: second.id))
        #expect(!firstView.isHidden, "fixture: the outgoing terminal is not visible")
        #expect(secondView.isHidden, "fixture: the incoming terminal is already visible")

        harness.windowRuntime.selectNextTabInFocusedPane()

        #expect(pane.activeTabID == second.id)
        #expect(firstView.isHidden, "the outgoing terminal was not hidden by the action")
        #expect(!secondView.isHidden, "the incoming terminal was not revealed by the action")
        #expect(secondView.frame == secondFrame)
    }

    /// The Tab bar's chip binding writes `pane.activeTabID` directly.
    @Test func selectingATabFromTheTabBarBindingHidesTheOutgoingTerminalInTheAction() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let pane = try #require(harness.windowRuntime.selectedSession?.tree.focusedPane)
        let first = try #require(pane.activeTab)
        let second = pane.addTab()
        harness.mountAndReport(pane)
        let firstView = try #require(first.terminalNSView)
        let secondView = try #require(second.terminalNSView)
        #expect(!secondView.isHidden, "fixture: the outgoing terminal is not visible")
        #expect(firstView.isHidden, "fixture: the incoming terminal is already visible")

        pane.activeTabID = first.id

        #expect(secondView.isHidden, "the outgoing terminal was not hidden by the write")
        #expect(!firstView.isHidden, "the incoming terminal was not revealed by the write")
    }

    /// Non-default control: Tabs switching in a background Session must not
    /// reveal anything, while the selected Session's terminal stays visible.
    @Test func switchingTabsInABackgroundSessionRevealsNothing() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let windowRuntime = harness.windowRuntime
        let sessionA = try #require(windowRuntime.selectedSession)
        let sessionB = windowRuntime.addSession()
        let paneB = sessionB.tree.focusedPane
        let firstB = try #require(paneB.activeTab)
        let secondB = paneB.addTab()
        windowRuntime.selectSession(at: 0)
        harness.mountAndReport(sessionA)
        harness.mountAndReport(sessionB)
        let viewA = try #require(sessionA.tree.focusedPane.activeTab?.terminalNSView)
        #expect(!viewA.isHidden)

        paneB.activeTabID = firstB.id

        #expect(try #require(firstB.terminalNSView).isHidden)
        #expect(try #require(secondB.terminalNSView).isHidden)
        #expect(!harness.hostStore.isTabShown(firstB.id))
        #expect(!harness.hostStore.isTabShown(secondB.id))
        #expect(!viewA.isHidden, "the selected Session's terminal was hidden")
    }

    @Test func switchingFromAnAlreadyHiddenTabRevealsNothing() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let session = try #require(harness.windowRuntime.selectedSession)
        let pane = session.tree.focusedPane
        _ = session.tree.splitFocusedPane(direction: .horizontal)
        let first = try #require(pane.activeTab)
        let second = pane.addTab()
        harness.mountAndReport(session)
        harness.windowRuntime.hidePane(id: pane.id)
        #expect(pane.isHidden)

        pane.activeTabID = first.id

        #expect(try #require(first.terminalNSView).isHidden)
        #expect(try #require(second.terminalNSView).isHidden)
        #expect(!harness.hostStore.isTabShown(first.id))
        #expect(!harness.hostStore.isTabShown(second.id))
    }

    @Test func closingTheActiveTabRevealsItsNeighbour() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let pane = try #require(harness.windowRuntime.selectedSession?.tree.focusedPane)
        let first = try #require(pane.activeTab)
        let second = pane.addTab()
        harness.mountAndReport(pane)
        let firstView = try #require(first.terminalNSView)
        #expect(firstView.isHidden)

        harness.store.closeTab(id: second.id)

        #expect(pane.activeTabID == first.id)
        #expect(!firstView.isHidden, "the neighbour was not revealed by the close")
        #expect(harness.hostStore.isTabShown(first.id))
        #expect(!harness.hostStore.isTabShown(second.id))
    }

    // MARK: - Session switch

    @Test func selectingASessionHidesTheLeftSessionsTerminalsInTheAction() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let windowRuntime = harness.windowRuntime
        let sessionA = try #require(windowRuntime.selectedSession)
        let sessionB = windowRuntime.addSession()
        let paneB = sessionB.tree.focusedPane
        let inactiveB = paneB.addTab()
        let activeB = try #require(paneB.tabs.first)
        paneB.activeTabID = activeB.id
        windowRuntime.selectSession(at: 0)
        harness.mountAndReport(sessionA)
        harness.mountAndReport(sessionB)
        let viewA = try #require(sessionA.tree.focusedPane.activeTab?.terminalNSView)
        let activeView = try #require(activeB.terminalNSView)
        let inactiveView = try #require(inactiveB.terminalNSView)
        #expect(!viewA.isHidden, "fixture: Session A's terminal is not visible")
        #expect(activeView.isHidden, "fixture: Session B's terminal is already visible")

        windowRuntime.setSelectedSession(id: sessionB.id)

        #expect(viewA.isHidden, "Session A's terminal was not hidden by the action")
        #expect(!activeView.isHidden, "Session B's active terminal was not revealed by the action")
        #expect(activeView.frame == harness.hostStore.reportedFrame(forTabID: activeB.id))
        #expect(inactiveView.isHidden, "Session B's inactive Tab was revealed")
    }

    @Test func theInitialSessionsTerminalIsShown() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let tab = try #require(harness.windowRuntime.selectedSession?.tree.focusedPane.activeTab)
        #expect(harness.hostStore.isTabShown(tab.id))
    }

    /// AppKit would hand first responder to the next valid key view, which can
    /// be another visible terminal; the action resigns to the window instead.
    @Test func hidingTheFirstResponderTerminalResignsToTheWindow() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let session = try #require(harness.windowRuntime.selectedSession)
        let pane = session.tree.focusedPane
        let other = session.tree.splitFocusedPane(direction: .horizontal)
        session.tree.focusedPaneID = pane.id
        let first = try #require(pane.activeTab)
        _ = pane.addTab()
        pane.activeTabID = first.id
        harness.mountAndReport(session)
        let firstView = try #require(first.terminalNSView)
        let otherView = try #require(other.activeTab?.terminalNSView)
        #expect(!firstView.isHidden)
        #expect(!otherView.isHidden, "fixture: no other visible terminal in the window")
        #expect(harness.window.makeFirstResponder(firstView))
        #expect(harness.window.firstResponder === firstView)

        harness.windowRuntime.selectNextTabInFocusedPane()

        #expect(firstView.isHidden)
        #expect(harness.window.firstResponder === harness.window, "first responder: \(String(describing: harness.window.firstResponder))")
    }

    // MARK: - Frame reports

    @Test func aShownTabIsRevealedByItsFirstFrameReport() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let pane = try #require(harness.windowRuntime.selectedSession?.tree.focusedPane)
        let tab = pane.addTab()
        #expect(harness.hostStore.isTabShown(tab.id))
        let view = try #require(harness.mount(tab))
        #expect(view.isHidden, "a new view must start hidden")

        let frame = harness.nextFrame()
        harness.report(tab, frame: frame)

        #expect(!view.isHidden)
        #expect(view.frame == frame)
    }

    @Test func reportingAFrameNeverHidesAView() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let tab = try #require(harness.windowRuntime.selectedSession?.tree.focusedPane.activeTab)
        let view = try #require(harness.mount(tab))
        harness.report(tab, frame: harness.nextFrame())
        #expect(!view.isHidden)

        for _ in 0..<3 {
            harness.report(tab, frame: harness.nextFrame())
            #expect(!view.isHidden)
        }
        harness.report(tab, frame: .zero)
        #expect(!view.isHidden)
    }

    @Test func reportingAFrameNeverRevealsATabThatIsNotShown() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let pane = try #require(harness.windowRuntime.selectedSession?.tree.focusedPane)
        let first = try #require(pane.activeTab)
        _ = pane.addTab()
        let view = try #require(harness.mount(first))
        #expect(!harness.hostStore.isTabShown(first.id))

        let frame = harness.nextFrame()
        harness.report(first, frame: frame)
        harness.report(first, frame: harness.nextFrame())

        #expect(view.isHidden)
        #expect(view.frame != frame, "a hidden Tab's view was moved")
    }

    // MARK: - Pane hide and show

    @Test func hidingAPaneForgetsItsFrameSoShowWaitsForTheRemount() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let session = try #require(harness.windowRuntime.selectedSession)
        let pane = session.tree.focusedPane
        _ = session.tree.splitFocusedPane(direction: .horizontal)
        harness.mountAndReport(session)
        let tab = try #require(pane.activeTab)
        let view = try #require(tab.terminalNSView)
        #expect(!view.isHidden)

        harness.windowRuntime.hidePane(id: pane.id)
        #expect(view.isHidden)
        harness.windowRuntime.showPane(id: pane.id)

        #expect(harness.hostStore.isTabShown(tab.id))
        #expect(view.isHidden, "show revealed the view before the remount reported a frame")
        let frame = harness.nextFrame()
        harness.report(tab, frame: frame)
        #expect(!view.isHidden)
        #expect(view.frame == frame)
    }

    @Test func showingAPaneInABackgroundSessionRevealsNothing() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let windowRuntime = harness.windowRuntime
        let sessionB = windowRuntime.addSession()
        let paneB = sessionB.tree.focusedPane
        _ = sessionB.tree.splitFocusedPane(direction: .horizontal)
        windowRuntime.selectSession(at: 0)
        harness.mountAndReport(sessionB)
        windowRuntime.hidePane(id: paneB.id)

        windowRuntime.showPane(id: paneB.id)
        let tab = try #require(paneB.activeTab)
        harness.report(tab, frame: harness.nextFrame())

        #expect(!harness.hostStore.isTabShown(tab.id))
        #expect(try #require(tab.terminalNSView).isHidden)
    }

    // MARK: - Splits

    @Test func splittingABackgroundSessionsPaneKeepsTheNewTerminalHidden() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let windowRuntime = harness.windowRuntime
        let sessionB = windowRuntime.addSession()
        let paneB = sessionB.tree.focusedPane
        windowRuntime.selectSession(at: 0)

        let newID = try #require(harness.store.splitPane(id: paneB.id, direction: .horizontal))
        let newPane = try #require(sessionB.tree.allPanes.first { $0.id == newID })
        let tab = try #require(newPane.activeTab)
        let view = try #require(harness.mount(tab))
        harness.report(tab, frame: harness.nextFrame())

        #expect(!harness.hostStore.isTabShown(tab.id))
        #expect(view.isHidden)
    }

    @Test func splittingTheSelectedSessionsPaneRevealsTheNewTerminalOnItsFirstFrame() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let session = try #require(harness.windowRuntime.selectedSession)

        let newPane = session.tree.splitFocusedPane(direction: .vertical)
        let tab = try #require(newPane.activeTab)
        let view = try #require(harness.mount(tab))
        #expect(harness.hostStore.isTabShown(tab.id))
        #expect(view.isHidden)
        harness.report(tab, frame: harness.nextFrame())

        #expect(!view.isHidden)
    }

    // MARK: - Invariant

    @Test func onlyTheSelectedSessionsActiveTabsAreShownAfterEveryAction() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let windowRuntime = harness.windowRuntime
        let sessionA = try #require(windowRuntime.selectedSession)
        let paneA = sessionA.tree.focusedPane
        let sessionB = windowRuntime.addSession()
        let paneB = sessionB.tree.focusedPane

        func check(_ step: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let expected = harness.expectedShownTabIDs()
            for tab in harness.allTabs() {
                #expect(
                    harness.hostStore.isTabShown(tab.id) == expected.contains(tab.id),
                    "after \(step): tab \(tab.id) shown=\(harness.hostStore.isTabShown(tab.id))",
                    sourceLocation: sourceLocation
                )
            }
        }

        check("addSession")
        windowRuntime.selectSession(at: 0)
        check("select A")
        _ = paneA.addTab()
        check("add Tab")
        windowRuntime.selectPreviousTabInFocusedPane()
        check("switch Tab")
        let splitA = sessionA.tree.splitFocusedPane(direction: .horizontal)
        check("split selected")
        _ = harness.store.splitPane(id: paneB.id, direction: .vertical)
        check("split background")
        windowRuntime.hidePane(id: splitA.id)
        check("hide")
        windowRuntime.setSelectedSession(id: sessionB.id)
        check("switch Session")
        windowRuntime.setSelectedSession(id: sessionA.id)
        check("switch back")
        windowRuntime.showPane(id: splitA.id)
        check("show")
        harness.store.closeTab(id: paneA.activeTabID)
        check("close Tab")
    }

    @Test func releaseLeavesNoShownOrFrameEntry() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let pane = try #require(harness.windowRuntime.selectedSession?.tree.focusedPane)
        let mounted = try #require(pane.activeTab)
        harness.mount(mounted)
        harness.report(mounted, frame: harness.nextFrame())
        let neverMounted = pane.addTab()
        harness.report(neverMounted, frame: harness.nextFrame())
        #expect(harness.hostStore.isTabShown(neverMounted.id))
        #expect(!harness.hostStore.hasTerminalView(forTabID: neverMounted.id))

        harness.hostStore.releaseTerminalView(forTabID: mounted.id)
        harness.hostStore.releaseTerminalView(forTabID: neverMounted.id)

        for id in [mounted.id, neverMounted.id] {
            #expect(harness.hostStore.placement(forTabID: id) == nil)
            #expect(!harness.hostStore.isTabShown(id))
            #expect(harness.hostStore.reportedFrame(forTabID: id) == nil)
        }
    }
}
