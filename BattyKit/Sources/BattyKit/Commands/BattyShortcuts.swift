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
        // The key monitor is global, so without this gate Cmd-W in the
        // Settings panel would fire `closeTab` against the background main
        // window — closing its last tab, cascading to session removal, and
        // terminating the app. Only run content-window shortcuts when a
        // registered content window is key; Settings / Help / panels are
        // excluded by not being in the NSWindow↔WindowID registry.
        let appStore = AppStateStore.shared
        guard appStore.keyWindowIsContentWindow() else { return false }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if let candidate = makeCandidate(from: event, mods: mods) {
            let shortcuts = ShortcutsStore.shared
            for action in ShortcutAction.allCases where shortcuts.binding(for: action) == candidate {
                run(action, appStore: appStore)
                return true
            }
        }

        // Per-window dispatch for positional bindings targets the key window's runtime.
        guard let windowRuntime = appStore.keyWindowRuntime() else { return false }

        // Positional bindings — intentionally NOT customizable in v1.
        // The preference is read at dispatch time (rather than baked into
        // bindings registered once at launch) so the swap takes effect live.
        let cmdSwitchesSessions = currentCmdNumberTarget() == .sessions

        switch (mods, chars) {
        case ([.command], let digit) where digit.count == 1 && digit.first?.isWholeNumber == true:
            if let index = Int(digit), (1...9).contains(index) {
                if cmdSwitchesSessions {
                    windowRuntime.selectSession(at: index - 1)
                } else {
                    windowRuntime.selectedSession?.focusedTerminalPane?.selectTab(at: index - 1)
                }
                return true
            }
            return false

        case ([.command, .option], let digit) where digit.count == 1 && digit.first?.isWholeNumber == true:
            if let index = Int(digit), (1...9).contains(index) {
                if cmdSwitchesSessions {
                    windowRuntime.selectedSession?.focusedTerminalPane?.selectTab(at: index - 1)
                } else {
                    windowRuntime.selectSession(at: index - 1)
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

    private static func run(_ action: ShortcutAction, appStore: AppStateStore) {
        logger.info("dispatching action \(action.rawValue, privacy: .public)")
        // New Window is app-level; all other actions target the key window's runtime.
        if action == .newWindow {
            appStore.openWindowAction?()
            return
        }
        guard let window = appStore.keyWindowRuntime() else { return }
        switch action {
        case .newSession:
            window.addSession()
        case .closeTab:
            // `WindowRuntime.closeFocusedTab()` itself branches on
            // `SessionRuntime.focusedTerminalPane` (#0315 review round 2,
            // finding 2): closes the active Tab for a `.terminal` focused
            // pane, or the Pane itself otherwise (#0334) — no separate
            // check needed here either way.
            window.closeFocusedTab()
        case .newTab:
            // Kind-gated via `focusedTerminalPane`, not `focusedPane`: a
            // non-terminal pane's one TabRuntime is a structural
            // placeholder PaneView never renders — Cmd-T on a focused
            // non-terminal pane must not silently add a second invisible
            // tab nobody can see or reach.
            window.selectedSession?.focusedTerminalPane?.addTab(
                inheritingCWDFrom: window.selectedSession?.focusedTerminalPane?.activeTab
            )
        case .splitHorizontal:
            if let tree = window.selectedSession?.tree {
                tree.splitFocusedPane(direction: .horizontal, inheritingFrom: tree.focusedPane)
            }
        case .splitVertical:
            if let tree = window.selectedSession?.tree {
                tree.splitFocusedPane(direction: .vertical, inheritingFrom: tree.focusedPane)
            }
        case .splitFullHeightColumn:
            if let tree = window.selectedSession?.tree {
                tree.splitFullDimension(direction: .horizontal, inheritingFrom: tree.focusedPane)
            }
        case .splitFullWidthRow:
            if let tree = window.selectedSession?.tree {
                tree.splitFullDimension(direction: .vertical, inheritingFrom: tree.focusedPane)
            }
        case .focusPaneLeft:
            window.selectedSession?.focusPane(adjacent: .left)
        case .focusPaneRight:
            window.selectedSession?.focusPane(adjacent: .right)
        case .focusPaneUp:
            window.selectedSession?.focusPane(adjacent: .up)
        case .focusPaneDown:
            window.selectedSession?.focusPane(adjacent: .down)
        case .previousTab:
            window.selectedSession?.focusedTerminalPane?.selectPreviousTab()
        case .nextTab:
            window.selectedSession?.focusedTerminalPane?.selectNextTab()
        case .toggleSidebar:
            NotificationCenter.default.post(name: .battyToggleSidebar, object: nil)
        case .toggleBellFeed:
            NotificationCenter.default.post(name: .battyToggleBellFeed, object: nil)
        case .commandPalette:
            NotificationCenter.default.post(name: .battyToggleCommandPalette, object: nil)
        case .openQuickly:
            NotificationCenter.default.post(name: .battyToggleOpenQuickly, object: nil)
        case .layoutPicker:
            NotificationCenter.default.post(name: .battyToggleLayoutPicker, object: nil)
        case .themeSelector:
            NotificationCenter.default.post(name: .battyToggleThemeSelector, object: nil)
        case .exitShell:
            ExitDispatcher.sendExit(store: appStore)
        case .resizeSplitLeft:
            window.selectedSession?.tree.resizeFocusedSplit(.left)
        case .resizeSplitRight:
            window.selectedSession?.tree.resizeFocusedSplit(.right)
        case .resizeSplitUp:
            window.selectedSession?.tree.resizeFocusedSplit(.up)
        case .resizeSplitDown:
            window.selectedSession?.tree.resizeFocusedSplit(.down)
        case .newWindow:
            // Already handled above; unreachable.
            break
        }
    }
}
