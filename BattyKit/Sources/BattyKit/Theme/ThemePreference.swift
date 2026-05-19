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
}
