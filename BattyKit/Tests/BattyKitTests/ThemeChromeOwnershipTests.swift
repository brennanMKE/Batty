// ThemeChromeOwnershipTests.swift

import AppKit
import Foundation
import Observation
import Testing
@testable import BattyKit

private nonisolated final class ChromeChangeFlag: @unchecked Sendable {
    var fired = false
}

/// Each window's chrome is derived from observed inputs
/// (`AppStateStore.chromePalette(for:)`) and nothing writes it. Window A
/// follows the global Theme; window B's selected Session has its own Theme.
/// The global dark, global light and Session Themes all differ, and none is
/// a built-in default, so no assertion holds by accident.
@MainActor
final class ThemeChromeOwnershipTests {
    private let testDefaults = TestDefaults()
    private let dark: GhosttyThemeDefinition
    private let light: GhosttyThemeDefinition
    private let sessionTheme: GhosttyThemeDefinition
    private let other: GhosttyThemeDefinition
    let store: AppStateStore
    let a: WindowRuntime
    let b: WindowRuntime

    init() {
        let avoid: Set<String> = [ThemePreference.defaultDarkThemeName, ThemePreference.defaultLightThemeName]
        let pool = BattyThemeCatalog.allThemes.filter { !avoid.contains($0.name) }
        dark = pool[0]
        light = pool[1]
        sessionTheme = pool[2]
        other = pool[3]
        let defaults = testDefaults.defaults
        defaults.set(true, forKey: ThemePreference.migrationDoneKey)
        defaults.set(dark.name, forKey: ThemePreference.darkDefaultsKey)
        defaults.set(light.name, forKey: ThemePreference.lightDefaultsKey)
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-chrome-ownership-\(UUID().uuidString)")
            .appendingPathComponent("session-name-cache.json")
        let cache = SessionNameCache(fileURL: cacheURL, debounce: .zero, homeDirectory: "/Users/test")
        store = AppStateStore(nameCache: cache, preferences: defaults)
        store.applyGlobalThemeForCurrentAppearance(isDark: true)
        a = store.windows[0]
        b = store.openWindowRuntime(for: WindowID())
        b.sessions[0].themeOverride = .both(sessionTheme.name)
    }

    @MainActor deinit { testDefaults.tearDown() }

    private func palette(_ theme: GhosttyThemeDefinition) -> ChromePalette { ChromePalette(theme: theme) }

    /// Fires when an input of `window`'s chrome derivation changes, which is
    /// what re-runs its `WindowChromeScope`.
    private func track(_ window: WindowRuntime) -> ChromeChangeFlag {
        let flag = ChromeChangeFlag()
        withObservationTracking { _ = store.themeChrome(for: window) } onChange: { flag.fired = true }
        return flag
    }

    private func chrome(_ window: WindowRuntime) -> ChromePalette { store.chromePalette(for: window) }

    @Test func eachWindowsChromeFollowsItsOwnSelectedSession() {
        #expect(palette(dark) != palette(sessionTheme))
        #expect(chrome(a) == palette(dark))
        #expect(chrome(b) == palette(sessionTheme))
    }

    @Test func becomingKeyAndRegistrationDoNotInvalidateChrome() {
        let trackA = track(a)
        let trackB = track(b)
        let nsWindow = NSWindow()
        nsWindow.isReleasedWhenClosed = false

        store.contentWindowBecameKey(b.id)
        store.registerNSWindow(nsWindow, for: b.id)

        #expect(!trackA.fired)
        #expect(!trackB.fired)
        #expect(chrome(a) == palette(dark))
        #expect(chrome(b) == palette(sessionTheme))
        store.unregisterNSWindow(nsWindow)
    }

    @Test func sessionThemeCommitRechromesOnlyItsWindow() throws {
        let trackA = track(a)
        let trackB = track(b)
        let session = try #require(a.selectedSession)

        store.setSessionTheme(other, for: session)

        #expect(trackA.fired)
        #expect(!trackB.fired)
        #expect(chrome(a) == palette(other))
    }

    @Test func selectingAnotherSessionRechromesThatWindow() throws {
        let first = try #require(a.selectedSession)
        let themed = a.addSession()
        themed.themeOverride = .both(other.name)
        a.setSelectedSession(id: first.id)
        #expect(chrome(a) == palette(dark))
        let trackA = track(a)

        a.setSelectedSession(id: themed.id)

        #expect(trackA.fired)
        #expect(chrome(a) == palette(other))
    }

    @Test func appearanceFlipRechromesGlobalFollowingWindows() {
        let trackA = track(a)

        store.applyGlobalThemeForCurrentAppearance(isDark: false)

        #expect(trackA.fired)
        #expect(chrome(a) == palette(light))
        #expect(chrome(b) == palette(sessionTheme))
    }

    @Test func globalThemeChangeRechromesOnlyFollowingWindows() {
        let trackA = track(a)
        let trackB = track(b)

        store.setGlobalTheme(named: other.name, isDark: true, appearanceIsDark: true)

        #expect(trackA.fired)
        #expect(!trackB.fired)
        #expect(chrome(a) == palette(other))
        #expect(chrome(b) == palette(sessionTheme))
    }

    @Test func sessionPreviewShowsInChromeAndEndRestores() throws {
        let session = try #require(b.selectedSession)

        store.previewSessionTheme(other, for: session)
        #expect(chrome(b) == palette(other))

        store.endSessionThemePreviews(in: b, isDark: true)
        #expect(chrome(b) == palette(sessionTheme))
    }

    @Test func globalPreviewShowsInChromeAndEndRestores() {
        store.previewGlobalTheme(other, isDark: true)
        #expect(chrome(a) == palette(other))
        #expect(chrome(b) == palette(sessionTheme))

        store.endGlobalThemePreview(isDark: true)
        #expect(chrome(a) == palette(dark))
    }

    @Test func chromeIsOneInstancePerThemeName() throws {
        #expect(store.themeChromeCache.countForTesting == 0)
        let first = store.themeChrome(for: a)
        #expect(store.themeChrome(for: a) === first)
        #expect(store.themeChromeCache.countForTesting == 1)

        let sibling = a.addSession()
        a.setSelectedSession(id: sibling.id)
        #expect(store.themeChrome(for: a) === first, "a switch to a Session with the same Theme changed the injected chrome")
        #expect(store.themeChromeCache.countForTesting == 1)
    }
}
