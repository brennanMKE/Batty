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

    static let titledStyle = SessionDetailFixture.titledStyle

    private typealias Fixture = SessionDetailFixture

    private func makeFixture(
        extraSessions: Int = 0,
        size: CGSize = CGSize(width: 1100, height: 700),
        store: AppStateStore = AppStateStore(),
        beforeHosting: (AppStateStore, WindowRuntime) -> Void = { _, _ in }
    ) -> Fixture {
        SessionDetailFixture.standard(extraSessions: extraSessions, size: size, store: store, beforeHosting: beforeHosting)
    }

    private func terminalViewCount(_ fixture: Fixture) -> Int {
        fixture.terminalViewCount()
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
    /// back into layout without failing on run-to-run noise. A strict
    /// majority of the four switches must be under the ceiling
    /// (`LayoutConvergenceProbe.mostlyWithin`). `.serialized` because two
    /// cases settling at once interleave their counts.
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
            paletteAfter[index] = store.chromePalette(for: windowRuntime)
        }

        for index in 1...3 {
            #expect(windowRuntime.sessions[index].unseenBellCount == 0, "Session \(index) was not marked seen")
        }
        #expect(paletteAfter[2] == ChromePalette(theme: sessionTheme), "the Session Theme did not reach the chrome")
        #expect(paletteAfter[3] == ChromePalette(theme: global), "the chrome did not return to the global Theme")
        #expect(decisions == [false], "Session 0's clipboard request was not denied")
        let ceiling = try #require(Self.switchRequestCeiling[extraSessions])
        #expect(
            LayoutConvergenceProbe.mostlyWithin(perSwitch, ceiling: ceiling),
            "extraSessions=\(extraSessions) perSwitch \(LayoutConvergenceProbe.budgetReport(perSwitch, ceiling: ceiling))"
        )
    }

    /// How much more a switch among the same four Sessions may request with
    /// 12 more Sessions in the window than without them: the measured 192
    /// plus 20 for noise. Before #0604 the difference was 216. Measured with
    /// the Sidebar alone, a switch re-runs only the two changed rows' bodies,
    /// yet still costs about 16 requests per row: about 12 go away only when
    /// the `List(selection:)` binding's value stops changing, and about 4
    /// remain even then. Lower this when that cost is removed.
    private static let sessionCountMargin = 212

    /// Per-switch request counts for two runs of `[1, 2, 3, 0]`, in order.
    private func switchRequests(extraSessions: Int) async -> [Int] {
        let fixture = makeFixture(extraSessions: extraSessions)
        defer { fixture.tearDown() }
        _ = await fixture.probe.settle()
        _ = await fixture.probe.settle()
        var perSwitch: [Int] = []
        for _ in 0..<2 {
            for index in [1, 2, 3, 0] {
                fixture.windowRuntime.selectSession(at: index)
                let switched = await fixture.probe.settle()
                #expect(switched.converged, "extraSessions=\(extraSessions), Session \(index): \(switched)")
                perSwitch.append(switched.postNeedsUpdateConstraintsCalls)
            }
        }
        return perSwitch
    }

    /// #0604: Sidebar rows read the per-Session `SessionRuntime.isSelected`,
    /// so a switch re-renders only the two rows it crosses instead of every
    /// row comparing itself against `selectedSessionID`. Before the fix, 16
    /// Sessions requested 216 more than 4; after it, 192 more. The rest is
    /// the `List` selection binding (see `sessionCountMargin`). Each of the
    /// eight switches is compared with the same switch among 4 Sessions, and
    /// a strict majority of the differences must be within the margin
    /// (`LayoutConvergenceProbe.mostlyWithin`).
    @Test func sessionSwitchRequestsDoNotScaleWithSessionCount() async {
        let four = await switchRequests(extraSessions: 0)
        let sixteen = await switchRequests(extraSessions: 12)
        let differences = zip(sixteen, four).map { $0 - $1 }
        #expect(
            LayoutConvergenceProbe.mostlyWithin(differences, ceiling: Self.sessionCountMargin),
            "4 Sessions \(four); 16 Sessions \(sixteen); differences \(LayoutConvergenceProbe.budgetReport(differences, ceiling: Self.sessionCountMargin))"
        )
    }

    // MARK: - Divider drag request volume

    /// A loose regression guard on `_postWindowNeedsUpdateConstraints`
    /// requests per divider-drag tick (`SplitTree.updateRatio`), keyed by
    /// `extraSessions`, with the Session split in three selected. Measured:
    /// 57 and 105 per tick before split ratios moved into a per-split
    /// `SplitRatio` box, when every tick reassigned `SplitTree.root` and
    /// re-rendered every reader of the tree's structure; 25 and 36 at most
    /// after (issues/0607.md). The ceilings are the after maxima plus about
    /// 17%. A strict majority of the six ticks must be under the ceiling
    /// (`LayoutConvergenceProbe.mostlyWithin`); before #0607 every tick was
    /// over. `.serialized` because two cases settling at once interleave
    /// their counts.
    private static let dividerTickRequestCeiling: [Int: Int] = [0: 30, 12: 42]

    @Test(.serialized, arguments: [0, 12])
    func dividerDragTickRequestsStayUnderCeiling(extraSessions: Int) async throws {
        let fixture = makeFixture(extraSessions: extraSessions)
        defer { fixture.tearDown() }
        let windowRuntime = fixture.windowRuntime
        windowRuntime.selectSession(at: 2)
        _ = await fixture.probe.settle()
        let first = await fixture.probe.settle()
        #expect(first.converged, "first settle: \(first)")

        let tree = windowRuntime.sessions[2].tree
        guard case .split(let splitID, _, _, _, _) = tree.root else {
            Issue.record("Session 2 has no split root")
            return
        }
        var perTick: [Int] = []
        for ratio in [0.30, 0.35, 0.40, 0.45, 0.50, 0.55] {
            tree.updateRatio(forSplitID: splitID, to: ratio)
            let ticked = await fixture.probe.settle()
            #expect(ticked.converged, "ratio \(ratio): \(ticked)")
            perTick.append(ticked.postNeedsUpdateConstraintsCalls)
        }
        let ceiling = try #require(Self.dividerTickRequestCeiling[extraSessions])
        #expect(
            LayoutConvergenceProbe.mostlyWithin(perTick, ceiling: ceiling),
            "extraSessions=\(extraSessions) perTick \(LayoutConvergenceProbe.budgetReport(perTick, ceiling: ceiling))"
        )
    }

    // MARK: - Window resize request volume

    /// A loose regression guard on `_postWindowNeedsUpdateConstraints`
    /// requests per window resize, keyed by `extraSessions`. Measured with
    /// each case run alone: [11, 0, 0] for both cases before `PaneView`'s
    /// frame and width moved out of its `@State`, and the same after
    /// (issues/0610.md); these requests do not count body re-evaluations,
    /// so the guard does not distinguish the two. A full-suite run saw 22,
    /// so the ceilings are that maximum plus about 17%. A strict majority of
    /// the three resizes must be under the ceiling
    /// (`LayoutConvergenceProbe.mostlyWithin`). `.serialized` because two
    /// cases settling at once interleave their counts.
    private static let resizeRequestCeiling: [Int: Int] = [0: 26, 12: 26]

    @Test(.serialized, arguments: [0, 12])
    func resizeUpdateConstraintRequestsStayUnderCeiling(extraSessions: Int) async throws {
        let fixture = makeFixture(extraSessions: extraSessions)
        defer { fixture.tearDown() }
        _ = await fixture.probe.settle()
        let first = await fixture.probe.settle()
        #expect(first.converged, "first settle: \(first)")

        var perResize: [Int] = []
        let sizes = [CGSize(width: 800, height: 520), CGSize(width: 1400, height: 900), CGSize(width: 960, height: 640)]
        for size in sizes {
            fixture.probe.resize(to: size)
            let resized = await fixture.probe.settle()
            #expect(resized.converged, "resize to \(size): \(resized)")
            perResize.append(resized.postNeedsUpdateConstraintsCalls)
        }
        let ceiling = try #require(Self.resizeRequestCeiling[extraSessions])
        #expect(
            LayoutConvergenceProbe.mostlyWithin(perResize, ceiling: ceiling),
            "extraSessions=\(extraSessions) perResize \(LayoutConvergenceProbe.budgetReport(perResize, ceiling: ceiling))"
        )
    }

    // MARK: - Terminal placement

    private func viewsNeedingUpdateConstraints(_ fixture: Fixture) -> [String] {
        fixture.probe.allViews().filter(\.needsUpdateConstraints).map { String(NSStringFromClass(type(of: $0)).prefix(80)) }
    }

    /// `TerminalPlaceholderView` calls `TerminalHostStore.reportFrame` from
    /// `onGeometryChange`, inside SwiftUI's layout pass, for every Tab in
    /// every mounted Session. That is safe only if a frame write (and the
    /// reveal it can make) marks no view in the window as needing update
    /// constraints, or each report asks AppKit for another pass of the window
    /// it is laying out. The hide and show steps run in actions since #0605,
    /// and must not dirty constraints either.
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
        // Hiding the first responder resigns it, and any first-responder
        // change marks the hosting views as needing update constraints. That
        // resign belongs to the hide action and is covered by the
        // `...DoesNotChangeFirstResponderDuringLayout` tests below. Whether
        // the terminal is first responder here depends on whether the
        // selection's deferred focus request has landed yet, so take it out
        // of the measurement.
        fixture.probe.window.makeFirstResponder(nil)
        _ = await fixture.probe.settle()
        #expect(viewsNeedingUpdateConstraints(fixture).isEmpty)
        let original = terminal.frame
        #expect(original.width > 0 && original.height > 0)
        let moved = original.insetBy(dx: 10, dy: 10)

        #expect(TerminalHostStore.shared.isTabShown(tab.id))
        TerminalHostStore.shared.reportFrame(moved, forTabID: tab.id)
        let afterFrame = viewsNeedingUpdateConstraints(fixture)
        fixture.probe.window.layoutIfNeeded()
        #expect(terminal.frame == moved, "layout moved the terminal off its placement")
        _ = await fixture.probe.settle()

        TerminalHostStore.shared.setTabShown(false, forTabID: tab.id)
        #expect(terminal.isHidden)
        let afterHide = viewsNeedingUpdateConstraints(fixture)
        _ = await fixture.probe.settle()

        TerminalHostStore.shared.setTabShown(true, forTabID: tab.id)
        #expect(!terminal.isHidden)
        let afterShow = viewsNeedingUpdateConstraints(fixture)
        _ = await fixture.probe.settle()

        #expect(afterFrame.isEmpty, "frame placement marked \(afterFrame.count) views: \(afterFrame)")
        #expect(afterHide.isEmpty, "hide placement marked \(afterHide.count) views: \(afterHide)")
        #expect(afterShow.isEmpty, "show placement marked \(afterShow.count) views: \(afterShow)")
    }

    // MARK: - First responder during layout (#0605)

    /// Makes `tab`'s terminal the probe window's first responder, drives
    /// `action`, and checks that the outgoing terminal was hidden and resigned
    /// by the action itself, so the settle that follows changes no first
    /// responder inside layout and never strands it on a non-terminal.
    private func assertSwitchKeepsResponderChangesOutOfLayout(
        _ fixture: Fixture,
        outgoing tab: TabRuntime,
        action: () -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let window = fixture.probe.window
        let terminal = try #require(tab.terminalNSView, sourceLocation: sourceLocation)
        #expect(!terminal.isHidden, "fixture: the outgoing terminal is not on screen", sourceLocation: sourceLocation)
        #expect(window.makeFirstResponder(terminal), sourceLocation: sourceLocation)
        #expect(window.firstResponder === terminal, sourceLocation: sourceLocation)
        window.resetResponderChanges()

        action()

        #expect(terminal.isHidden, "the action did not hide the outgoing terminal", sourceLocation: sourceLocation)
        #expect(window.firstResponder !== terminal, "the outgoing terminal is still first responder after the action", sourceLocation: sourceLocation)
        let afterAction = window.responderChanges.count

        _ = await fixture.probe.settle()

        let duringSettle = Array(window.responderChanges.dropFirst(afterAction))
        let inLayout = duringSettle.filter(\.inLayout)
        #expect(inLayout.isEmpty, "first responder changed inside layout: \(inLayout)", sourceLocation: sourceLocation)
        let stranded = duringSettle.filter { $0.previousIsTerminal && !$0.argumentIsTerminal }
        #expect(stranded.isEmpty, "the settle moved first responder off a terminal: \(stranded)", sourceLocation: sourceLocation)
    }

    @Test func tabSwitchDoesNotChangeFirstResponderDuringLayout() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let windowRuntime = fixture.windowRuntime
        windowRuntime.selectSession(at: 3)
        _ = await fixture.probe.settle()
        _ = await fixture.probe.settle()
        let pane = try #require(windowRuntime.selectedSession?.focusedTerminalPane)
        #expect(pane.tabs.count == 2)
        let outgoing = try #require(pane.activeTab)

        try await assertSwitchKeepsResponderChangesOutOfLayout(fixture, outgoing: outgoing) {
            windowRuntime.selectNextTabInFocusedPane()
        }
        #expect(pane.activeTabID != outgoing.id)
    }

    @Test func sessionSwitchDoesNotChangeFirstResponderDuringLayout() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let windowRuntime = fixture.windowRuntime
        _ = await fixture.probe.settle()
        _ = await fixture.probe.settle()
        let outgoing = try #require(windowRuntime.selectedSession?.focusedTerminalPane?.activeTab)

        try await assertSwitchKeepsResponderChangesOutOfLayout(fixture, outgoing: outgoing) {
            windowRuntime.selectSession(at: 1)
        }
        #expect(windowRuntime.selectedSessionID == windowRuntime.sessions[1].id)
    }
}
