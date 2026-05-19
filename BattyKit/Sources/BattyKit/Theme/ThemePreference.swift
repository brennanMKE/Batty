// ThemePreference.swift

import Foundation

public enum ThemePreference {
    public static let defaultsKey = "co.sstools.Batty.themeName"

    /// Looks up the currently-selected `.ghostty` theme, if any. Used at
    /// app launch to seed `AppStateStore.themeChrome` from whatever the
    /// user picked in a previous session.
    public static func activeTheme() -> GhosttyThemeDefinition? {
        guard let name = UserDefaults.standard.string(forKey: defaultsKey),
              !name.isEmpty else { return nil }
        return GhosttyThemeCatalog.theme(named: name)
    }
}

extension AppStateStore {
    public func applyThemeToAllSurfaces(_ theme: GhosttyThemeDefinition) {
        let terminalTheme = theme.toTerminalTheme()
        for session in sessions {
            for pane in session.tree.allPanes {
                for tab in pane.tabs {
                    tab.terminal.controller.setTheme(terminalTheme)
                }
            }
        }
        themeChrome.update(from: theme)
    }

    /// Applies the theme that should be active for the currently-selected
    /// session: the session's `localThemeName` override when set, or the
    /// global `ThemePreference` otherwise. Called on every session-focus
    /// switch so the active theme tracks the selected session.
    public func applyActiveSessionTheme() {
        if let localName = selectedSession?.localThemeName,
           let theme = GhosttyThemeCatalog.theme(named: localName) {
            applyThemeToAllSurfaces(theme)
        } else if let globalTheme = ThemePreference.activeTheme() {
            applyThemeToAllSurfaces(globalTheme)
        }
    }
}
