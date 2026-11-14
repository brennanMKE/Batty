// SessionSidebarOutlineLayoutTests.swift

import AppKit
import SwiftUI
import Testing
@testable import BattyKit

/// #0627: the `NSOutlineView` Sidebar draws its chevron, indentation, insets
/// and selected title as the pre-#0619 `List(.sidebar)` did, measured there.
@MainActor
struct SessionSidebarOutlineLayoutTests {

    private struct Extent {
        let minX: CGFloat
        let maxX: CGFloat
        let minY: CGFloat
        let maxY: CGFloat
    }

    /// Drawn extent in points (top-down y), from pixels with alpha > 0.3.
    private func inkExtent(of view: NSView) -> Extent? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.3 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return Extent(
            minX: CGFloat(minX) / scale,
            maxX: CGFloat(maxX + 1) / scale,
            minY: CGFloat(minY) / scale,
            maxY: CGFloat(maxY + 1) / scale
        )
    }

    private func settledOutline(_ fixture: SessionDetailFixture) async throws -> SessionSidebarOutlineView {
        for session in fixture.windowRuntime.sessions {
            session.title = "Session 1"
            session.isPaneListExpanded = true
        }
        _ = await fixture.probe.settle()
        _ = await fixture.probe.settle()
        return try #require(fixture.probe.allViews().compactMap { $0 as? SessionSidebarOutlineView }.first)
    }

    private func sessionRows(_ outline: NSOutlineView) -> [Int] {
        (0..<outline.numberOfRows).filter { outline.item(atRow: $0) is SessionRuntime }
    }

    private func paneRows(_ outline: NSOutlineView) -> [Int] {
        (0..<outline.numberOfRows).filter { outline.item(atRow: $0) is PaneRuntime }
    }

    private func cell(_ outline: NSOutlineView, row: Int) throws -> NSView {
        try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: false))
    }

    private func referenceWidth(_ view: some View) -> CGFloat {
        let host = NSHostingView(rootView: view.fixedSize().padding(4))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let extent = inkExtent(of: host) else { return 0 }
        return extent.maxX - extent.minX
    }

    @Test func outlineMetricsMatchPre0619List() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let outline = try await settledOutline(fixture)
        #expect(outline.indentationPerLevel == 12)
        #expect(outline.rowHeight == 32)
        #expect(outline.rowSizeStyle == .medium)
        #expect(outline.intercellSpacing == NSSize(width: 3, height: 0))
        for row in 0..<outline.numberOfRows {
            #expect(outline.rect(ofRow: row).height == 32)
        }
    }

    @Test func disclosureChevronIsVerticallyCentredOnSessionRows() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let outline = try await settledOutline(fixture)
        let rows = sessionRows(outline)
        #expect(!rows.isEmpty)
        for row in rows {
            let outlineCell = outline.frameOfOutlineCell(atRow: row)
            #expect(outlineCell.minX == 12)
            #expect(outlineCell.width == 13)
            #expect(outlineCell.midY == outline.rect(ofRow: row).midY)

            let rowView = try #require(outline.rowView(atRow: row, makeIfNecessary: false))
            let button = try #require(rowView.subviews.first {
                $0.identifier == NSOutlineView.disclosureButtonIdentifier
            })
            #expect(button.frame == NSRect(x: 12, y: 0, width: 13, height: 32))
            let image = try #require(button.subviews.first)
            #expect(abs(image.frame.midY - button.bounds.midY) <= 0.5,
                    "chevron image at \(image.frame) in \(button.bounds)")
            #expect(abs(try cell(outline, row: row).firstBaselineOffsetFromTop - 20.92) <= 0.5)
        }
    }

    @Test func paneCellsIndentAndInsetLikePre0619List() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let outline = try await settledOutline(fixture)
        let sessionMinX = outline.frameOfCell(atColumn: 0, row: try #require(sessionRows(outline).first)).minX
        let panes = paneRows(outline)
        #expect(!panes.isEmpty)
        for row in panes {
            let frame = outline.frameOfCell(atColumn: 0, row: row)
            #expect(frame.minX == sessionMinX + 12)
            let extent = try #require(inkExtent(of: try cell(outline, row: row)))
            #expect(abs(extent.minX - 12) <= 1, "pane content starts at \(extent.minX)")
            #expect(extent.maxX <= frame.width - 8 + 0.5, "pane content ends at \(extent.maxX) of \(frame.width)")
        }
    }

    @Test func sessionCellContentStartsAtPre0619Inset() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let outline = try await settledOutline(fixture)
        let row = try #require(sessionRows(outline).first { outline.selectedRow != $0 })
        let extent = try #require(inkExtent(of: try cell(outline, row: row)))
        #expect(abs(extent.minX - 8) <= 0.5, "session content starts at \(extent.minX)")
    }

    @Test func selectedSessionTitleIsBold() async throws {
        let fixture = SessionDetailFixture.standard()
        defer { fixture.tearDown() }
        let outline = try await settledOutline(fixture)
        let boldGain = referenceWidth(Text(verbatim: "Session 1").bold())
            - referenceWidth(Text(verbatim: "Session 1"))
        #expect(boldGain >= 1)

        func widths() throws -> (selected: CGFloat, unselected: CGFloat) {
            let rows = sessionRows(outline)
            let selected = try #require(rows.first { $0 == outline.selectedRow })
            let unselected = try #require(rows.first { $0 != outline.selectedRow })
            let a = try #require(inkExtent(of: try cell(outline, row: selected)))
            let b = try #require(inkExtent(of: try cell(outline, row: unselected)))
            return (a.maxX - a.minX, b.maxX - b.minX)
        }

        let before = try widths()
        #expect(abs((before.selected - before.unselected) - boldGain) <= 1,
                "selected \(before.selected), unselected \(before.unselected), bold gain \(boldGain)")

        let firstSelected = outline.selectedRow
        fixture.windowRuntime.selectSession(at: 1)
        _ = await fixture.probe.settle()
        _ = await fixture.probe.settle()
        #expect(outline.selectedRow != firstSelected)
        let selectedCell = try #require(inkExtent(of: try cell(outline, row: outline.selectedRow)))
        let oldCell = try #require(inkExtent(of: try cell(outline, row: firstSelected)))
        #expect(abs(((selectedCell.maxX - selectedCell.minX) - (oldCell.maxX - oldCell.minX)) - boldGain) <= 1)
    }
}
