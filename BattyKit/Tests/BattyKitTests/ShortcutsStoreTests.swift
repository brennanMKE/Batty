// ShortcutsStoreTests.swift

import Foundation
import SwiftUI
import Testing
@testable import BattyKit

@MainActor
@Suite("ShortcutsStore")
struct ShortcutsStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsLoadWhenEmpty() {
        let defaults = makeDefaults()
        let store = ShortcutsStore(userDefaults: defaults)
        for action in ShortcutAction.allCases {
            #expect(store.binding(for: action) == action.defaultBinding)
        }
    }

    @Test func remindMeDefaultsToCommandShiftRAndCollidesWithNoOtherDefault() {
        let binding = ShortcutAction.remindMe.defaultBinding
        #expect(binding == ShortcutBinding(key: "r", modifiers: EventModifiers([.command, .shift]).rawValue))
        #expect(ShortcutAction.remindMe.displayName == "Remind Me…")
        for action in ShortcutAction.allCases where action != .remindMe {
            #expect(action.defaultBinding != binding, "\(action.rawValue)")
        }
        #expect(!ShortcutsStore.reservedShortcuts.contains(binding))
    }

    @Test func toggleRemindersDefaultsToOptionCommandR() {
        #expect(ShortcutAction.toggleReminders.defaultBinding
            == ShortcutBinding(key: "r", modifiers: EventModifiers([.command, .option]).rawValue))
        #expect(ShortcutAction.toggleReminders.displayName == "Show Reminders")
        #expect(ShortcutAction.allCases.last == .toggleSidebarStyle, "the catalog is append-only")
    }

    @Test func toggleRemindersDefaultCollidesWithNoOtherDefault() {
        let binding = ShortcutAction.toggleReminders.defaultBinding
        for action in ShortcutAction.allCases where action != .toggleReminders {
            #expect(action.defaultBinding != binding, "\(action.rawValue)")
        }
        #expect(!ShortcutsStore.reservedShortcuts.contains(binding))
    }

    @Test func toggleSidebarStyleDefaultsToOptionCommandB() {
        #expect(ShortcutAction.toggleSidebarStyle.defaultBinding
            == ShortcutBinding(key: "b", modifiers: EventModifiers([.command, .option]).rawValue))
        #expect(ShortcutAction.toggleSidebarStyle.displayName == "Toggle Symbols-Only Sidebar")
    }

    @Test func toggleSidebarStyleDefaultCollidesWithNoOtherDefault() {
        let binding = ShortcutAction.toggleSidebarStyle.defaultBinding
        for action in ShortcutAction.allCases where action != .toggleSidebarStyle {
            #expect(action.defaultBinding != binding, "\(action.rawValue)")
        }
        #expect(!ShortcutsStore.reservedShortcuts.contains(binding))
    }

    @Test func sidebarStyleActionIsUnavailableWithFlagOff() {
        let off = FeatureFlags(sharedProjectImages: false, compactSidebar: false)
        let on = FeatureFlags(sharedProjectImages: false, compactSidebar: true)
        #expect(!ShortcutAction.toggleSidebarStyle.isAvailable(off))
        #expect(ShortcutAction.toggleSidebarStyle.isAvailable(on))
        for action in ShortcutAction.allCases where action != .toggleSidebarStyle {
            #expect(action.isAvailable(off), "\(action.rawValue)")
        }
    }

    @Test func bindingRoundTripsThroughUserDefaults() {
        let defaults = makeDefaults()
        let store1 = ShortcutsStore(userDefaults: defaults)
        let custom = ShortcutBinding(key: "k", modifiers: EventModifiers([.command]).rawValue)
        store1.setBinding(custom, for: .closeTab)

        let store2 = ShortcutsStore(userDefaults: defaults)
        #expect(store2.binding(for: .closeTab) == custom)
    }

    @Test func collisionsReportOtherActions() {
        let defaults = makeDefaults()
        let store = ShortcutsStore(userDefaults: defaults)
        let combo = ShortcutBinding(key: "x", modifiers: EventModifiers([.command]).rawValue)
        store.setBinding(combo, for: .newTab)
        store.setBinding(combo, for: .closeTab)

        let hits = store.collisions(combo, excluding: .newTab, flags: FeatureFlags(sharedProjectImages: false, compactSidebar: true))
        #expect(hits.contains(.closeTab))
        #expect(!hits.contains(.newTab))
    }

    @Test func hiddenSidebarStyleActionReportsNoCollisionWithFlagOff() {
        let store = ShortcutsStore(userDefaults: makeDefaults())
        let optionCmdB = ShortcutAction.toggleSidebarStyle.defaultBinding
        store.setBinding(optionCmdB, for: .newTab)
        let off = FeatureFlags(sharedProjectImages: false, compactSidebar: false)
        let on = FeatureFlags(sharedProjectImages: false, compactSidebar: true)
        #expect(store.collisions(optionCmdB, excluding: .newTab, flags: off).isEmpty)
        #expect(store.collisions(optionCmdB, excluding: .newTab, flags: on) == [.toggleSidebarStyle])
    }

    @Test func isReservedFlagsCmdQ() {
        let cmdQ = ShortcutBinding(key: "q", modifiers: EventModifiers([.command]).rawValue)
        #expect(ShortcutsStore.isReserved(cmdQ))

        let cmdComma = ShortcutBinding(key: ",", modifiers: EventModifiers([.command]).rawValue)
        #expect(ShortcutsStore.isReserved(cmdComma))

        let cmdK = ShortcutBinding(key: "k", modifiers: EventModifiers([.command]).rawValue)
        #expect(!ShortcutsStore.isReserved(cmdK))
    }

    @Test func resetToDefaultFlipsCustomizedBinding() {
        let defaults = makeDefaults()
        let store = ShortcutsStore(userDefaults: defaults)
        let custom = ShortcutBinding(key: "z", modifiers: EventModifiers([.command]).rawValue)
        store.setBinding(custom, for: .newTab)
        #expect(store.binding(for: .newTab) == custom)

        store.resetToDefault(.newTab)
        #expect(store.binding(for: .newTab) == ShortcutAction.newTab.defaultBinding)
    }

    @Test func resetAllToDefaultsClearsAll() {
        let defaults = makeDefaults()
        let store = ShortcutsStore(userDefaults: defaults)
        let custom = ShortcutBinding(key: "z", modifiers: EventModifiers([.command]).rawValue)
        store.setBinding(custom, for: .newTab)
        store.setBinding(custom, for: .closeTab)

        store.resetAllToDefaults()
        for action in ShortcutAction.allCases {
            #expect(store.binding(for: action) == action.defaultBinding)
        }
    }

    @Test func partialPersistedBlobFallsBackToDefaultsForMissingActions() throws {
        let defaults = makeDefaults()
        let partial: [String: ShortcutBinding] = [
            ShortcutAction.newTab.rawValue: ShortcutBinding(
                key: "y", modifiers: EventModifiers([.command]).rawValue
            )
        ]
        let data = try JSONEncoder().encode(partial)
        defaults.set(data, forKey: "co.sstools.Batty.keyboardShortcuts")

        let store = ShortcutsStore(userDefaults: defaults)
        #expect(store.binding(for: .newTab).key == "y")
        #expect(store.binding(for: .closeTab) == ShortcutAction.closeTab.defaultBinding)
        #expect(store.binding(for: .newSession) == ShortcutAction.newSession.defaultBinding)
    }

    @Test func exitShellIsInCatalogWithADistinctDefaultBinding() {
        #expect(ShortcutAction.allCases.contains(.exitShell))
        #expect(!ShortcutAction.exitShell.displayName.isEmpty)

        let expected = ShortcutBinding(key: "x", modifiers: EventModifiers([.command, .shift]).rawValue)
        #expect(ShortcutAction.exitShell.defaultBinding == expected)
        #expect(!ShortcutsStore.isReserved(ShortcutAction.exitShell.defaultBinding))

        // Must not collide with the "Cut" chord (⌘X) the shortcut was
        // deliberately chosen to avoid (#0309).
        let cut = ShortcutBinding(key: "x", modifiers: EventModifiers([.command]).rawValue)
        #expect(ShortcutAction.exitShell.defaultBinding != cut)
    }

    @Test func resizeSplitActionsAreInCatalogWithDistinctCmdCtrlArrowBindings() {
        let actions: [(ShortcutAction, ShortcutBinding.SpecialKey)] = [
            (.resizeSplitLeft, .leftArrow),
            (.resizeSplitRight, .rightArrow),
            (.resizeSplitUp, .upArrow),
            (.resizeSplitDown, .downArrow),
        ]
        for (action, specialKey) in actions {
            #expect(ShortcutAction.allCases.contains(action))
            #expect(!action.displayName.isEmpty)

            let expected = ShortcutBinding(
                key: specialKey.rawValue,
                modifiers: EventModifiers([.command, .control]).rawValue
            )
            #expect(action.defaultBinding == expected)
            #expect(!ShortcutsStore.isReserved(action.defaultBinding))

            // Must not collide with the Cmd-Option-arrow focus-pane bindings
            // (#0325's chord-collision check): same key, different modifier.
            let focusPaneEquivalent = ShortcutBinding(
                key: specialKey.rawValue,
                modifiers: EventModifiers([.command, .option]).rawValue
            )
            #expect(action.defaultBinding != focusPaneEquivalent)
        }
    }

    @Test func everyActionHasAUniqueDefaultBinding() {
        var seen: [ShortcutBinding: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            let binding = action.defaultBinding
            if let existing = seen[binding] {
                Issue.record("\(action) and \(existing) share default binding \(binding)")
            }
            seen[binding] = action
        }
    }

    @Test func unknownActionIdsInPersistedBlobAreIgnored() throws {
        let defaults = makeDefaults()
        let blob: [String: ShortcutBinding] = [
            "someFutureAction": ShortcutBinding(
                key: "z", modifiers: EventModifiers([.command]).rawValue
            ),
            ShortcutAction.closeTab.rawValue: ShortcutBinding(
                key: "k", modifiers: EventModifiers([.command]).rawValue
            )
        ]
        let data = try JSONEncoder().encode(blob)
        defaults.set(data, forKey: "co.sstools.Batty.keyboardShortcuts")

        let store = ShortcutsStore(userDefaults: defaults)
        #expect(store.binding(for: .closeTab).key == "k")
    }
}
