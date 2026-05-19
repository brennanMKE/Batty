// ShortcutAction.swift

import SwiftUI

/// The catalog of user-configurable keyboard shortcuts in Batty. Cmd-1..9
/// (tab activation), Cmd-Option-1..9 (session selection), Cmd-C, and Cmd-V
/// stay fixed — positional and pasteboard standards (see issue #0070).
///
/// Each case is identified by a stable `rawValue` string used as the
/// persistence key in `UserDefaults`. Renaming a case mid-flight would
/// orphan a saved binding; keep the mapping append-only.
public enum ShortcutAction: String, CaseIterable, Hashable, Identifiable, Sendable {
    case newSession
    case closeTab
    case newTab
    case splitHorizontal
    case splitVertical
    case focusPaneLeft
    case focusPaneRight
    case focusPaneUp
    case focusPaneDown
    case previousTab
    case nextTab
    case toggleSidebar
    case toggleBellFeed
    case themeSelector

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .newSession:      return String(localized: "New Session")
        case .closeTab:        return String(localized: "Close Tab")
        case .newTab:          return String(localized: "New Tab")
        case .splitHorizontal: return String(localized: "Split Horizontally")
        case .splitVertical:   return String(localized: "Split Vertically")
        case .focusPaneLeft:   return String(localized: "Focus Pane Left")
        case .focusPaneRight:  return String(localized: "Focus Pane Right")
        case .focusPaneUp:     return String(localized: "Focus Pane Above")
        case .focusPaneDown:   return String(localized: "Focus Pane Below")
        case .previousTab:     return String(localized: "Show Previous Tab")
        case .nextTab:         return String(localized: "Show Next Tab")
        case .toggleSidebar:   return String(localized: "Toggle Sidebar")
        case .toggleBellFeed:  return String(localized: "Toggle Bell Feed")
        case .themeSelector:   return String(localized: "Open Theme Selector")
        }
    }

    /// Default binding shipped in v1. Restored by "Reset" in the Shortcuts pane.
    public var defaultBinding: ShortcutBinding {
        switch self {
        case .newSession:
            return ShortcutBinding(key: "n", modifiers: EventModifiers([.command]).rawValue)
        case .closeTab:
            return ShortcutBinding(key: "w", modifiers: EventModifiers([.command]).rawValue)
        case .newTab:
            return ShortcutBinding(key: "t", modifiers: EventModifiers([.command]).rawValue)
        case .splitHorizontal:
            return ShortcutBinding(key: "d", modifiers: EventModifiers([.command]).rawValue)
        case .splitVertical:
            return ShortcutBinding(key: "d", modifiers: EventModifiers([.command, .shift]).rawValue)
        case .focusPaneLeft:
            return ShortcutBinding(key: ShortcutBinding.SpecialKey.leftArrow.rawValue,
                                   modifiers: EventModifiers([.command, .option]).rawValue)
        case .focusPaneRight:
            return ShortcutBinding(key: ShortcutBinding.SpecialKey.rightArrow.rawValue,
                                   modifiers: EventModifiers([.command, .option]).rawValue)
        case .focusPaneUp:
            return ShortcutBinding(key: ShortcutBinding.SpecialKey.upArrow.rawValue,
                                   modifiers: EventModifiers([.command, .option]).rawValue)
        case .focusPaneDown:
            return ShortcutBinding(key: ShortcutBinding.SpecialKey.downArrow.rawValue,
                                   modifiers: EventModifiers([.command, .option]).rawValue)
        case .previousTab:
            return ShortcutBinding(key: "[", modifiers: EventModifiers([.command, .shift]).rawValue)
        case .nextTab:
            return ShortcutBinding(key: "]", modifiers: EventModifiers([.command, .shift]).rawValue)
        case .toggleSidebar:
            return ShortcutBinding(key: "s", modifiers: EventModifiers([.command, .control]).rawValue)
        case .toggleBellFeed:
            return ShortcutBinding(key: "n", modifiers: EventModifiers([.command, .shift]).rawValue)
        case .themeSelector:
            return ShortcutBinding(key: "t", modifiers: EventModifiers([.command, .shift]).rawValue)
        }
    }
}
