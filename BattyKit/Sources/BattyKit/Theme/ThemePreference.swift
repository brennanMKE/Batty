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
    /// Applies a theme to every surface in every session. Used by the global
    /// theme selector when the user explicitly picks a theme for all open sessions.
    public func applyThemeToAllSurfaces(_ theme: GhosttyThemeDefinition) {
        logger.info("applyThemeToAllSurfaces: theme=\(theme.name, privacy: .public) sessions=\(self.sessions.count, privacy: .public)")
        let terminalTheme = theme.toTerminalTheme()
        for session in sessions {
            session.localThemeName = theme.name
            for pane in session.tree.allPanes {
                for tab in pane.tabs {
                    tab.terminal.controller.setTheme(terminalTheme)
                }
            }
        }
        themeChrome.update(from: theme)
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

    /// Applies the session-local theme to the currently-selected session's
    /// surfaces when it has a `localThemeName` override. Resets the window
    /// chrome to the system default when no override is set. The global
    /// `ThemePreference` is intentionally NOT used as a fallback here — new
    /// sessions always start unthemed.
    public func applyActiveSessionTheme() {
        guard let session = selectedSession else {
            logger.debug("applyActiveSessionTheme: no selected session")
            return
        }
        if let localName = session.localThemeName,
           let theme = GhosttyThemeCatalog.theme(named: localName) {
            logger.info("applyActiveSessionTheme: session=\(session.title, privacy: .public) localTheme=\(localName, privacy: .public)")
            applyTheme(theme, to: session)
        } else {
            logger.info("applyActiveSessionTheme: session=\(session.title, privacy: .public) localTheme=nil → resetting chrome")
            themeChrome.update(from: nil)
        }
    }
}
