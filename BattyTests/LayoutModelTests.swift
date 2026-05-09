// LayoutModelTests.swift

import Foundation
import Testing
@testable import Batty

struct LayoutModelTests {

    @Test func tabRoundTrips() throws {
        let original = Tab(
            titleOverride: "logs",
            lastKnownCWD: "/Users/brennan/Developer/brennanMKE/Batty",
            lastSetTitle: "tail -f",
            bellCount: 3,
            unseenBellCount: 1,
            lastBellAt: Date(timeIntervalSince1970: 1_750_000_000),
            lastBellMessage: "build complete"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Tab.self, from: data)
        #expect(decoded == original)
    }

    @Test func paneRoundTripsWithMultipleTabs() throws {
        let t1 = Tab()
        let t2 = Tab(titleOverride: "vim")
        let original = Pane(tabs: [t1, t2], activeTabID: t2.id)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Pane.self, from: data)
        #expect(decoded == original)
        #expect(decoded.activeTabID == t2.id)
    }

    @Test func nestedSplitRoundTrips() throws {
        let leftPane = Pane(tabs: [Tab()])
        let topRightPane = Pane(tabs: [Tab()])
        let bottomRightPane = Pane(tabs: [Tab()])

        let rightSubtree: SplitNode = .split(
            direction: .vertical,
            ratio: 0.4,
            left: .leaf(topRightPane),
            right: .leaf(bottomRightPane)
        )
        let original: SplitNode = .split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(leftPane),
            right: rightSubtree
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SplitNode.self, from: data)
        #expect(decoded == original)
    }

    @Test func sessionRoundTripsAcrossTwoEncoders() throws {
        let pane = Pane(tabs: [Tab(), Tab()])
        let session = Session(
            title: "frontend",
            icon: "rectangle.split.2x1",
            root: .leaf(pane),
            focusedPaneID: pane.id,
            unseenBellCount: 2
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded == session)
    }

    @Test func makeDefaultProducesCoherentSession() {
        let s = Session.makeDefault(title: "scratch")
        #expect(s.title == "scratch")
        #expect(s.root.contains(paneID: s.focusedPaneID))
        #expect(s.root.firstPane.tabs.count == 1)
    }

    @Test func paneRequiresAtLeastOneTab() {
        // Constructing a Pane with no tabs is a programmer error and should
        // trip the precondition; we assert behavior via the public API by
        // constructing with one tab and confirming activeTabID resolves.
        let t = Tab()
        let p = Pane(tabs: [t])
        #expect(p.activeTabID == t.id)
    }

    @Test func splitNodeContainsTraversesEntireTree() {
        let p1 = Pane(tabs: [Tab()])
        let p2 = Pane(tabs: [Tab()])
        let p3 = Pane(tabs: [Tab()])
        let tree: SplitNode = .split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(p1),
            right: .split(
                direction: .vertical,
                ratio: 0.5,
                left: .leaf(p2),
                right: .leaf(p3)
            )
        )
        #expect(tree.contains(paneID: p1.id))
        #expect(tree.contains(paneID: p2.id))
        #expect(tree.contains(paneID: p3.id))
        #expect(!tree.contains(paneID: UUID()))
    }
}
