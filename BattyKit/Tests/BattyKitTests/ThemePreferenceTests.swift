// ThemePreferenceTests.swift

import Foundation
import Testing
@testable import BattyKit

struct ThemePreferenceTests {

    // MARK: - Helpers

    /// Returns a fresh `UserDefaults` suite isolated from the host's standard
    /// defaults so tests can't contaminate each other or the developer's prefs.
    private func isolatedDefaults(name: String = #function) -> UserDefaults {
        let suite = "co.sstools.BattyKitTests.ThemePreference.\(name)"
        let d = UserDefaults(suiteName: suite)!
        // Wipe any leftover state from a previous test run.
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: - Key selection

    @Test func darkKeyDiffersFromLightKey() {
        #expect(ThemePreference.darkDefaultsKey != ThemePreference.lightDefaultsKey)
    }

    @Test func defaultsKeyReturnsDarkKeyWhenDark() {
        #expect(ThemePreference.defaultsKey(isDark: true) == ThemePreference.darkDefaultsKey)
    }

    @Test func defaultsKeyReturnsLightKeyWhenLight() {
        #expect(ThemePreference.defaultsKey(isDark: false) == ThemePreference.lightDefaultsKey)
    }

    // MARK: - Migration from legacy single key

    @Test func migrationPreservesLegacyValueInBothSlots() {
        let defaults = isolatedDefaults()
        let legacyName = ThemePreference.defaultDarkThemeName

        // Plant a legacy value exactly as the old code would have.
        defaults.set(legacyName, forKey: ThemePreference.legacyDefaultsKey)

        ThemePreference.migrateAndSeedIfNeeded(into: defaults)

        // Both slots should now carry the legacy value.
        #expect(defaults.string(forKey: ThemePreference.darkDefaultsKey) == legacyName)
        #expect(defaults.string(forKey: ThemePreference.lightDefaultsKey) == legacyName)
        // Migration flag set so the migration won't run again.
        #expect(defaults.bool(forKey: ThemePreference.migrationDoneKey) == true)
    }

    @Test func migrationDoesNotOverwriteExistingSlots() {
        // If the user somehow already had per-appearance prefs set (e.g.
        // downgrade + upgrade), the migration must not clobber them.
        let defaults = isolatedDefaults()
        defaults.set(ThemePreference.defaultDarkThemeName, forKey: ThemePreference.darkDefaultsKey)
        defaults.set(ThemePreference.defaultLightThemeName, forKey: ThemePreference.lightDefaultsKey)
        defaults.set("SomeOtherTheme", forKey: ThemePreference.legacyDefaultsKey)

        ThemePreference.migrateAndSeedIfNeeded(into: defaults)

        // Existing slots must be left alone.
        #expect(defaults.string(forKey: ThemePreference.darkDefaultsKey) == ThemePreference.defaultDarkThemeName)
        #expect(defaults.string(forKey: ThemePreference.lightDefaultsKey) == ThemePreference.defaultLightThemeName)
    }

    @Test func migrationRunsOnlyOnce() {
        let defaults = isolatedDefaults()
        defaults.set("ThemeA", forKey: ThemePreference.legacyDefaultsKey)

        ThemePreference.migrateAndSeedIfNeeded(into: defaults)
        // Simulate a second app launch changing the legacy key (edge case).
        defaults.set("ThemeB", forKey: ThemePreference.legacyDefaultsKey)
        ThemePreference.migrateAndSeedIfNeeded(into: defaults)

        // Second call must be a no-op: the first migration's values survive.
        #expect(defaults.string(forKey: ThemePreference.darkDefaultsKey) == "ThemeA")
        #expect(defaults.string(forKey: ThemePreference.lightDefaultsKey) == "ThemeA")
    }

    // MARK: - Default seeding (fresh install)

    @Test func freshInstallSeedsDefaultDarkTheme() {
        let defaults = isolatedDefaults()

        ThemePreference.migrateAndSeedIfNeeded(into: defaults)

        #expect(defaults.string(forKey: ThemePreference.darkDefaultsKey) == ThemePreference.defaultDarkThemeName)
    }

    @Test func freshInstallSeedsDefaultLightTheme() {
        let defaults = isolatedDefaults()

        ThemePreference.migrateAndSeedIfNeeded(into: defaults)

        #expect(defaults.string(forKey: ThemePreference.lightDefaultsKey) == ThemePreference.defaultLightThemeName)
    }

    @Test func defaultDarkThemeExistsInCatalog() {
        // Guard: if the default theme name is ever wrong or the catalog
        // shrinks, this test fails loudly rather than silently producing a
        // nil theme at runtime.
        let theme = GhosttyThemeCatalog.theme(named: ThemePreference.defaultDarkThemeName)
        #expect(theme != nil)
    }

    @Test func defaultLightThemeExistsInCatalog() {
        let theme = GhosttyThemeCatalog.theme(named: ThemePreference.defaultLightThemeName)
        #expect(theme != nil)
    }

    @Test func defaultDarkThemeIsDark() {
        guard let theme = GhosttyThemeCatalog.theme(named: ThemePreference.defaultDarkThemeName) else {
            Issue.record("default dark theme not found in catalog")
            return
        }
        #expect(theme.isDark == true)
    }

    @Test func defaultLightThemeIsLight() {
        guard let theme = GhosttyThemeCatalog.theme(named: ThemePreference.defaultLightThemeName) else {
            Issue.record("default light theme not found in catalog")
            return
        }
        #expect(theme.isDark == false)
    }

    // MARK: - Per-appearance active-theme resolution

    @Test func activeThemeResolvesCorrectSlotForDark() {
        let defaults = isolatedDefaults()
        defaults.set(ThemePreference.defaultDarkThemeName, forKey: ThemePreference.darkDefaultsKey)
        defaults.set(ThemePreference.defaultLightThemeName, forKey: ThemePreference.lightDefaultsKey)
        defaults.set(true, forKey: ThemePreference.migrationDoneKey)

        let theme = ThemePreference.activeTheme(isDark: true, defaults: defaults)
        #expect(theme?.name == ThemePreference.defaultDarkThemeName)
    }

    @Test func activeThemeResolvesCorrectSlotForLight() {
        let defaults = isolatedDefaults()
        defaults.set(ThemePreference.defaultDarkThemeName, forKey: ThemePreference.darkDefaultsKey)
        defaults.set(ThemePreference.defaultLightThemeName, forKey: ThemePreference.lightDefaultsKey)
        defaults.set(true, forKey: ThemePreference.migrationDoneKey)

        let theme = ThemePreference.activeTheme(isDark: false, defaults: defaults)
        #expect(theme?.name == ThemePreference.defaultLightThemeName)
    }

    @Test func activeThemeReturnsDifferentThemesForDarkAndLight() {
        let defaults = isolatedDefaults()
        defaults.set(ThemePreference.defaultDarkThemeName, forKey: ThemePreference.darkDefaultsKey)
        defaults.set(ThemePreference.defaultLightThemeName, forKey: ThemePreference.lightDefaultsKey)
        defaults.set(true, forKey: ThemePreference.migrationDoneKey)

        let dark = ThemePreference.activeTheme(isDark: true, defaults: defaults)
        let light = ThemePreference.activeTheme(isDark: false, defaults: defaults)
        #expect(dark?.name != light?.name)
    }

    @Test func activeThemeReturnsNilForEmptySlot() {
        let defaults = isolatedDefaults()
        defaults.set("", forKey: ThemePreference.darkDefaultsKey)
        defaults.set(true, forKey: ThemePreference.migrationDoneKey)

        let theme = ThemePreference.activeTheme(isDark: true, defaults: defaults)
        #expect(theme == nil)
    }

    @Test func activeThemeReturnsNilForUnknownThemeName() {
        let defaults = isolatedDefaults()
        defaults.set("NonExistentThemeName12345", forKey: ThemePreference.darkDefaultsKey)
        defaults.set(true, forKey: ThemePreference.migrationDoneKey)

        let theme = ThemePreference.activeTheme(isDark: true, defaults: defaults)
        #expect(theme == nil)
    }
}
