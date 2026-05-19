// BattyShortcuts.swift

import AppKit
import Foundation
import OSLog
import SwiftUI

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "BattyShortcuts")

/// App-level keyboard shortcut router. Installed as an NSEvent local monitor
/// from `BattyAppDelegate` so Cmd-key shortcuts fire regardless of which view
/// holds first responder. Bypasses SwiftUI Commands + NSWindow's default
/// `performClose:` etc., which compete unpredictably with the terminal NSView.
///
/// Customizable bindings come from `ShortcutsStore.shared`. Fixed combos
/// (`Cmd-1..9`, `Cmd-Option-1..9`) are handled separately at the bottom.
@MainActor
public enum BattyShortcuts {
    /// Returns true when the event was consumed.
    public static func handle(_ event: NSEvent) -> Bool {
        // If the user is recording a new shortcut in Settings, the keystroke
        // belongs to the recorder, not to our action dispatch. Let it fall
        // through to RecorderView.performKeyEquivalent / keyDown.
        if NSApp.keyWindow?.firstResponder is RecorderView {
            return false
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        let store = WorkspaceManager.shared.store

        if let candidate = makeCandidate(from: event, mods: mods) {
            let shortcuts = ShortcutsStore.shared
            for action in ShortcutAction.allCases where shortcuts.binding(for: action) == candidate {
                run(action, store: store)
                return true
            }
        }

        // Positional bindings — intentionally NOT customizable in v1.
        // The preference is read at dispatch time (rather than baked into
        // bindings registered once at launch) so the swap takes effect live.
        let cmdSwitchesSessions = currentCmdNumberTarget() == .sessions

        switch (mods, chars) {
        case ([.command], let digit) where digit.count == 1 && digit.first?.isWholeNumber == true:
            if let index = Int(digit), (1...9).contains(index) {
                if cmdSwitchesSessions {
                    store.selectSession(at: index - 1)
                } else {
                    store.selectedSession?.focusedPane.selectTab(at: index - 1)
                }
                return true
            }
            return false

        case ([.command, .option], let digit) where digit.count == 1 && digit.first?.isWholeNumber == true:
            if let index = Int(digit), (1...9).contains(index) {
                if cmdSwitchesSessions {
                    store.selectedSession?.focusedPane.selectTab(at: index - 1)
                } else {
                    store.selectSession(at: index - 1)
                }
                return true
            }
            return false

        default:
            return false
        }
    }

    private static func currentCmdNumberTarget() -> CmdNumberTarget {
        let raw = UserDefaults.standard.string(forKey: SettingsPreference.cmdNumberTargetKey)
            ?? SettingsPreference.defaultCmdNumberTarget
        return CmdNumberTarget(rawValue: raw) ?? .sessions
    }

    private static func makeCandidate(from event: NSEvent, mods: NSEvent.ModifierFlags) -> ShortcutBinding? {
        var swiftUIMods: SwiftUI.EventModifiers = []
        if mods.contains(.command)  { swiftUIMods.insert(.command) }
        if mods.contains(.option)   { swiftUIMods.insert(.option) }
        if mods.contains(.shift)    { swiftUIMods.insert(.shift) }
        if mods.contains(.control)  { swiftUIMods.insert(.control) }

        if let special = RecorderView.specialKey(forKeyCode: Int(event.keyCode)) {
            return ShortcutBinding(key: special.rawValue, modifiers: swiftUIMods.rawValue)
        }
        guard let first = event.charactersIgnoringModifiers?.first else {
            return nil
        }
        let key = String(first).lowercased()
        return ShortcutBinding(key: key, modifiers: swiftUIMods.rawValue)
    }

    private static func run(_ action: ShortcutAction, store: AppStateStore) {
        logger.info("dispatching action \(action.rawValue, privacy: .public)")
        switch action {
        case .newSession:
            store.addSession()
        case .closeTab:
            store.closeFocusedTab()
        case .newTab:
            store.selectedSession?.focusedPane.addTab(
                inheritingCWDFrom: store.selectedSession?.focusedPane.activeTab
            )
        case .splitHorizontal:
            if let tree = store.selectedSession?.tree {
                tree.splitFocusedPane(direction: .horizontal, inheritingFrom: tree.focusedPane)
            }
        case .splitVertical:
            if let tree = store.selectedSession?.tree {
                tree.splitFocusedPane(direction: .vertical, inheritingFrom: tree.focusedPane)
            }
        case .focusPaneLeft:
            store.selectedSession?.focusPane(adjacent: .left)
        case .focusPaneRight:
            store.selectedSession?.focusPane(adjacent: .right)
        case .focusPaneUp:
            store.selectedSession?.focusPane(adjacent: .up)
        case .focusPaneDown:
            store.selectedSession?.focusPane(adjacent: .down)
        case .previousTab:
            store.selectedSession?.focusedPane.selectPreviousTab()
        case .nextTab:
            store.selectedSession?.focusedPane.selectNextTab()
        case .toggleSidebar:
            let defaults = UserDefaults.standard
            let current = defaults.bool(forKey: SidebarPreference.hiddenKey)
            defaults.set(!current, forKey: SidebarPreference.hiddenKey)
        case .toggleBellFeed:
            NotificationCenter.default.post(name: .battyToggleBellFeed, object: nil)
        case .commandPalette:
            NotificationCenter.default.post(name: .battyToggleCommandPalette, object: nil)
        case .openQuickly:
            NotificationCenter.default.post(name: .battyToggleOpenQuickly, object: nil)
        }
    }
}
