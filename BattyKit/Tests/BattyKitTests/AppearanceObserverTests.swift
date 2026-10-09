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
// `.serialized` because this suite mutates the process-global
// `NSApp.appearance`, and Swift Testing parallelises suites by default.
// Every `AppStateStore` construction reads `NSApp.effectiveAppearance` via
// `ThemePreference.activeTheme(isDark:defaults:)` to seed `themeChrome` —
// regardless of which `preferences` it's given — so a sibling suite's own
// `AppStateStore()` could observe this test's appearance flip mid-init if
// the two ran concurrently. The theme keys this test pins live on a
// private `TestDefaults` suite (#0426), which keeps this test's own key
// reads/writes private, but that is a separate concern from the
// `NSApp.appearance` race `.serialized` guards against.
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

        let testDefaults = TestDefaults()
        defer { testDefaults.tearDown() }
        let defaults = testDefaults.defaults
        defaults.set(ThemePreference.defaultDarkThemeName, forKey: ThemePreference.darkDefaultsKey)
        defaults.set(ThemePreference.defaultLightThemeName, forKey: ThemePreference.lightDefaultsKey)
        defaults.set(true, forKey: ThemePreference.migrationDoneKey)

        let store = AppStateStore(preferences: defaults)
        let observer = AppearanceObserver(store: store)

        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }

        let wasDark = NSApp.effectiveAppearance.isDark
        let before = store.themeChrome.palette

        NSApp.appearance = NSAppearance(named: wasDark ? .aqua : .darkAqua)

        let expectedTheme = ThemePreference.activeTheme(isDark: !wasDark, defaults: defaults)
        let after = store.themeChrome.palette

        // Distinct dark/light defaults guarantee `before != expected`, so
        // `after == expected` only holds if the KVO callback actually ran
        // and reached the main actor — it is not trivially true.
        #expect(before != ChromePalette(theme: expectedTheme))
        #expect(after == ChromePalette(theme: expectedTheme))

        withExtendedLifetime(observer) {}
    }
}
