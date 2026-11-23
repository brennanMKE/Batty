// SidebarStyleTests.swift

import Foundation
import Testing
@testable import BattyKit

struct SidebarStyleTests {
    private let rail = SidebarRailMetrics.defaultRail

    @Test func toggledFlipsBetweenNamesAndSymbols() {
        #expect(SidebarStyle.names.toggled == .symbols)
        #expect(SidebarStyle.symbols.toggled == .names)
    }

    @Test func commandTitleSaysWhatWillHappen() {
        #expect(SidebarStyle.toggleCommandTitle(current: .names) == "Show Symbols Only")
        #expect(SidebarStyle.toggleCommandTitle(current: .symbols) == "Show Session Names")
    }

    @Test func columnRangeIsUnchangedWithFlagOff() {
        for style in [SidebarStyle.names, .symbols] {
            let range = SidebarRailMetrics.columnRange(compactSidebar: false, style: style, railWidth: rail)
            #expect(range.min == 180)
            #expect(range.ideal == 220)
            #expect(range.max == 320)
        }
    }

    @Test func columnRangeAllowsTheRailOnlyInSymbolsWithFlagOn() {
        let rail = SidebarRailMetrics.columnRange(compactSidebar: true, style: .symbols, railWidth: 84)
        #expect(rail.min == 84)
        #expect(rail.ideal == 220)
        #expect(rail.max == 320)
        let names = SidebarRailMetrics.columnRange(compactSidebar: true, style: .names, railWidth: 84)
        #expect(names.min == 180)
        #expect(names.ideal == 220)
        #expect(names.max == 320)
    }

    @Test func railWidthDefaultsTo56AndAcceptsOnly84() throws {
        let defaults = try #require(UserDefaults(suiteName: "SidebarStyleTests-\(UUID().uuidString)"))
        let key = SidebarRailMetrics.railWidthDefaultsKey
        #expect(SidebarRailMetrics.railWidth(defaults: defaults) == 56)
        defaults.set(84, forKey: key)
        #expect(SidebarRailMetrics.railWidth(defaults: defaults) == 84)
        defaults.set(70, forKey: key)
        #expect(SidebarRailMetrics.railWidth(defaults: defaults) == 56)
        defaults.set("wide", forKey: key)
        #expect(SidebarRailMetrics.railWidth(defaults: defaults) == 56)
    }

    @Test func dragEndBelowThresholdSnapsToRail() {
        let resolved = SidebarRailMetrics.resolveDragEnd(width: 100, railWidth: rail)
        #expect(resolved.style == .symbols)
        #expect(resolved.width == rail)
        #expect(SidebarRailMetrics.resolveDragEnd(width: 119, railWidth: 84).width == 84)
    }

    @Test func dragEndBetweenThresholdAndNamesMinimumSnapsToNamesMinimum() {
        for width: CGFloat in [120, 150, 179] {
            let resolved = SidebarRailMetrics.resolveDragEnd(width: width, railWidth: rail)
            #expect(resolved.style == .names)
            #expect(resolved.width == 180)
        }
    }

    @Test func dragEndAboveNamesMinimumKeepsWidth() {
        let resolved = SidebarRailMetrics.resolveDragEnd(width: 250, railWidth: rail)
        #expect(resolved.style == .names)
        #expect(resolved.width == 250)
    }

    @Test func dragEndPastMaximumClamps() {
        #expect(SidebarRailMetrics.resolveDragEnd(width: 400, railWidth: rail).width == 320)
    }

    @Test func namesTargetRestoresLastNamesWidth() {
        #expect(SidebarRailMetrics.targetWidth(for: .names, railWidth: rail, lastNamesWidth: 260) == 260)
        #expect(SidebarRailMetrics.targetWidth(for: .names, railWidth: rail, lastNamesWidth: 400) == 320)
        #expect(SidebarRailMetrics.targetWidth(for: .names, railWidth: rail, lastNamesWidth: 100) == 180)
        #expect(SidebarRailMetrics.targetWidth(for: .symbols, railWidth: rail, lastNamesWidth: 260) == rail)
    }

    @Test func namesTargetWithoutHistoryIsIdeal() {
        #expect(SidebarRailMetrics.targetWidth(for: .names, railWidth: rail, lastNamesWidth: nil) == 220)
    }

    @Test func railCountBadgeCapsAtNinePlus() {
        #expect(SessionRailBadge.countText(0) == nil)
        #expect(SessionRailBadge.countText(1) == "1")
        #expect(SessionRailBadge.countText(9) == "9")
        #expect(SessionRailBadge.countText(10) == "9+")
        #expect(SessionRailBadge.countText(250) == "9+")
    }

    @Test func railCornerGlyphPriorityIsDueThenImageThenPending() {
        #expect(SessionRailBadge.cornerGlyph(reminderDue: true, imageProblem: true, reminderPending: true) == .reminderDue)
        #expect(SessionRailBadge.cornerGlyph(reminderDue: false, imageProblem: true, reminderPending: true) == .imageProblem)
        #expect(SessionRailBadge.cornerGlyph(reminderDue: false, imageProblem: false, reminderPending: true) == .reminderPending)
        #expect(SessionRailBadge.cornerGlyph(reminderDue: false, imageProblem: false, reminderPending: false) == nil)
        #expect(SessionRailBadge.Glyph.reminderDue.systemName == "alarm.fill")
        #expect(SessionRailBadge.Glyph.imageProblem.systemName == "exclamationmark.triangle.fill")
        #expect(SessionRailBadge.Glyph.reminderPending.systemName == "clock")
    }
}
