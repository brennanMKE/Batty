// AppearanceObserverTests.swift

import AppKit
import Testing
@testable import BattyKit

/// Regression test for #0320: `AppearanceObserver`'s KVO callback on
/// `NSApp.effectiveAppearance` calls the main-actor-isolated
/// `applyGlobalThemeForCurrentAppearance()` from a closure the compiler
/// treats as a nonisolated context (the `NSKeyValueObservation` API is not
/// concurrency-audited). The fix asserts main-actor isolation at the call
/// site via `MainActor.assumeIsolated` rather than suppressing the warning;
/// this test proves the callback still reaches the store correctly and,
/// just as important, would fail loudly (a trap, not a silent skip) if that
/// assumption were ever wrong.
// `.serialized` because this suite mutates two process-global values —
// `NSApp.appearance` and three `UserDefaults.standard` keys — and Swift
// Testing parallelises suites by default. No sibling suite reads
// `NSApp.effectiveAppearance` today; this keeps that from becoming a
// silent flake the day one does.
//
// `UserDefaults.standard` rather than an isolated suite (the convention in
// `ThemePreferenceTests`) because the production path under test —
// `applyGlobalThemeForCurrentAppearance` -> `ThemePreference.activeTheme(isDark:)`
// — hardcodes `.standard`; the injectable overload is unreachable from
// production. The test host is bare `xctest`, so this is the tool's
// defaults domain, never the developer's installed Batty.
@Suite(.serialized)
@MainActor
struct AppearanceObserverTests {

    @Test func effectiveAppearanceChangeAppliesGlobalTheme() {
        // `NSApp` is a lazily-populated global (`NSApplication!`) normally
        // set as a side effect of app launch. `swift test` on the bare
        // package never launches an app, so touch `.shared` explicitly —
        // otherwise `NSApp.observe(...)` in `AppearanceObserver.init`
        // force-unwraps a nil global.
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let originalDark = defaults.string(forKey: ThemePreference.darkDefaultsKey)
        let originalLight = defaults.string(forKey: ThemePreference.lightDefaultsKey)
        let originalMigrated = defaults.object(forKey: ThemePreference.migrationDoneKey)
        defer {
            setOrRemove(originalDark, forKey: ThemePreference.darkDefaultsKey, in: defaults)
            setOrRemove(originalLight, forKey: ThemePreference.lightDefaultsKey, in: defaults)
            setOrRemove(originalMigrated, forKey: ThemePreference.migrationDoneKey, in: defaults)
        }
        defaults.set(ThemePreference.defaultDarkThemeName, forKey: ThemePreference.darkDefaultsKey)
        defaults.set(ThemePreference.defaultLightThemeName, forKey: ThemePreference.lightDefaultsKey)
        defaults.set(true, forKey: ThemePreference.migrationDoneKey)

        let store = AppStateStore()
        let observer = AppearanceObserver(store: store)

        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }

        let wasDark = NSApp.effectiveAppearance.isDark
        let before = store.themeChrome.palette

        NSApp.appearance = NSAppearance(named: wasDark ? .aqua : .darkAqua)

        let expectedTheme = ThemePreference.activeTheme(isDark: !wasDark)
        let after = store.themeChrome.palette

        // Distinct dark/light defaults guarantee `before != expected`, so
        // `after == expected` only holds if the KVO callback actually ran
        // and reached the main actor — it is not trivially true.
        #expect(before != ChromePalette(theme: expectedTheme))
        #expect(after == ChromePalette(theme: expectedTheme))

        withExtendedLifetime(observer) {}
    }

    private func setOrRemove(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
