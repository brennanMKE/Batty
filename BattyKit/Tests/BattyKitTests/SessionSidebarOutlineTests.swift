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

    /// #0637: a Reminder adds only a fixed-size glyph to its row, so every
    /// Session row keeps one height through pending, fired and acknowledged.
    @Test func sessionRowHeightIsTheSameWithAndWithoutAReminder() async throws {
        let testDefaults = TestDefaults()
        defer { testDefaults.tearDown() }
        let store = AppStateStore(
            preferences: testDefaults.defaults,
            reminderClock: TestClock(now: ReminderFixture.anchor),
            reminderCalendar: { ReminderFixture.calendar() })
        let fixture = SessionDetailFixture.standard(store: store)
        defer { fixture.tearDown() }
        let windowRuntime = fixture.windowRuntime
        let outline = try #require(await settled(fixture))
        let target = windowRuntime.sessions[1]
        let baseline = outline.rect(ofRow: outline.row(forItem: target)).height
        #expect(baseline > 0)

        func expectUniformHeights(_ label: String) {
            for session in windowRuntime.sessions {
                let height = outline.rect(ofRow: outline.row(forItem: session)).height
                #expect(height == baseline, "\(label): \(session.title) is \(height), expected \(baseline)")
            }
        }
        func step(_ label: String, _ change: () -> Void) async {
            change()
            _ = await fixture.probe.settle()
            _ = await fixture.probe.settle()
            expectUniformHeights(label)
        }

        expectUniformHeights("baseline")
        await step("pending") {
            store.setReminder(.after(minutes: 15), note: "check the deploy", forSessionID: target.id)
        }
        await step("fired") {
            guard let reminder = target.reminder else { return }
            store.fireReminder(ReminderFiring(
                sessionID: target.id, reminder: reminder, dueDate: reminder.fireDate(calendar: ReminderFixture.calendar())!))
        }
        #expect(store.firedReminders.unseenSessionIDs == [target.id])
        await step("acknowledged") { store.markAllRemindersRead() }
        #expect(store.firedReminders.unseenSessionIDs.isEmpty)
    }

    /// Any `heightOfRowByItem`, even one returning a constant, switches the
    /// outline to per-row height queries.
    @Test func outlineDelegateHasNoPerRowHeight() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let outline = try #require(await settled(fixture))
        let coordinator = try coordinator(of: outline)
        #expect(!coordinator.responds(to: #selector(NSOutlineViewDelegate.outlineView(_:heightOfRowByItem:))))
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

    // MARK: - Symbols-only rail (#0679)

    private func cellIdentifiers(_ outline: NSOutlineView) -> [String] {
        (0..<outline.numberOfRows).compactMap {
            outline.view(atColumn: 0, row: $0, makeIfNecessary: false)?.identifier?.rawValue
        }
    }

    @Test func railStyleReportsNoChildrenAndKeepsExpandedState() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let windowRuntime = fixture.windowRuntime
        let expanded = windowRuntime.sessions[2]
        expanded.isPaneListExpanded = true
        let outline = try #require(await settled(fixture))
        let paneRow = try #require(expanded.tree.panesSortedByColumnThenRow.first)
        #expect(outline.row(forItem: paneRow) >= 0)

        windowRuntime.sidebarStyle = .symbols
        _ = await fixture.probe.settle()
        #expect(outline.numberOfRows == windowRuntime.sessions.count, "Pane rows are hidden in the rail")
        #expect(outline.numberOfChildren(ofItem: expanded) == 0)
        #expect(!outline.isExpandable(expanded))
        #expect(expanded.isPaneListExpanded, "the rail must not write the expanded state")

        windowRuntime.sidebarStyle = .names
        _ = await fixture.probe.settle()
        #expect(expanded.isPaneListExpanded)
        #expect(outline.isItemExpanded(expanded))
        #expect(outline.row(forItem: paneRow) >= 0, "Pane rows return with names")
    }

    @Test func railStyleUsesRailCellsAndFlushOutline() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let outline = try #require(await settled(fixture))
        #expect(outline.style == .sourceList)

        fixture.windowRuntime.sidebarStyle = .symbols
        _ = await fixture.probe.settle()
        #expect(outline.style == .plain)
        #expect(outline.indentationPerLevel == 0)
        #expect(outline.rowHeight == SessionSidebarCoordinator.railRowHeight)
        let identifiers = cellIdentifiers(outline)
        #expect(!identifiers.isEmpty)
        #expect(identifiers.allSatisfy { $0 == SessionSidebarCoordinator.railCellID.rawValue }, "\(identifiers)")
        let rowView = try #require(outline.rowView(atRow: 0, makeIfNecessary: false) as? SidebarOutlineRowView)
        #expect(rowView.isRail)
        let railCell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: false))
        #expect(railCell.frame.minX < 4, "the rail cell reserves disclosure space: \(railCell.frame)")
        #expect(abs(railCell.frame.midX - rowView.bounds.midX) < 4, "the rail cell is not centred: \(railCell.frame) in \(rowView.bounds)")
        #expect(rowView.interiorBackgroundStyle == .normal)

        fixture.windowRuntime.sidebarStyle = .names
        _ = await fixture.probe.settle()
        #expect(outline.style == .sourceList)
        #expect(outline.indentationPerLevel == 12)
        #expect(outline.rowSizeStyle == .medium)
        #expect(outline.rowHeight == 32)
        #expect(cellIdentifiers(outline).allSatisfy { $0 != SessionSidebarCoordinator.railCellID.rawValue })
    }

    @Test func railStyleArrowKeysStillSelectSessions() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let windowRuntime = fixture.windowRuntime
        windowRuntime.sidebarStyle = .symbols
        let outline = try #require(await settled(fixture))
        _ = fixture.probe.window.makeFirstResponder(outline)

        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        for expected in 1...3 {
            try key(down, keyCode: 125, to: outline, in: fixture.probe.window)
            _ = await fixture.probe.settle()
            #expect(selectedIndex(windowRuntime) == expected)
        }
    }

    @Test func railStyleDropStillMovesSessions() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        fixture.windowRuntime.sidebarStyle = .symbols
        let outline = try #require(await settled(fixture))
        let coordinator = try coordinator(of: outline)
        let titles = fixture.windowRuntime.sessions.map(\.title)
        coordinator.moveSession(from: 0, toRootIndex: 3)
        _ = await fixture.probe.settle()
        #expect(fixture.windowRuntime.sessions.map(\.title) == [titles[1], titles[2], titles[0], titles[3]])
        let shown = (0..<outline.numberOfChildren(ofItem: nil)).map { (outline.child($0, ofItem: nil) as? SessionRuntime)?.title }
        #expect(shown == fixture.windowRuntime.sessions.map(\.title))
    }

    @Test(.disabled("A headless NSHostingView cell exposes no SwiftUI accessibility children; BattyUITests/SidebarRailTests reads session-row.<title> in the rail"))
    func railRowsKeepTheirAccessibilityIdentifierAndValue() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        fixture.windowRuntime.sidebarStyle = .symbols
        let outline = try #require(await settled(fixture))
        let session = fixture.windowRuntime.sessions[0]
        let cell = try #require(outline.view(atColumn: 0, row: outline.row(forItem: session), makeIfNecessary: false))

        func ax(_ object: NSObject, _ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        func find(_ element: Any, depth: Int = 0) -> NSObject? {
            guard depth < 12, let object = element as? NSObject else { return nil }
            if ax(object, "accessibilityIdentifier") as? String == "session-row.\(session.title)" { return object }
            for child in ax(object, "accessibilityChildren") as? [Any] ?? [] {
                if let hit = find(child, depth: depth + 1) { return hit }
            }
            return nil
        }
        let element = try #require(find(cell))
        let value = ax(element, "accessibilityValue") as? String
        #expect(value?.hasPrefix("selected") == true, "\(value ?? "nil")")
    }
}
