// ToolbarHelpTextTests.swift

import Foundation
import SwiftUI
import Testing
@testable import BattyKit

@MainActor
@Suite("ToolbarHelpText")
struct ToolbarHelpTextTests {
    private func makeStore() -> ShortcutsStore {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ShortcutsStore(userDefaults: defaults)
    }

    private func chord(_ key: String, _ modifiers: EventModifiers) -> ShortcutBinding {
        ShortcutBinding(key: key, modifiers: modifiers.rawValue)
    }

    @Test func bellFeedHelpShowsTheDefaultShortcut() {
        #expect(ToolbarHelpText.bellFeed(makeStore()) == "Bell Feed (\u{21E7}\u{2318}B)")
    }

    @Test func bellFeedHelpFollowsARebinding() {
        let store = makeStore()
        store.setBinding(chord("f", [.control, .option]), for: .toggleBellFeed)
        #expect(ToolbarHelpText.bellFeed(store) == "Bell Feed (\u{2303}\u{2325}F)")
    }

    @Test func splitHelpShowsTheBoundShortcuts() {
        let store = makeStore()
        #expect(ToolbarHelpText.splitHorizontal(store)
            == "Split Horizontally (\u{2318}D) \u{2014} Option for a full-height column (\u{2325}\u{2318}D)")
        #expect(ToolbarHelpText.splitVertical(store)
            == "Split Vertically (\u{21E7}\u{2318}D) \u{2014} Option for a full-width row (\u{2325}\u{21E7}\u{2318}D)")
    }

    @Test func splitHelpFollowsRebindings() {
        let store = makeStore()
        store.setBinding(chord("1", [.control, .command]), for: .splitHorizontal)
        store.setBinding(chord("2", [.control, .command]), for: .splitVertical)
        store.setBinding(chord("3", [.control, .command]), for: .splitFullHeightColumn)
        store.setBinding(chord("4", [.control, .command]), for: .splitFullWidthRow)
        let horizontal = ToolbarHelpText.splitHorizontal(store)
        let vertical = ToolbarHelpText.splitVertical(store)
        #expect(horizontal
            == "Split Horizontally (\u{2303}\u{2318}1) \u{2014} Option for a full-height column (\u{2303}\u{2318}3)")
        #expect(vertical
            == "Split Vertically (\u{2303}\u{2318}2) \u{2014} Option for a full-width row (\u{2303}\u{2318}4)")
        #expect(!horizontal.contains("\u{2318}D"))
        #expect(!vertical.contains("\u{2318}D"))
    }

    @Test func labelledFormatsTitleAndBinding() {
        #expect(ToolbarHelpText.labelled("Reminders", chord("r", [.command, .option]))
            == "Reminders (\u{2325}\u{2318}R)")
    }
}
