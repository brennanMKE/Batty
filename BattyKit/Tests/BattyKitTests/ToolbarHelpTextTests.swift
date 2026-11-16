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

    private func remindersList(dueCount: Int, upcomingMinutes: [Double]) -> RemindersListModel {
        let anchor = ReminderFixture.anchor
        var sessions: [RemindersSessionInput] = []
        var fired: [FiredReminder] = []
        for index in 0..<dueCount {
            let id = UUID()
            sessions.append(RemindersSessionInput(id: id, title: "Due \(index)", reminder: nil))
            fired.append(FiredReminder(
                id: UUID(), sessionID: id, windowID: UUID(), note: nil,
                createdAt: anchor, dueAt: anchor, firedAt: anchor, seen: true))
        }
        for (index, minutes) in upcomingMinutes.enumerated() {
            sessions.append(RemindersSessionInput(
                id: UUID(), title: "Up \(index)",
                reminder: SessionReminder(createdAt: anchor, target: .instant(anchor.addingTimeInterval(minutes * 60)))))
        }
        return RemindersListModel(fired: fired, sessions: sessions, calendar: ReminderFixture.calendar())
    }

    private func remindersHelp(_ store: ShortcutsStore, _ list: RemindersListModel) -> String {
        ToolbarHelpText.reminders(
            store, list: list, now: ReminderFixture.anchor, calendar: ReminderFixture.calendar(),
            locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func remindersHelpShowsTheBoundShortcutAndState() {
        let store = makeStore()
        #expect(remindersHelp(store, remindersList(dueCount: 0, upcomingMinutes: []))
            == "Reminders (\u{2325}\u{2318}R)")
        #expect(remindersHelp(store, remindersList(dueCount: 0, upcomingMinutes: [45, 90]))
            == "Reminders (\u{2325}\u{2318}R) \u{00B7} 2 upcoming, next at 3:45 PM")
        #expect(remindersHelp(store, remindersList(dueCount: 1, upcomingMinutes: [45, 90]))
            == "Reminders (\u{2325}\u{2318}R) \u{00B7} 1 due, 2 upcoming")
        #expect(remindersHelp(store, remindersList(dueCount: 1, upcomingMinutes: []))
            == "Reminders (\u{2325}\u{2318}R) \u{00B7} 1 due")
    }

    @Test func remindersHelpFollowsARebinding() {
        let store = makeStore()
        store.setBinding(chord("x", [.control, .option]), for: .toggleReminders)
        #expect(remindersHelp(store, remindersList(dueCount: 0, upcomingMinutes: []))
            == "Reminders (\u{2303}\u{2325}X)")
    }
}
