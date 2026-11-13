// SessionDetailLayoutConvergenceTests.swift

import AppKit
import SwiftUI
import Testing
@testable import BattyKit

/// #0601: does the main window's session detail tree reach a layout fixed
/// point? Hosts the production `NavigationSplitView { SessionSidebarView }
/// detail: { SessionDetailView }` shape with terminal Panes, splits and
/// several mounted Sessions, and settles it through `LayoutConvergenceProbe`.
@MainActor
struct SessionDetailLayoutConvergenceTests {

    static let titledStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    private struct DetailTree: View {
        let store: AppStateStore
        let windowRuntime: WindowRuntime

        var body: some View {
            NavigationSplitView {
                SessionSidebarView(store: store, windowRuntime: windowRuntime)
            } detail: {
                SessionDetailView(store: store, windowRuntime: windowRuntime)
            }
            .environment(\.appStateStore, store)
            .environment(\.themeChrome, store.themeChrome)
        }
    }

    private struct Fixture {
        let store: AppStateStore
        let windowRuntime: WindowRuntime
        let probe: LayoutConvergenceProbe
        var testDefaults: TestDefaults?

        @MainActor
        func tearDown() {
            for session in windowRuntime.sessions {
                for pane in session.tree.allPanes {
                    for tab in pane.tabs {
                        TerminalHostStore.shared.releaseTerminalView(forTabID: tab.id)
                    }
                    pane.content?.tearDown()
                }
            }
            TerminalHostStore.shared.releaseHost(forWindowID: windowRuntime.id)
            probe.window.close()
        }
    }

    /// As in production, every Session stays mounted (non-selected ones at
    /// `opacity(0)`): one plain, one split in two, one split in three, one
    /// with two Tabs, plus `extraSessions` split in two.
    private func makeFixture(
        extraSessions: Int = 0,
        size: CGSize = CGSize(width: 1100, height: 700),
        store: AppStateStore = AppStateStore(),
        beforeHosting: (AppStateStore, WindowRuntime) -> Void = { _, _ in }
    ) -> Fixture {
        let windowRuntime = store.windows[0]
        let second = windowRuntime.addSession()
        if let paneID = second.tree.allPanes.first?.id {
            store.splitPane(id: paneID, direction: .horizontal)
        }
        let third = windowRuntime.addSession()
        if let paneID = third.tree.allPanes.first?.id {
            store.splitPane(id: paneID, direction: .vertical)
            store.splitPane(id: paneID, direction: .horizontal)
        }
        let fourth = windowRuntime.addSession()
        fourth.tree.allPanes.first?.addTab()
        for _ in 0..<extraSessions {
            let extra = windowRuntime.addSession()
            if let paneID = extra.tree.allPanes.first?.id {
                store.splitPane(id: paneID, direction: .horizontal)
            }
        }
        windowRuntime.selectSession(at: 0)
        beforeHosting(store, windowRuntime)
        let probe = LayoutConvergenceProbe(
            DetailTree(store: store, windowRuntime: windowRuntime),
            size: size,
            styleMask: Self.titledStyle
        )
        return Fixture(store: store, windowRuntime: windowRuntime, probe: probe)
    }

    private func terminalViewCount(_ fixture: Fixture) -> Int {
        fixture.probe.allViews().filter { NSStringFromClass(type(of: $0)).contains("AppTerminalView") }.count
    }

    // MARK: - Controls

    @Test func probeDetectsAConstraintFeedbackLoop() async {
        let probe = LayoutConvergenceProbe(
            ConstraintLoopControl(budget: 100_000).frame(width: 300, height: 200),
            size: CGSize(width: 500, height: 300)
        )
        defer { probe.window.close() }
        probe.window.postBreakerLimit = 50
        let result = await probe.settle()
        #expect(probe.allViews().count > 100)
        #expect(!result.converged, "control loop reported as converged: \(result)")
    }

    @Test func probeDetectsTheLoopInTheSplitTier() async {
        let probe = LayoutConvergenceProbe(
            NavigationSplitView { Text("Sidebar") } detail: {
                ConstraintLoopControl(budget: 100_000).frame(width: 300, height: 200)
            },
            size: CGSize(width: 900, height: 500),
            styleMask: Self.titledStyle
        )
        defer { probe.window.close() }
        probe.window.postBreakerLimit = 50
        let result = await probe.settle()
        #expect(probe.allViews().count > 100)
        #expect(!result.converged, "control loop in the detail column reported as converged: \(result)")
    }

