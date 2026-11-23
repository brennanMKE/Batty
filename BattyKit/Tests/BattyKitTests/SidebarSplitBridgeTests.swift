// SidebarSplitBridgeTests.swift

import AppKit
import SwiftUI
import Testing
@testable import BattyKit

/// The `compactSidebar` experiment's headless question: does the
/// `NSSplitView` behind `NavigationSplitView` hold the rail width set through
/// `setPosition`, and come back to the names width?
@MainActor
@Suite(.serialized)
struct SidebarSplitBridgeTests {
    /// Every width the detail column's content is laid out at, recorded the
    /// way a terminal view sees it (`setFrameSize`) and the way SwiftUI
    /// reports it (`onGeometryChange`).
    final class DetailWidths {
        var frames: [CGFloat] = []
        var geometry: [CGFloat] = []
    }

    private final class FrameRecorderView: NSView {
        let widths: DetailWidths
        init(widths: DetailWidths) {
            self.widths = widths
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
        override func setFrameSize(_ newSize: NSSize) {
            if newSize.width != frame.width { widths.frames.append(newSize.width) }
            super.setFrameSize(newSize)
        }
    }

    private struct FrameRecorder: NSViewRepresentable {
        let widths: DetailWidths
        func makeNSView(context: Context) -> FrameRecorderView { FrameRecorderView(widths: widths) }
        func updateNSView(_ nsView: FrameRecorderView, context: Context) {}
    }

    /// `RootWindowView`'s shape: ⌘B toggles `columnVisibility`, and the
    /// bridge sees the same post first-hand.
    private struct Tree: View {
        let store: AppStateStore
        let windowRuntime: WindowRuntime
        let railWidth: CGFloat
        let widths: DetailWidths
        @State private var columnVisibility: NavigationSplitViewVisibility = .all

        var body: some View {
            let range = SidebarRailMetrics.columnRange(
                compactSidebar: true,
                style: windowRuntime.sidebarStyle,
                railWidth: railWidth
            )
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SessionSidebarView(store: store, windowRuntime: windowRuntime)
                    .navigationSplitViewColumnWidth(min: range.min, ideal: range.ideal, max: range.max)
            } detail: {
                FrameRecorder(widths: widths)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.geometry.append($0) }
                    .background(SidebarSplitBridge(windowRuntime: windowRuntime, store: store, railWidth: railWidth))
            }
            .environment(\.appStateStore, store)
            .onReceive(NotificationCenter.default.publisher(for: .battyToggleSidebar)) { _ in
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
    }

    private final class Fixture {
        let store: AppStateStore
        let windowRuntime: WindowRuntime
        let probe: LayoutConvergenceProbe
        let widths = DetailWidths()

        init(railWidth: CGFloat = SidebarRailMetrics.defaultRail) {
            store = AppStateStore(featureFlags: FeatureFlags(sharedProjectImages: false, compactSidebar: true))
            windowRuntime = store.windows[0]
            windowRuntime.addSession()
            probe = LayoutConvergenceProbe(
                Tree(store: store, windowRuntime: windowRuntime, railWidth: railWidth, widths: widths),
                size: CGSize(width: 1100, height: 700),
                styleMask: SessionDetailFixture.titledStyle
            )
        }

        func bridge() throws -> SidebarSplitBridgeView {
            try #require(probe.allViews().compactMap { $0 as? SidebarSplitBridgeView }.first)
        }

        func settled(keyTarget: Bool = true) async throws -> SidebarSplitBridgeView {
            _ = await probe.settle()
            _ = await probe.settle()
            let bridge = try bridge()
            bridge.isKeyTarget = { keyTarget }
            return bridge
        }

        func tearDown() {
            for session in windowRuntime.sessions {
                for pane in session.tree.allPanes {
                    for tab in pane.tabs {
                        TerminalHostStore.shared.releaseTerminalView(forTabID: tab.id)
                    }
                    pane.content?.tearDown()
                }
            }
            probe.window.close()
        }
    }

    private func width(_ bridge: SidebarSplitBridgeView) throws -> CGFloat {
        try #require(bridge.sidebarWidth)
    }

    @Test func bridgeFindsTheNavigationSplitViewSplitView() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let bridge = try await fixture.settled()
        let splitView = try #require(bridge.splitView)
        #expect(splitView.arrangedSubviews.count >= 2)
        #expect(abs(try width(bridge) - SidebarRailMetrics.ideal) < 2, "starts at ideal")
    }

