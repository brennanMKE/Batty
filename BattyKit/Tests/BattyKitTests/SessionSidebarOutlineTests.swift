// SessionSidebarOutlineTests.swift

import AppKit
import SwiftUI
import Testing
@testable import BattyKit

/// #0619: the Sidebar's `NSOutlineView` keeps `List`'s selection, keyboard,
/// type-select, disclosure and reorder behaviour, with the model and the
/// outline synced in both directions.
@MainActor
struct SessionSidebarOutlineTests {

    private struct SeeThroughTree: View {
        let store: AppStateStore
        let windowRuntime: WindowRuntime

        var body: some View {
            NavigationSplitView {
                SessionSidebarView(store: store, windowRuntime: windowRuntime)
            } detail: {
                Color.clear
            }
            .environment(\.windowIsSeeThrough, true)
            .environment(\.appStateStore, store)
        }
    }

    private func outline(in probe: LayoutConvergenceProbe) throws -> SessionSidebarOutlineView {
        try #require(probe.allViews().compactMap { $0 as? SessionSidebarOutlineView }.first)
    }

    private func coordinator(of outline: NSOutlineView) throws -> SessionSidebarCoordinator {
        try #require(outline.delegate as? SessionSidebarCoordinator)
    }

    private func settled(_ fixture: SessionDetailFixture) async -> SessionSidebarOutlineView? {
        _ = await fixture.probe.settle()
        _ = await fixture.probe.settle()
        return try? outline(in: fixture.probe)
    }

    private func key(_ characters: String, keyCode: UInt16, to outline: NSOutlineView, in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
        outline.keyDown(with: event)
    }

    private func selectedIndex(_ windowRuntime: WindowRuntime) -> Int? {
        windowRuntime.sessions.firstIndex { $0.id == windowRuntime.selectedSessionID }
    }