    @Test func probeSeesABoundedLoopEndAndSettle() async {
        let probe = LayoutConvergenceProbe(
            ConstraintLoopControl(budget: 40).frame(width: 300, height: 200),
            size: CGSize(width: 500, height: 300)
        )
        defer { probe.window.close() }
        let result = await probe.settle()
        #expect(result.converged, "\(result)")
        #expect(result.postNeedsUpdateConstraintsCalls >= 40, "the probe did not see the loop's requests: \(result)")
    }

    /// SwiftUI damps an `onGeometryChange` write that flips the geometry it
    /// measures, so this deliberate loop settles.
    @Test func swiftUIDampsAGeometryFeedbackLoop() async {
        let probe = LayoutConvergenceProbe(GeometryFeedbackLoopView(), size: CGSize(width: 500, height: 300))
        defer { probe.window.close() }
        let result = await probe.settle()
        #expect(result.converged, "\(result)")
    }

    @Test(arguments: [NSScroller.Style.legacy, .overlay])
    func probeSeesConvergenceForAPlainScrollView(style: NSScroller.Style) async {
        let probe = LayoutConvergenceProbe(PlainScrollViewControl(), size: CGSize(width: 400, height: 300))
        defer { probe.window.close() }
        _ = await probe.settle()
        probe.forceScrollerStyle(style)
        let result = await probe.settle()
        #expect(result.converged, "plain ScrollView did not converge: \(result)")
    }

    // MARK: - Session detail tree

    @Test(arguments: [0, 12])
    func sessionDetailTreeConvergesAcrossSizesAndSessionSwitches(extraSessions: Int) async {
        let fixture = makeFixture(extraSessions: extraSessions)
        defer { fixture.tearDown() }
        let first = await fixture.probe.settle()
        #expect(first.converged, "first settle: \(first)")
        #expect(terminalViewCount(fixture) >= 8 + extraSessions * 2, "terminal views were not mounted")

        let sizes = [CGSize(width: 800, height: 520), CGSize(width: 1400, height: 900), CGSize(width: 960, height: 640)]
        for size in sizes {
            fixture.probe.resize(to: size)
            let result = await fixture.probe.settle()
            #expect(result.converged, "resize to \(size): \(result)")
            for index in [1, 2, 3, 0] {
                fixture.windowRuntime.selectSession(at: index)
                let switched = await fixture.probe.settle()
                #expect(switched.converged, "size \(size), Session \(index): \(switched)")
            }
        }
    }

    // MARK: - Session switch request volume

    /// A loose regression guard on `_postWindowNeedsUpdateConstraints`
    /// requests per Session switch, keyed by `extraSessions`. Measured with
    /// each case run alone: 444 and 660 at most before the selection effects
    /// moved out of `SessionDetailView`'s `onChange` into
    /// `WindowRuntime.selectedSessionID`'s `didSet`, and the same maxima
    /// after (issues/0602.md). Nearly all of a switch's requests come from
    /// the selection change itself, so the ceilings are that baseline plus
    /// about 17%, to catch side effects or a second update round coming
    /// back into layout without failing on run-to-run noise. `.serialized`
    /// because two cases settling at once interleave their counts.
    private static let switchRequestCeiling: [Int: Int] = [0: 520, 12: 770]

