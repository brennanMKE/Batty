// PaneTabStripWidthTests.swift

import CoreGraphics
import SwiftUI
import Testing
@testable import BattyKit

@MainActor
struct PaneTabStripWidthTests {
    private typealias Strip = PaneTabStrip<EmptyChip>

    @Test func chipWidthDividesStripAmongTabs() {
        #expect(Strip.chipWidth(stripWidth: 800, tabCount: 4) == (742.0 / 4) - 6)
    }

    @Test func chipWidthClampsToMinAndCap() {
        #expect(Strip.chipWidth(stripWidth: 100, tabCount: 3) == 60)
        #expect(Strip.chipWidth(stripWidth: 2000, tabCount: 1) == 220)
    }

    @Test func chipWidthToleratesZeroWidthAndZeroTabs() {
        #expect(Strip.chipWidth(stripWidth: 0, tabCount: 0) == 60)
        #expect(Strip.chipWidth(stripWidth: 400, tabCount: 0) == Strip.chipWidth(stripWidth: 400, tabCount: 1))
    }
}

private struct EmptyChip: View {
    var body: some View { EmptyView() }
}
