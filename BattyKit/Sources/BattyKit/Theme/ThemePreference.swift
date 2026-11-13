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
        return BattyThemeCatalog.theme(named: name)
    }

    /// Reads the currently-active appearance from `NSApp` and resolves the
    /// matching stored theme. Falls back to dark when no shared application
    /// exists (unit-test context).
    public static func activeTheme() -> GhosttyThemeDefinition? {
        activeTheme(isDark: NSApp?.effectiveAppearance.isDark ?? true)
    }

    /// Resolves a Session's *effective* Theme: the override's slot for
    /// `isDark` if it names a catalog entry, else the global Theme for
    /// `isDark`. The single fallback chain every theme application uses.
    /// `SessionThemeSelectorView` (`#0363`) marks this card as "in effect" —
    /// a Session following the global Theme still has an effective Theme.
    public static func effectiveTheme(override: ThemePair?, isDark: Bool) -> GhosttyThemeDefinition? {
        effectiveTheme(override: override, isDark: isDark, defaults: .standard)
    }

    /// Testable overload — see `activeTheme(isDark:defaults:)`.
    static func effectiveTheme(override: ThemePair?, isDark: Bool, defaults: UserDefaults) -> GhosttyThemeDefinition? {
        overrideTheme(override, isDark: isDark) ?? activeTheme(isDark: isDark, defaults: defaults)
    }

    /// The override's Theme for `isDark`, only when that slot is set and the
    /// catalog has it. `nil` means the Session follows the global Theme in
    /// this appearance.
    public static func overrideTheme(_ override: ThemePair?, isDark: Bool) -> GhosttyThemeDefinition? {
        guard let name = override?.name(isDark: isDark) else { return nil }
        return BattyThemeCatalog.theme(named: name)
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
    /// Applies a theme to every Session that follows the global Theme in the
    /// current appearance. Does NOT write any Session's `themeOverride`.
    public func applyThemeToAllSurfaces(_ theme: GhosttyThemeDefinition) {
        applyThemeToAllSurfaces(theme, isDark: NSApp?.effectiveAppearance.isDark ?? true)
    }

    func applyThemeToAllSurfaces(_ theme: GhosttyThemeDefinition, isDark: Bool) {
        // The global theme is app-wide (per-window themes are out of scope —
        // multi-window-design.md §10), so re-theme every window's surfaces,
        // not just windows[0]. The `sessions` shim resolves to windows[0]
        // only; iterating `windows` directly avoids re-theming a single
        // window and leaving the others (and often the key window) stale.
        let following = windows.flatMap { $0.sessions }.filter {
            ThemePreference.overrideTheme($0.themeOverride, isDark: isDark) == nil
        }
        logger.info("applyThemeToAllSurfaces: theme=\(theme.name, privacy: .public) following=\(following.count, privacy: .public) windows=\(self.windows.count, privacy: .public)")
        for session in following {
            applyTerminalTheme(theme, to: session)
        }
        // themeChrome is a single app-wide object that follows the default
        // target window's selected Session; global-theme changes originate
        // from Settings, which is not tied to a content window.
        if ThemePreference.overrideTheme(defaultTargetWindow()?.selectedSession?.themeOverride, isDark: isDark) == nil {
            themeChrome.update(from: theme)
        }
    }

    /// Re-themes one Session's terminal surfaces without touching the chrome.
    func applyTerminalTheme(_ theme: GhosttyThemeDefinition, to session: SessionRuntime) {
        let terminalTheme = theme.toTerminalTheme()
        // A non-terminal pane's `tabs` holds one structural placeholder
        // `TabRuntime` (`PaneRuntime.kind`'s doc comment) — its
        // `TerminalController` was never attached to a rendered surface, so
        // reconfiguring it is wasted work (#0315 review round 1, finding 3).
        for pane in session.tree.allPanes where pane.kind == .terminal {
            for tab in pane.tabs {
                tab.terminal.controller.setTheme(terminalTheme)
            }
        }
    }

    /// Applies a theme only to the surfaces of one session, and to the chrome.
    /// Used when setting or restoring a Session Theme.
    public func applyTheme(_ theme: GhosttyThemeDefinition, to session: SessionRuntime) {
        logger.info("applyTheme: theme=\(theme.name, privacy: .public) session=\(session.title, privacy: .public)")
        applyTerminalTheme(theme, to: session)
        themeChrome.update(from: theme)
    }

    /// Applies the effective theme for the currently-selected session.
    public func applyActiveSessionTheme() {
        applyActiveSessionTheme(for: selectedSession)
    }

    /// Applies the effective theme for a specific session, to its surfaces
    /// and to the chrome.
    public func applyActiveSessionTheme(for session: SessionRuntime?) {
        applyActiveSessionTheme(for: session, isDark: NSApp?.effectiveAppearance.isDark ?? true)
    }

    func applyActiveSessionTheme(for session: SessionRuntime?, isDark: Bool) {
        guard let session else {
            logger.debug("applyActiveSessionTheme: no selected session")
            return
        }
        if let theme = ThemePreference.effectiveTheme(override: session.themeOverride, isDark: isDark, defaults: preferences) {
            logger.info("applyActiveSessionTheme: session=\(session.title, privacy: .public) theme=\(theme.name, privacy: .public)")
            applyTheme(theme, to: session)
        } else {
            logger.info("applyActiveSessionTheme: session=\(session.title, privacy: .public) no theme → resetting chrome")
            themeChrome.update(from: nil)
        }
    }

    /// Re-themes every surface for the current appearance: global-following
    /// Sessions get the global Theme, overriding Sessions get their own slot.
    /// Called when the system appearance changes. Sourced from AppKit KVO
    /// (event-origin), not from view-update code.
    public func applyGlobalThemeForCurrentAppearance() {
        applyGlobalThemeForCurrentAppearance(isDark: NSApp?.effectiveAppearance.isDark ?? true)
    }

    func applyGlobalThemeForCurrentAppearance(isDark: Bool) {
        logger.info("applyGlobalThemeForCurrentAppearance: isDark=\(isDark, privacy: .public)")
        if let theme = ThemePreference.activeTheme(isDark: isDark, defaults: preferences) {
            applyThemeToAllSurfaces(theme, isDark: isDark)
        }
        for session in windows.flatMap({ $0.sessions }) {
            if let own = ThemePreference.overrideTheme(session.themeOverride, isDark: isDark) {
                applyTerminalTheme(own, to: session)
            }
        }
        // themeChrome is app-wide and follows the default target window's
        // selected Session; the appearance-change event (AppKit KVO) is not
        // scoped to a particular window.
        themeChrome.update(from: ThemePreference.effectiveTheme(override: defaultTargetWindow()?.selectedSession?.themeOverride, isDark: isDark, defaults: preferences))
    }

    /// The Theme work of a selection change in `window`, run from
    /// `WindowRuntime.selectedSessionID`'s `didSet` through
    /// `selectionThemeHandler`. Re-themes the selected Session's surfaces in
    /// whichever window the selection changed, and the app-wide chrome only
    /// when `window` is the default target window, so the chrome follows
    /// the key window's Session.
    func applySelectionTheme(for window: WindowRuntime) {
        applySelectionTheme(for: window, isDark: NSApp?.effectiveAppearance.isDark ?? true)
    }

    func applySelectionTheme(for window: WindowRuntime, isDark: Bool) {
        guard let session = window.selectedSession else { return }
        let theme = ThemePreference.effectiveTheme(override: session.themeOverride, isDark: isDark, defaults: preferences)
        if let theme {
            applyTerminalTheme(theme, to: session)
        }
        if defaultTargetWindow() === window {
            themeChrome.update(from: theme)
        }
    }

    /// Points the app-wide chrome at `window`'s selected Session's Theme.
    /// Chrome only: the Session's surfaces were themed when it was selected.
    func applyChrome(for window: WindowRuntime) {
        applyChrome(for: window, isDark: NSApp?.effectiveAppearance.isDark ?? true)
    }

    func applyChrome(for window: WindowRuntime, isDark: Bool) {
        guard let session = window.selectedSession else { return }
        themeChrome.update(from: ThemePreference.effectiveTheme(override: session.themeOverride, isDark: isDark, defaults: preferences))
    }
}
