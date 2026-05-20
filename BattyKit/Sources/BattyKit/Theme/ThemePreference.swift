// ThemePreference.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ThemePreference")

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
    /// Applies a theme to every session that has no local override. Used by
    /// the global theme selector — does NOT write `localThemeName` on any
    /// session, so they remain "following global" and will pick up future
    /// global-theme changes automatically.
    public func applyThemeToAllSurfaces(_ theme: GhosttyThemeDefinition) {
        let unoverridden = sessions.filter { $0.localThemeName == nil }
        logger.info("applyThemeToAllSurfaces: theme=\(theme.name, privacy: .public) unoverridden=\(unoverridden.count, privacy: .public)/\(self.sessions.count, privacy: .public)")
        let terminalTheme = theme.toTerminalTheme()
        for session in unoverridden {
            for pane in session.tree.allPanes {
                for tab in pane.tabs {
                    tab.terminal.controller.setTheme(terminalTheme)
                }
            }
        }
        if selectedSession?.localThemeName == nil {
            themeChrome.update(from: theme)
        }
    }

    /// Applies a theme only to the surfaces of one session. Used when setting
    /// or restoring a session-local theme override.
    public func applyTheme(_ theme: GhosttyThemeDefinition, to session: SessionRuntime) {
        logger.info("applyTheme: theme=\(theme.name, privacy: .public) session=\(session.title, privacy: .public)")
        let terminalTheme = theme.toTerminalTheme()
        for pane in session.tree.allPanes {
            for tab in pane.tabs {
                tab.terminal.controller.setTheme(terminalTheme)
            }
        }
        themeChrome.update(from: theme)
    }

    /// Applies the effective theme for the currently-selected session.
    /// Resolves the fallback chain: session-local override → global UserDefaults
    /// key → system default. Called on every session switch and on first appear.
    public func applyActiveSessionTheme() {
        guard let session = selectedSession else {
            logger.debug("applyActiveSessionTheme: no selected session")
            return
        }
        let themeName = session.localThemeName
            ?? UserDefaults.standard.string(forKey: ThemePreference.defaultsKey)
        if let name = themeName, !name.isEmpty,
           let theme = GhosttyThemeCatalog.theme(named: name) {
            let source = session.localThemeName != nil ? "local" : "global"
            logger.info("applyActiveSessionTheme: session=\(session.title, privacy: .public) theme=\(name, privacy: .public) source=\(source, privacy: .public)")
            applyTheme(theme, to: session)
        } else {
            logger.info("applyActiveSessionTheme: session=\(session.title, privacy: .public) no theme → resetting chrome")
            themeChrome.update(from: nil)
        }
    }
}
