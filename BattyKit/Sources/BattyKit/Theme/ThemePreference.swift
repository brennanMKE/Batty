// ThemePreference.swift

import AppKit
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ThemePreference")

public enum ThemePreference {
    // MARK: - Keys

    /// Per-appearance theme name slots. The global theme choice is stored
    /// separately for Dark and Light so a switch between appearances
    /// re-applies the matching theme automatically.
    public static let darkDefaultsKey = "co.sstools.Batty.themeName.dark"
    public static let lightDefaultsKey = "co.sstools.Batty.themeName.light"

    /// The legacy single-appearance key. Read once during migration; never
    /// written after the upgrade path runs. Kept as `internal` rather than
    /// private so unit tests can write it to exercise the migration path.
    static let legacyDefaultsKey = "co.sstools.Batty.themeName"

    // MARK: - Built-in defaults

    /// Default theme for Dark appearance. "TokyoNight" is widely recognised,
    /// ships in the catalog, and has a dark (#1a1b26) background.
    public static let defaultDarkThemeName = "TokyoNight"

    /// Default theme for Light appearance. "TokyoNight Day" is the official
    /// light companion to "TokyoNight" in the same family, and has a light
    /// (#e1e2e7) background.
    public static let defaultLightThemeName = "TokyoNight Day"

    // MARK: - Key selection

    /// Returns the `UserDefaults` key for the given appearance darkness flag.
    public static func defaultsKey(isDark: Bool) -> String {
        isDark ? darkDefaultsKey : lightDefaultsKey
    }

    // MARK: - Active-theme resolution with migration + default seeding

    /// Looks up the stored theme for `isDark`, migrating the legacy single-key
    /// value and seeding defaults for both slots on first call after upgrade
    /// or on a fresh install. Returns `nil` when the stored name is empty or
    /// not found in the catalog.
    public static func activeTheme(isDark: Bool) -> GhosttyThemeDefinition? {
        activeTheme(isDark: isDark, defaults: .standard)
    }

    /// Testable overload that accepts an explicit `UserDefaults` suite so unit
    /// tests can run the full migration + resolution path in isolation.
    static func activeTheme(isDark: Bool, defaults: UserDefaults) -> GhosttyThemeDefinition? {
        migrateAndSeedIfNeeded(into: defaults)
        let key = defaultsKey(isDark: isDark)
        guard let name = defaults.string(forKey: key),
              !name.isEmpty else { return nil }
        return GhosttyThemeCatalog.theme(named: name)
    }

    /// Reads the currently-active appearance from `NSApp` and resolves the
    /// matching stored theme. Falls back to dark when no shared application
    /// exists (unit-test context).
    public static func activeTheme() -> GhosttyThemeDefinition? {
        activeTheme(isDark: NSApp?.effectiveAppearance.isDark ?? true)
    }

    // MARK: - Migration + default seeding

    /// Migration flag key. Written once; presence indicates that the legacy
    /// single-key has already been processed (or that this is a fresh install
    /// that was seeded with defaults).
    static let migrationDoneKey = "co.sstools.Batty.themeName.migrated"

    /// Runs at most once per app lifetime (guarded by `migrationDoneKey`).
    /// On fresh install (no legacy key), seeds both slots with the built-in
    /// defaults. On upgrade from the single-key era, copies the legacy value
    /// into both slots so the user's choice is preserved in both appearances.
    /// After migration the legacy key is left in place for downgrade safety —
    /// it is simply no longer read by this path. The `into` parameter is
    /// injectable for unit testing; production callers omit it (uses `.standard`).
    public static func migrateAndSeedIfNeeded() {
        migrateAndSeedIfNeeded(into: .standard)
    }

    static func migrateAndSeedIfNeeded(into defaults: UserDefaults) {
        guard !defaults.bool(forKey: migrationDoneKey) else { return }
        defer { defaults.set(true, forKey: migrationDoneKey) }

        if let legacy = defaults.string(forKey: legacyDefaultsKey), !legacy.isEmpty {
            // Upgrade path: preserve the user's existing single choice in both
            // slots so neither appearance loses the theme they'd been using.
            logger.info("ThemePreference: migrating legacy theme '\(legacy, privacy: .public)' to both dark/light slots")
            if defaults.string(forKey: darkDefaultsKey) == nil {
                defaults.set(legacy, forKey: darkDefaultsKey)
            }
            if defaults.string(forKey: lightDefaultsKey) == nil {
                defaults.set(legacy, forKey: lightDefaultsKey)
            }
        } else {
            // Fresh install: seed reasonable defaults for both slots.
            logger.info("ThemePreference: seeding defaults dark='\(defaultDarkThemeName, privacy: .public)' light='\(defaultLightThemeName, privacy: .public)'")
            if defaults.string(forKey: darkDefaultsKey) == nil {
                defaults.set(defaultDarkThemeName, forKey: darkDefaultsKey)
            }
            if defaults.string(forKey: lightDefaultsKey) == nil {
                defaults.set(defaultLightThemeName, forKey: lightDefaultsKey)
            }
        }
    }
}

// MARK: - NSAppearance helpers

extension NSAppearance {
    /// True when the appearance resolves to a dark variant.
    var isDark: Bool {
        let resolved = bestMatch(from: [.darkAqua, .aqua])
        return resolved == .darkAqua
    }
}

// MARK: - AppStateStore theme application

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
    /// key for the current appearance → system default. Called on every session
    /// switch and on first appear.
    public func applyActiveSessionTheme() {
        applyActiveSessionTheme(for: selectedSession)
    }

    /// Applies the effective theme for a specific session. Called by
    /// per-window views that resolve the selected session from their own
    /// `WindowRuntime` rather than the global forwarding shim.
    public func applyActiveSessionTheme(for session: SessionRuntime?) {
        guard let session else {
            logger.debug("applyActiveSessionTheme: no selected session")
            return
        }
        let isDark = NSApp?.effectiveAppearance.isDark ?? true
        let globalKey = ThemePreference.defaultsKey(isDark: isDark)
        let themeName = session.localThemeName
            ?? UserDefaults.standard.string(forKey: globalKey)
        if let name = themeName, !name.isEmpty,
           let theme = GhosttyThemeCatalog.theme(named: name) {
            let source = session.localThemeName != nil ? "local" : "global(\(isDark ? "dark" : "light"))"
            logger.info("applyActiveSessionTheme: session=\(session.title, privacy: .public) theme=\(name, privacy: .public) source=\(source, privacy: .public)")
            applyTheme(theme, to: session)
        } else {
            logger.info("applyActiveSessionTheme: session=\(session.title, privacy: .public) no theme → resetting chrome")
            themeChrome.update(from: nil)
        }
    }

    /// Resolves and applies the global theme for the current appearance to all
    /// surfaces that follow the global theme (no `localThemeName`). Called when
    /// the system appearance changes. Sourced from AppKit KVO (event-origin),
    /// not from view-update code.
    public func applyGlobalThemeForCurrentAppearance() {
        let isDark = NSApp?.effectiveAppearance.isDark ?? true
        logger.info("applyGlobalThemeForCurrentAppearance: isDark=\(isDark, privacy: .public)")
        if let theme = ThemePreference.activeTheme(isDark: isDark) {
            applyThemeToAllSurfaces(theme)
        } else {
            // No global theme stored for this appearance — reset chrome only
            // for sessions that follow the global theme.
            if selectedSession?.localThemeName == nil {
                themeChrome.update(from: nil)
            }
        }
    }
}
