// ShortcutAction.swift

import SwiftUI

/// The catalog of user-configurable keyboard shortcuts in Batty. Cmd-C and
/// Cmd-V stay fixed — pasteboard standards (see issue #0070). The positional
/// Cmd-1..9 / Cmd-Option-1..9 pair also stays outside this catalog, but which
/// chord selects Sessions vs. Tabs is swappable via the
/// `co.sstools.Batty.cmdNumberTarget` preference (`SettingsPreference`); by
/// default Cmd-1..9 selects Sessions and Cmd-Option-1..9 selects Tabs.
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
    case splitFullHeightColumn
    case splitFullWidthRow
    // #0331: creates a typed Pane split off the focused Pane — the menu/
    // Command Palette/shortcut counterpart to #0315's CLI
    // `batty pane split --view <kind>`. Eight cases (one pair per kind,
    // matching splitHorizontal/splitVertical's own plain-Cmd/Cmd-Shift
    // pairing) rather than a single "pick a kind" action, so each is
    // individually rebindable and shows up in the Command Palette and
    // Settings ▸ Shortcuts on its own, same as every other catalog entry.
    case splitHorizontalGitStatus
    case splitVerticalGitStatus
    case splitHorizontalProcessStatus
    case splitVerticalProcessStatus
    case splitHorizontalLMStudioDashboard
    case splitVerticalLMStudioDashboard
    case splitHorizontalSystemMetrics
    case splitVerticalSystemMetrics
    case focusPaneLeft
    case focusPaneRight
    case focusPaneUp
    case focusPaneDown
    case previousTab
    case nextTab
    case toggleSidebar
    case toggleBellFeed
    case commandPalette
    case openQuickly
    case layoutPicker
    case themeSelector
    case newWindow
    case exitShell
    case resizeSplitLeft
    case resizeSplitRight
    case resizeSplitUp
    case resizeSplitDown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .newSession:      return String(localized: "New Session")
        case .closeTab:        return String(localized: "Close Tab")
        case .newTab:          return String(localized: "New Tab")
        case .splitHorizontal: return String(localized: "Split Horizontally")
        case .splitVertical:   return String(localized: "Split Vertically")
        case .splitFullHeightColumn: return String(localized: "Split Full-Height Column")
        case .splitFullWidthRow:     return String(localized: "Split Full-Width Row")
        case .splitHorizontalGitStatus: return String(localized: "Split Horizontally (Git Status)")
        case .splitVerticalGitStatus:   return String(localized: "Split Vertically (Git Status)")
        case .splitHorizontalProcessStatus: return String(localized: "Split Horizontally (Process Status)")
        case .splitVerticalProcessStatus:   return String(localized: "Split Vertically (Process Status)")
        case .splitHorizontalLMStudioDashboard: return String(localized: "Split Horizontally (LM Studio Dashboard)")
        case .splitVerticalLMStudioDashboard:   return String(localized: "Split Vertically (LM Studio Dashboard)")
        case .splitHorizontalSystemMetrics: return String(localized: "Split Horizontally (System Metrics)")
        case .splitVerticalSystemMetrics:   return String(localized: "Split Vertically (System Metrics)")
        case .focusPaneLeft:   return String(localized: "Focus Pane Left")
        case .focusPaneRight:  return String(localized: "Focus Pane Right")
        case .focusPaneUp:     return String(localized: "Focus Pane Above")
        case .focusPaneDown:   return String(localized: "Focus Pane Below")
        case .previousTab:     return String(localized: "Show Previous Tab")
        case .nextTab:         return String(localized: "Show Next Tab")
        case .toggleSidebar:   return String(localized: "Toggle Sidebar")
        case .toggleBellFeed:  return String(localized: "Toggle Bell Feed")
        case .commandPalette:  return String(localized: "Open Command Palette")
        case .openQuickly:     return String(localized: "Open Quickly")
        case .layoutPicker:    return String(localized: "Open Layout Picker")
        case .themeSelector:   return String(localized: "Open Theme Selector")
        case .newWindow:       return String(localized: "New Window")
        case .exitShell:       return String(localized: "Exit Shell")
        case .resizeSplitLeft:  return String(localized: "Move Split Divider Left")
        case .resizeSplitRight: return String(localized: "Move Split Divider Right")
        case .resizeSplitUp:    return String(localized: "Move Split Divider Up")
        case .resizeSplitDown:  return String(localized: "Move Split Divider Down")
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
        case .splitFullHeightColumn:
            return ShortcutBinding(key: "d", modifiers: EventModifiers([.command, .option]).rawValue)
        case .splitFullWidthRow:
            return ShortcutBinding(key: "d", modifiers: EventModifiers([.command, .shift, .option]).rawValue)
        // #0331: `g`/`j`/`y`/`e` — chosen free of every existing catalog
        // entry, every fixed/clipboard combo, and every macOS-reserved
        // combo in `docs/shortcuts.md` (verified against
        // `ShortcutAction.allCases` and `ShortcutsStore.reservedShortcuts`
        // by hand before picking these). Mnemonic where one was free
        // (`g` for Git); arbitrary but collision-free otherwise, per the
        // user's own "pick reasonable letters, adjust later" directive.
        case .splitHorizontalGitStatus:
            return ShortcutBinding(key: "g", modifiers: EventModifiers([.command]).rawValue)
        case .splitVerticalGitStatus:
            return ShortcutBinding(key: "g", modifiers: EventModifiers([.command, .shift]).rawValue)
        case .splitHorizontalProcessStatus:
            return ShortcutBinding(key: "j", modifiers: EventModifiers([.command]).rawValue)
        case .splitVerticalProcessStatus:
            return ShortcutBinding(key: "j", modifiers: EventModifiers([.command, .shift]).rawValue)
        case .splitHorizontalLMStudioDashboard:
            return ShortcutBinding(key: "y", modifiers: EventModifiers([.command]).rawValue)
        case .splitVerticalLMStudioDashboard:
            return ShortcutBinding(key: "y", modifiers: EventModifiers([.command, .shift]).rawValue)
        case .splitHorizontalSystemMetrics:
            return ShortcutBinding(key: "e", modifiers: EventModifiers([.command]).rawValue)
        case .splitVerticalSystemMetrics:
            return ShortcutBinding(key: "e", modifiers: EventModifiers([.command, .shift]).rawValue)
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
            return ShortcutBinding(key: "b", modifiers: EventModifiers([.command]).rawValue)
        case .toggleBellFeed:
            return ShortcutBinding(key: "b", modifiers: EventModifiers([.command, .shift]).rawValue)
        case .commandPalette:
            return ShortcutBinding(key: "p", modifiers: EventModifiers([.command, .shift]).rawValue)
        case .openQuickly:
            return ShortcutBinding(key: "o", modifiers: EventModifiers([.command, .shift]).rawValue)
        case .layoutPicker:
            return ShortcutBinding(key: "l", modifiers: EventModifiers([.command, .shift]).rawValue)
        case .themeSelector:
            return ShortcutBinding(key: "t", modifiers: EventModifiers([.command, .shift]).rawValue)
        case .newWindow:
            return ShortcutBinding(key: "n", modifiers: EventModifiers([.command, .shift]).rawValue)
        case .exitShell:
            return ShortcutBinding(key: "x", modifiers: EventModifiers([.command, .shift]).rawValue)
        case .resizeSplitLeft:
            return ShortcutBinding(key: ShortcutBinding.SpecialKey.leftArrow.rawValue,
                                   modifiers: EventModifiers([.command, .control]).rawValue)
        case .resizeSplitRight:
            return ShortcutBinding(key: ShortcutBinding.SpecialKey.rightArrow.rawValue,
                                   modifiers: EventModifiers([.command, .control]).rawValue)
        case .resizeSplitUp:
            return ShortcutBinding(key: ShortcutBinding.SpecialKey.upArrow.rawValue,
                                   modifiers: EventModifiers([.command, .control]).rawValue)
        case .resizeSplitDown:
            return ShortcutBinding(key: ShortcutBinding.SpecialKey.downArrow.rawValue,
                                   modifiers: EventModifiers([.command, .control]).rawValue)
        }
    }
}
