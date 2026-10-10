// WindowCornersTests.swift

import SwiftUI
import Testing
@testable import BattyKit

@Suite struct WindowCornersTests {
    @Test func detailAreaOwnsOnlyBottomTrailingWhileSidebarShown() {
        #expect(WindowCorners.detailArea(sidebarHidden: false) == [.bottomTrailing])
    }

    @Test func detailAreaOwnsBothBottomCornersWhenSidebarHidden() {
        #expect(WindowCorners.detailArea(sidebarHidden: true) == [.bottomLeading, .bottomTrailing])
    }

    @Test func horizontalSplitHandsLeadingCornersToFirstChildOnly() {
        let root = WindowCorners.all
        #expect(root.firstChild(of: .horizontal) == [.topLeading, .bottomLeading])
        #expect(root.secondChild(of: .horizontal) == [.topTrailing, .bottomTrailing])
    }

    @Test func verticalSplitHandsTopCornersToFirstChildOnly() {
        let root = WindowCorners.all
        #expect(root.firstChild(of: .vertical) == [.topLeading, .topTrailing])
        #expect(root.secondChild(of: .vertical) == [.bottomLeading, .bottomTrailing])
    }

    @Test func childNeverGainsCornersTheParentLacks() {
        let parent: WindowCorners = [.bottomTrailing]
        #expect(parent.firstChild(of: .horizontal).isEmpty)
        #expect(parent.secondChild(of: .horizontal) == [.bottomTrailing])
        #expect(parent.firstChild(of: .vertical).isEmpty)
        #expect(parent.secondChild(of: .vertical) == [.bottomTrailing])
    }

    @Test func bottomRightPaneOfThreePaneLayoutGetsOnlyItsWindowCorner() {
        // detail area, sidebar shown: left | (top / bottom)
        let detail = WindowCorners.detailArea(sidebarHidden: false)
        let right = detail.secondChild(of: .horizontal)
        let rightBottom = right.secondChild(of: .vertical)
        let rightTop = right.firstChild(of: .vertical)
        #expect(rightBottom == [.bottomTrailing])
        #expect(rightTop.isEmpty)
        #expect(detail.firstChild(of: .horizontal).isEmpty)
    }

    @Test func radiiUseWindowRadiusOnlyAtWindowCorners() {
        let r = WindowCorners([.bottomTrailing]).radii(windowRadius: 26, interiorRadius: 4)
        #expect(r.bottomTrailing == 26)
        #expect(r.topLeading == 4)
        #expect(r.topTrailing == 4)
        #expect(r.bottomLeading == 4)
    }
}