    @Test func arrowKeysMoveSelectionBetweenSessionsSkippingPaneRows() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let windowRuntime = fixture.windowRuntime
        for session in windowRuntime.sessions { session.isPaneListExpanded = true }
        let outline = try #require(await settled(fixture))
        #expect(outline.numberOfRows > windowRuntime.sessions.count, "Pane rows were not shown")
        _ = fixture.probe.window.makeFirstResponder(outline)

        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        for expected in 1...3 {
            try key(down, keyCode: 125, to: outline, in: fixture.probe.window)
            _ = await fixture.probe.settle()
            #expect(selectedIndex(windowRuntime) == expected)
            #expect(outline.item(atRow: outline.selectedRow) is SessionRuntime, "a Pane row was selected")
        }
        try key(up, keyCode: 126, to: outline, in: fixture.probe.window)
        _ = await fixture.probe.settle()
        #expect(selectedIndex(windowRuntime) == 2)
        #expect(outline.item(atRow: outline.selectedRow) is SessionRuntime)
    }

    @Test func typeSelectSelectsASessionByTitle() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let windowRuntime = fixture.windowRuntime
        windowRuntime.renameSession(id: windowRuntime.sessions[2].id, to: "Zeta")
        let outline = try #require(await settled(fixture))
        _ = fixture.probe.window.makeFirstResponder(outline)
        #expect(selectedIndex(windowRuntime) == 0)

        try key("z", keyCode: 6, to: outline, in: fixture.probe.window)
        try key("e", keyCode: 14, to: outline, in: fixture.probe.window)
        _ = await fixture.probe.settle()
        #expect(selectedIndex(windowRuntime) == 2)
    }

    @Test func paneRowsAreNotSelectable() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let outline = try #require(await settled(fixture))
        let coordinator = try coordinator(of: outline)
        let session = fixture.windowRuntime.sessions[1]
        let pane = try #require(session.tree.panesSortedByColumnThenRow.first)

        #expect(coordinator.outlineView(outline, shouldSelectItem: pane) == false)
        #expect(coordinator.outlineView(outline, shouldSelectItem: session) == true)
        #expect(coordinator.outlineView(outline, typeSelectStringFor: nil, item: pane) == nil)
        #expect(coordinator.outlineView(outline, typeSelectStringFor: nil, item: session) == session.title)
    }

    @Test func modelSelectionSelectsTheOutlineRow() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let windowRuntime = fixture.windowRuntime
        let outline = try #require(await settled(fixture))

        windowRuntime.selectSession(at: 3)
        _ = await fixture.probe.settle()
        #expect(outline.selectedRow == outline.row(forItem: windowRuntime.sessions[3]))
        #expect(outline.accessibilitySelectedRows()?.count == 1)
    }

    @Test func userSelectionGoesThroughTheSidebarSetter() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let windowRuntime = fixture.windowRuntime
        windowRuntime.sessions[1].isPaneListExpanded = true
        let outline = try #require(await settled(fixture))

        let target = windowRuntime.sessions[2]
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: target)), byExtendingSelection: false)
        #expect(windowRuntime.selectedSessionID == target.id)
        _ = await fixture.probe.settle()

        let pane = try #require(windowRuntime.sessions[1].tree.panesSortedByColumnThenRow.first)
        let paneRow = outline.row(forItem: pane)
        #expect(paneRow >= 0, "the Pane row is not shown")
        outline.selectRowIndexes(IndexSet(integer: paneRow), byExtendingSelection: false)
        #expect(windowRuntime.selectedSessionID == target.id, "a Pane row's selection reached the model")
        _ = await fixture.probe.settle()
        #expect(outline.selectedRow == outline.row(forItem: target), "the outline did not snap back")
    }

    @Test func expansionFollowsTheModelAndTheDisclosure() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let session = fixture.windowRuntime.sessions[2]
        let outline = try #require(await settled(fixture))
        #expect(!outline.isItemExpanded(session))

        session.isPaneListExpanded = true
        _ = await fixture.probe.settle()
        #expect(outline.isItemExpanded(session))
        for pane in session.tree.panesSortedByColumnThenRow {
            #expect(outline.row(forItem: pane) >= 0)
        }

        outline.collapseItem(session)
        #expect(session.isPaneListExpanded == false)
        outline.expandItem(session)
        #expect(session.isPaneListExpanded == true)
    }

    @Test func structureChangesReloadRows() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let windowRuntime = fixture.windowRuntime
        let store = fixture.store
        let outline = try #require(await settled(fixture))
        let rootCount = outline.numberOfChildren(ofItem: nil)

        let added = windowRuntime.addSession()
        _ = await fixture.probe.settle()
        #expect(outline.numberOfChildren(ofItem: nil) == rootCount + 1)
        #expect(outline.row(forItem: added) >= 0)

        let first = windowRuntime.sessions[0]
        first.isPaneListExpanded = true
        _ = await fixture.probe.settle()
        let paneCount = outline.numberOfChildren(ofItem: first)
        let paneID = try #require(first.tree.allPanes.first?.id)
        #expect(store.splitPane(id: paneID, direction: .horizontal) != nil)
        _ = await fixture.probe.settle()
        #expect(outline.numberOfChildren(ofItem: first) == paneCount + 1)

        windowRuntime.moveSessions(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        _ = await fixture.probe.settle()
        let shown = (0..<outline.numberOfChildren(ofItem: nil)).map { outline.child($0, ofItem: nil) as? SessionRuntime }
        #expect(shown.map { $0?.id } == windowRuntime.sessions.map(\.id))
    }

    @Test func dropMovesSessions() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let reference = SessionDetailFixture.standard()
        defer { reference.tearDown() }
        let outline = try #require(await settled(fixture))
        let coordinator = try coordinator(of: outline)
        let titles = fixture.windowRuntime.sessions.map(\.title)
        #expect(titles == reference.windowRuntime.sessions.map(\.title))

        coordinator.moveSession(from: 0, toRootIndex: 3)
        reference.windowRuntime.moveSessions(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(fixture.windowRuntime.sessions.map(\.title) == reference.windowRuntime.sessions.map(\.title))
        #expect(fixture.windowRuntime.sessions.map(\.title) != titles)
    }

    @Test func outlineCarriesTheSidebarIdentifier() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let outline = try #require(await settled(fixture))
        #expect(outline.accessibilityIdentifier() == "session-sidebar")
    }

    @Test func seeThroughRowViewsUseFillAndTint() async throws {
        let base = SessionDetailFixture.standard()
        base.probe.window.close()
        let store = base.store
        let windowRuntime = base.windowRuntime
        let probe = LayoutConvergenceProbe(
            SeeThroughTree(store: store, windowRuntime: windowRuntime),
            size: CGSize(width: 1100, height: 700),
            styleMask: SessionDetailFixture.titledStyle
        )
        defer {
            base.tearDown()
            probe.window.close()
        }
        windowRuntime.sessions[1].isPaneListExpanded = true
        _ = await probe.settle()
        _ = await probe.settle()
        let outline = try outline(in: probe)

        let selected = try #require(outline.rowView(atRow: outline.row(forItem: windowRuntime.sessions[0]), makeIfNecessary: false) as? SidebarOutlineRowView)
        #expect(selected.fill != nil)
        #expect(selected.tint != nil)
        #expect(selected.interiorBackgroundStyle == .normal)
        let pane = try #require(windowRuntime.sessions[1].tree.panesSortedByColumnThenRow.first)
        let paneRow = try #require(outline.rowView(atRow: outline.row(forItem: pane), makeIfNecessary: false) as? SidebarOutlineRowView)
        #expect(paneRow.fill != nil)
        #expect(paneRow.tint == nil)
    }
}
