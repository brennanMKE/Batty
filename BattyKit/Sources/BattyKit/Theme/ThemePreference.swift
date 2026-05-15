// ThemePreference.swift

import Foundation

public enum ThemePreference {
    public static let defaultsKey = "co.sstools.Batty.themeName"
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
    }
}