    @Test func styleCommandNarrowsTheColumnToTheRail() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let bridge = try await fixture.settled()
        NotificationCenter.default.post(name: .battyToggleSidebarStyle, object: nil)
        #expect(fixture.windowRuntime.sidebarStyle == .symbols)
        let settle = await fixture.probe.settle()
        #expect(settle.converged, "\(settle)")
        #expect(abs(try width(bridge) - SidebarRailMetrics.defaultRail) < 1, "width \(bridge.sidebarWidth ?? -1)")
    }

    @Test func wideRailWidthHolds() async throws {
        let fixture = Fixture(railWidth: SidebarRailMetrics.wideRail)
        defer { fixture.tearDown() }
        let bridge = try await fixture.settled()
        bridge.apply(.symbols)
        _ = await fixture.probe.settle()
        #expect(abs(try width(bridge) - SidebarRailMetrics.wideRail) < 1)
    }

    @Test func styleCommandBackRestoresThePriorNamesWidth() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let bridge = try await fixture.settled()
        try #require(bridge.splitView).setPosition(260, ofDividerAt: 0)
        _ = await fixture.probe.settle()
        #expect(abs(try width(bridge) - 260) < 1)

        bridge.apply(.symbols)
        _ = await fixture.probe.settle()
        #expect(abs(try width(bridge) - SidebarRailMetrics.defaultRail) < 1, "width \(bridge.sidebarWidth ?? -1)")

        bridge.apply(.names)
        _ = await fixture.probe.settle()
        #expect(fixture.windowRuntime.sidebarStyle == .names)
        #expect(abs(try width(bridge) - 260) < 1)
    }

    @Test func styleCommandIgnoredWhenNotKeyTarget() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let bridge = try await fixture.settled(keyTarget: false)
        let before = try width(bridge)
        NotificationCenter.default.post(name: .battyToggleSidebarStyle, object: nil)
        _ = await fixture.probe.settle()
        #expect(fixture.windowRuntime.sidebarStyle == .names)
        #expect(abs(try width(bridge) - before) < 1)
    }

    @Test func dividerDragEndBelowThresholdSnapsToRail() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let bridge = try await fixture.settled()
        let start = try width(bridge)
        bridge.beginDividerDrag()
        try #require(bridge.splitView).setPosition(100, ofDividerAt: 0)
        bridge.finishDividerDrag(startWidth: start)
        _ = await fixture.probe.settle()
        #expect(fixture.windowRuntime.sidebarStyle == .symbols)
        #expect(abs(try width(bridge) - SidebarRailMetrics.defaultRail) < 1, "width \(bridge.sidebarWidth ?? -1)")
        #expect(bridge.lastNamesWidth.map { abs($0 - start) < 1 } == true)
    }

    @Test func dividerDragEndBetweenThresholdAndMinimumSnapsTo180() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let bridge = try await fixture.settled()
        bridge.beginDividerDrag()
        try #require(bridge.splitView).setPosition(150, ofDividerAt: 0)
        bridge.finishDividerDrag()
        _ = await fixture.probe.settle()
        #expect(fixture.windowRuntime.sidebarStyle == .names)
        #expect(abs(try width(bridge) - SidebarRailMetrics.namesMin) < 1)
        #expect(try item(bridge).minimumThickness == SidebarRailMetrics.namesMin)
    }

    @Test func dividerDragEndFromRailPastThresholdRestoresNames() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let bridge = try await fixture.settled()
        bridge.apply(.symbols)
        _ = await fixture.probe.settle()
        bridge.beginDividerDrag()
        try #require(bridge.splitView).setPosition(240, ofDividerAt: 0)
        bridge.finishDividerDrag()
        _ = await fixture.probe.settle()
        #expect(fixture.windowRuntime.sidebarStyle == .names)
        #expect(abs(try width(bridge) - 240) < 1)
    }

    private func item(_ bridge: SidebarSplitBridgeView) throws -> NSSplitViewItem {
        try #require((bridge.splitView?.delegate as? NSSplitViewController)?.splitViewItems.first)
    }

    /// Names keeps today's minimum, so a new window can't open its names
    /// column at the rail's minimum; the rail lowers it.
    @Test func splitViewItemMinimumFollowsTheStyle() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let bridge = try await fixture.settled()
        #expect(try item(bridge).minimumThickness == SidebarRailMetrics.namesMin)
        #expect(try item(bridge).maximumThickness == SidebarRailMetrics.max)

        bridge.apply(.symbols)
        _ = await fixture.probe.settle()
        #expect(try item(bridge).minimumThickness == SidebarRailMetrics.defaultRail)

        bridge.apply(.names)
        _ = await fixture.probe.settle()
        #expect(try item(bridge).minimumThickness == SidebarRailMetrics.namesMin)
        #expect(abs(try width(bridge) - SidebarRailMetrics.ideal) < 1)
    }

    /// A names column moved below 180 outside a drag is held at 180.
    @Test func namesColumnCannotRestBelowItsMinimum() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let bridge = try await fixture.settled()
        try #require(bridge.splitView).setPosition(60, ofDividerAt: 0)
        _ = await fixture.probe.settle()
        #expect(try width(bridge) >= SidebarRailMetrics.namesMin - 0.5, "width \(bridge.sidebarWidth ?? -1)")
    }

    @Test func dividerDragEndThatKeepsNamesRestoresTheNamesMinimum() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let bridge = try await fixture.settled()
        bridge.beginDividerDrag()
        #expect(try item(bridge).minimumThickness == SidebarRailMetrics.defaultRail)
        try #require(bridge.splitView).setPosition(250, ofDividerAt: 0)
        bridge.finishDividerDrag()
        _ = await fixture.probe.settle()
        #expect(fixture.windowRuntime.sidebarStyle == .names)
        #expect(try item(bridge).minimumThickness == SidebarRailMetrics.namesMin)
        #expect(abs(try width(bridge) - 250) < 1)
    }

    private func toggleSidebar(_ fixture: Fixture) async {
        NotificationCenter.default.post(name: .battyToggleSidebar, object: nil)
        _ = await fixture.probe.settle()
        _ = await fixture.probe.settle()
    }

    /// ⌥⌘B never shows or hides the Sidebar: while hidden it switches the
    /// style only, and the next ⌘B show comes back in that style.
    @Test func styleCommandWhileHiddenKeepsItHiddenAndNextShowUsesTheNewStyle() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let bridge = try await fixture.settled()
        try #require(bridge.splitView).setPosition(260, ofDividerAt: 0)
        _ = await fixture.probe.settle()
        let start = try width(bridge)
        #expect(abs(start - 260) < 1)
        await toggleSidebar(fixture)
        #expect(bridge.isSidebarCollapsed)

        NotificationCenter.default.post(name: .battyToggleSidebarStyle, object: nil)
        _ = await fixture.probe.settle()
        #expect(fixture.windowRuntime.sidebarStyle == .symbols)
        #expect(bridge.isSidebarCollapsed, "the style command must not show the hidden Sidebar")

        await toggleSidebar(fixture)
        #expect(!bridge.isSidebarCollapsed)
        #expect(abs(try width(bridge) - SidebarRailMetrics.defaultRail) < 1, "shows as the rail: \(bridge.sidebarWidth ?? -1)")
        #expect(try item(bridge).minimumThickness == SidebarRailMetrics.defaultRail)
        #expect(try item(bridge).maximumThickness == SidebarRailMetrics.max)

        await toggleSidebar(fixture)
        #expect(bridge.isSidebarCollapsed)
        NotificationCenter.default.post(name: .battyToggleSidebarStyle, object: nil)
        _ = await fixture.probe.settle()
        #expect(fixture.windowRuntime.sidebarStyle == .names)
        #expect(bridge.isSidebarCollapsed)

        await toggleSidebar(fixture)
        #expect(abs(try width(bridge) - start) < 1, "shows names at the earlier width \(start): \(bridge.sidebarWidth ?? -1)")
        #expect(try item(bridge).minimumThickness == SidebarRailMetrics.namesMin)
        #expect(try item(bridge).maximumThickness == SidebarRailMetrics.max)
    }

    /// A style command while hidden lays nothing out in the detail column, so
    /// no terminal is resized; the next ⌘B show resizes it once, to its final
    /// width.
    @Test func styleCommandWhileHiddenResizesNoDetailContent() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let bridge = try await fixture.settled()
        await toggleSidebar(fixture)
        #expect(bridge.isSidebarCollapsed)
        let hiddenWidth = try #require(fixture.widths.frames.last)

        fixture.widths.frames.removeAll()
        fixture.widths.geometry.removeAll()
        NotificationCenter.default.post(name: .battyToggleSidebarStyle, object: nil)
        #expect(fixture.widths.frames.isEmpty, "inside the post: \(fixture.widths.frames)")
        _ = await fixture.probe.settle()
        _ = await fixture.probe.settle()
        #expect(fixture.windowRuntime.sidebarStyle == .symbols)
        #expect(bridge.isSidebarCollapsed)
        #expect(fixture.widths.frames.isEmpty, "frames: \(fixture.widths.frames)")
        #expect(fixture.widths.geometry.isEmpty, "geometry: \(fixture.widths.geometry)")

        await toggleSidebar(fixture)
        let shown = try width(bridge)
        #expect(abs(shown - SidebarRailMetrics.defaultRail) < 1, "width \(shown)")
        #expect(fixture.widths.frames.count == 1, "one resize on show: \(fixture.widths.frames)")
        #expect(fixture.widths.frames.allSatisfy { $0 < hiddenWidth - shown + 1 }, "frames: \(fixture.widths.frames)")
        #expect(fixture.widths.geometry.count <= 1, "geometry: \(fixture.widths.geometry)")
    }

    @Test func bridgeViewIsHitTestTransparent() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let bridge = try await fixture.settled()
        #expect(bridge.hitTest(NSPoint(x: bridge.bounds.midX, y: bridge.bounds.midY)) == nil)
    }
}
