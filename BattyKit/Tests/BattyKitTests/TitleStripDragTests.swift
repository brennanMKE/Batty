// TitleStripDragTests.swift

import Testing
@testable import BattyKit

@MainActor
struct TitleStripDragTests {
    private func decide(
        className: String = "NSToolbarTitleView",
        isOpaque: Bool = false,
        clickCount: Int = 1,
        inStrip: Bool = true,
        controlOrCommandHeld: Bool = false
    ) -> Bool {
        TitleStripDrag.shouldStartDrag(
            hitViewClassName: className,
            isWindowOpaque: isOpaque,
            clickCount: clickCount,
            isInTitleStrip: inStrip,
            controlOrCommandHeld: controlOrCommandHeld
        )
    }

    nonisolated private static let allowlist = [
        "NSToolbarPrimaryTitleContainerView",
        "NSToolbarTitleView",
        "_NSToolbarTitleField",
        "NSTitlebarView"
    ]

    @Test(arguments: allowlist)
    func allowlistedViewDragsInANonOpaqueWindowsStrip(className: String) {
        #expect(decide(className: className))
    }

    @Test func allowlistIsExactlyTheNamedClasses() {
        #expect(TitleStripDrag.draggableHitViews == Set(Self.allowlist))
    }

    @Test(arguments: allowlist)
    func opaqueWindowNeverDrags(className: String) {
        #expect(!decide(className: className, isOpaque: true))
    }

    @Test(arguments: [0, 2, 3])
    func onlyASingleClickDrags(clickCount: Int) {
        #expect(!decide(clickCount: clickCount))
    }

    @Test func pressOutsideTheStripNeverDrags() {
        #expect(!decide(inStrip: false))
    }

    @Test func controlOrCommandPressNeverDrags() {
        #expect(!decide(controlOrCommandHeld: true))
    }

    @Test(arguments: [
        "NSButton",
        "NSToolbarButton",
        "_NSThemeCloseWidget",
        "AppTerminalView",
        "NSToolbarView",
        "SomeRenamedTitleView",
        "nstoolbartitleview",
        ""
    ])
    func otherViewsNeverDrag(className: String) {
        #expect(!decide(className: className))
    }

    @Test func sidebarHostingViewNeverDrags() {
        #expect(!decide(className: "NSHostingView<ModifiedContent<ColumnView, NavigationPaneModifier<SidebarStyleContext>>>"))
    }
}