    @Test(.serialized, arguments: [0, 12])
    func sessionSwitchUpdateConstraintRequestsStayUnderCeiling(extraSessions: Int) async throws {
        let themes = Array(BattyThemeCatalog.allThemes.prefix(2))
        let global = try #require(themes.first)
        let sessionTheme = try #require(themes.last)
        #expect(global.name != sessionTheme.name)
        let testDefaults = TestDefaults()
        let defaults = testDefaults.defaults
        defaults.set(true, forKey: ThemePreference.migrationDoneKey)
        defaults.set(global.name, forKey: ThemePreference.darkDefaultsKey)
        defaults.set(global.name, forKey: ThemePreference.lightDefaultsKey)
        let store = AppStateStore(preferences: defaults)
        store.isBattyActiveProvider = { false }
        var decisions: [Bool] = []

        var fixture = makeFixture(extraSessions: extraSessions, store: store) { store, windowRuntime in
            windowRuntime.sessions[2].themeOverride = ThemePair(dark: sessionTheme.name, light: sessionTheme.name)
            for index in 1...3 {
                if let tab = windowRuntime.sessions[index].focusedPaneAnyKind.activeTab {
                    store.ringBell(in: tab, times: 2)
                }
            }
            windowRuntime.sessions[0].requestClipboardReadConfirmation(kind: .osc52Read) { decisions.append($0) }
        }
        fixture.testDefaults = testDefaults
        defer { fixture.tearDown() }
        let windowRuntime = fixture.windowRuntime
        for index in 1...3 {
            #expect(windowRuntime.sessions[index].unseenBellCount == 2, "Session \(index) fixture has no unseen bells")
        }
        #expect(windowRuntime.sessions[0].pendingClipboardConfirmation != nil)

        _ = await fixture.probe.settle()
        let first = await fixture.probe.settle()
        #expect(first.converged, "first settle: \(first)")

        var perSwitch: [Int] = []
        var paletteAfter: [Int: ChromePalette] = [:]
        for index in [1, 2, 3, 0] {
            windowRuntime.selectSession(at: index)
            let switched = await fixture.probe.settle()
            #expect(switched.converged, "Session \(index): \(switched)")
            perSwitch.append(switched.postNeedsUpdateConstraintsCalls)
            paletteAfter[index] = store.themeChrome.palette
        }

        for index in 1...3 {
            #expect(windowRuntime.sessions[index].unseenBellCount == 0, "Session \(index) was not marked seen")
        }
        #expect(paletteAfter[2] == ChromePalette(theme: sessionTheme), "the Session Theme did not reach the chrome")
        #expect(paletteAfter[3] == ChromePalette(theme: global), "the chrome did not return to the global Theme")
        #expect(decisions == [false], "Session 0's clipboard request was not denied")
        let ceiling = try #require(Self.switchRequestCeiling[extraSessions])
        #expect((perSwitch.max() ?? 0) <= ceiling, "extraSessions=\(extraSessions) perSwitch=\(perSwitch) ceiling=\(ceiling)")
    }

    // MARK: - Terminal placement

    private func viewsNeedingUpdateConstraints(_ fixture: Fixture) -> [String] {
        fixture.probe.allViews().filter(\.needsUpdateConstraints).map { String(NSStringFromClass(type(of: $0)).prefix(80)) }
    }

    /// `TerminalPlaceholderView` calls `TerminalHostStore.setPlacement` from
    /// `onGeometryChange`, inside SwiftUI's layout pass, for every Tab in
    /// every mounted Session. That is safe only if a placement write is
    /// frame-only: it must not mark any view in the window as needing update
    /// constraints, or each placement asks AppKit for another pass of the
    /// window it is laying out.
    @Test func terminalPlacementWriteMarksNoViewAsNeedingUpdateConstraints() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        _ = await fixture.probe.settle()
        let settled = await fixture.probe.settle()
        #expect(settled.converged, "baseline: \(settled)")
        #expect(viewsNeedingUpdateConstraints(fixture).isEmpty)

        let session = fixture.windowRuntime.sessions[0]
        let tab = try #require(session.tree.allPanes.first?.activeTab)
        let terminal = try #require(TerminalHostStore.shared.terminalView(for: tab, windowID: fixture.windowRuntime.id))
        #expect(terminal.window === fixture.probe.window)
        let original = terminal.frame
        #expect(original.width > 0 && original.height > 0)
        let moved = original.insetBy(dx: 10, dy: 10)

        TerminalHostStore.shared.setPlacement(.init(frame: moved, isVisible: true), forTabID: tab.id)
        let afterFrame = viewsNeedingUpdateConstraints(fixture)
        fixture.probe.window.layoutIfNeeded()
        #expect(terminal.frame == moved, "layout moved the terminal off its placement")
        _ = await fixture.probe.settle()

        TerminalHostStore.shared.setPlacement(.init(frame: original, isVisible: false), forTabID: tab.id)
        let afterHide = viewsNeedingUpdateConstraints(fixture)
        _ = await fixture.probe.settle()

        TerminalHostStore.shared.setPlacement(.init(frame: original, isVisible: true), forTabID: tab.id)
        let afterShow = viewsNeedingUpdateConstraints(fixture)
        _ = await fixture.probe.settle()

        #expect(afterFrame.isEmpty, "frame placement marked \(afterFrame.count) views: \(afterFrame)")
        #expect(afterHide.isEmpty, "hide placement marked \(afterHide.count) views: \(afterHide)")
        #expect(afterShow.isEmpty, "show placement marked \(afterShow.count) views: \(afterShow)")
    }
}
