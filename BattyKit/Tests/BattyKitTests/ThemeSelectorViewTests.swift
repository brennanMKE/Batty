// ThemeSelectorViewTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers the pure ordering/index logic behind the Theme Selector's
/// active-Theme mark and keyboard-cursor seeding (`#0363`):
/// `themeDisplayOrder(pinnedIDs:)` and `themeCursorIndex(activeThemeName:
/// pinnedIDs:)`. Both are free functions in `ThemeSelectorView.swift`
/// (`internal`, not `private`) specifically so this logic — which used to
/// only exist as `@State`-entangled computed properties inside the view —
/// can be exercised without standing up any SwiftUI view.
struct ThemeSelectorViewTests {

    // MARK: - themeDisplayOrder

    @Test func displayOrderContainsEveryCatalogThemeExactlyOnce() {
        let order = themeDisplayOrder(pinnedIDs: [])
        #expect(order.count == BattyThemeCatalog.allThemes.count)
        #expect(Set(order.map(\.name)).count == order.count)
    }

    @Test func displayOrderWithNoPinnedThemesMatchesCatalogOrder() {
        let order = themeDisplayOrder(pinnedIDs: [])
        #expect(order.map(\.name) == BattyThemeCatalog.allThemes.map(\.name))
    }

    @Test func displayOrderPlacesPinnedThemeBeforeUnpinnedOnes() {
        let pinnedName = ThemePreference.defaultLightThemeName
        let order = themeDisplayOrder(pinnedIDs: [pinnedName])

        // The sole pinned entry must be the very first element: it's the
        // only member of the "Pinned" section, which always precedes
        // "Themes" / "All Themes" in the selector's layout.
        #expect(order.first?.name == pinnedName)
        #expect(order.count == BattyThemeCatalog.allThemes.count)
    }

    @Test func displayOrderIgnoresUnknownPinnedNames() {
        // A stale pinned id (theme removed from the catalog since it was
        // pinned) must not change the count or crash — it simply never
        // matches `PinnedThemes.contains`.
        let order = themeDisplayOrder(pinnedIDs: ["NotARealThemeName12345"])
        #expect(order.count == BattyThemeCatalog.allThemes.count)
    }

    // MARK: - themeFilterScrollTarget

    @Test func filterScrollTargetIsNilWhenNothingDisplayed() {
        #expect(themeFilterScrollTarget(displayed: []) == nil)
    }

    @Test func filterScrollTargetIsTopIDWhenResultsExist() {
        let displayed = themeDisplayOrder(pinnedIDs: [])
        #expect(themeFilterScrollTarget(displayed: displayed) == themeListTopID)
    }

    // MARK: - themeTopHeaderSection

    @Test func topHeaderIsPinnedWhenPinnedMatchesExist() {
        #expect(themeTopHeaderSection(pinnedCount: 2, othersCount: 0) == .pinned)
        #expect(themeTopHeaderSection(pinnedCount: 2, othersCount: 5) == .pinned)
    }

    @Test func topHeaderIsOthersWhenNothingPinnedMatches() {
        #expect(themeTopHeaderSection(pinnedCount: 0, othersCount: 5) == .others)
    }

    @Test func topHeaderIsNilWhenNothingDisplayed() {
        #expect(themeTopHeaderSection(pinnedCount: 0, othersCount: 0) == nil)
    }

    // MARK: - themeCursorIndex

    @Test func cursorIndexIsZeroWhenNoActiveTheme() {
        #expect(themeCursorIndex(activeThemeName: nil, pinnedIDs: []) == 0)
    }

    @Test func cursorIndexIsZeroWhenActiveThemeNotInCatalog() {
        #expect(themeCursorIndex(activeThemeName: "NotARealThemeName12345", pinnedIDs: []) == 0)
    }

    @Test func cursorIndexFindsActiveThemeInUnpinnedOrder() {
        let name = ThemePreference.defaultDarkThemeName
        let expected = themeDisplayOrder(pinnedIDs: []).firstIndex { $0.name == name }
        #expect(expected != nil)
        #expect(themeCursorIndex(activeThemeName: name, pinnedIDs: []) == expected)
    }

    @Test func cursorIndexAccountsForPinnedReordering() {
        // Pin the active Theme itself: it moves to the front of the
        // "Pinned" section, so its cursor index must be 0 even though it
        // is very unlikely to be alphabetically first in the raw catalog.
        let name = ThemePreference.defaultDarkThemeName
        #expect(themeCursorIndex(activeThemeName: name, pinnedIDs: [name]) == 0)
    }

    @Test func cursorIndexShiftsByOneWhenALaterCatalogThemeIsPinned() {
        let allNames = BattyThemeCatalog.allThemes.map(\.name)
        #expect(allNames.count > 5)
        let active = allNames[2]
        let pinnedLater = allNames[5]

        let baseline = themeCursorIndex(activeThemeName: active, pinnedIDs: [])
        let withLaterPinned = themeCursorIndex(activeThemeName: active, pinnedIDs: [pinnedLater])

        // Pinning a theme that originally sat *after* `active` moves it to
        // the front of the list, shifting `active`'s index up by exactly
        // one (the newly-inserted pinned entry).
        #expect(baseline == 2)
        #expect(withLaterPinned == baseline + 1)
    }

    @Test func cursorIndexUnchangedWhenAnEarlierCatalogThemeIsPinned() {
        let allNames = BattyThemeCatalog.allThemes.map(\.name)
        #expect(allNames.count > 5)
        let active = allNames[5]
        let pinnedEarlier = allNames[2]

        let baseline = themeCursorIndex(activeThemeName: active, pinnedIDs: [])
        let withEarlierPinned = themeCursorIndex(activeThemeName: active, pinnedIDs: [pinnedEarlier])

        // Pinning a theme that already sat *before* `active` only moves it
        // within the segment ahead of `active` — `active`'s own index is
        // unaffected.
        #expect(baseline == 5)
        #expect(withEarlierPinned == baseline)
    }
}

/// The selectors' inits read the committed Theme from the store's
/// preferences and never run the migration (a `UserDefaults` write that
/// `@AppStorage` observers watch) during view construction.
@MainActor
struct ThemeSelectorInitPurityTests {
    private let testDefaults = TestDefaults()
    private let theme: GhosttyThemeDefinition

    init() {
        let avoid = Set([ThemePreference.activeTheme(isDark: true)?.name, ThemePreference.activeTheme(isDark: false)?.name].compactMap { $0 })
        theme = BattyThemeCatalog.allThemes.first { !avoid.contains($0.name) }!
    }

    private func makeStore() -> AppStateStore {
        let defaults = testDefaults.defaults
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-selector-init-\(UUID().uuidString)")
            .appendingPathComponent("session-name-cache.json")
        let cache = SessionNameCache(fileURL: cacheURL, debounce: .zero, homeDirectory: "/Users/test")
        let store = AppStateStore(nameCache: cache, preferences: defaults)
        defaults.set(theme.name, forKey: ThemePreference.darkDefaultsKey)
        defaults.set(theme.name, forKey: ThemePreference.lightDefaultsKey)
        defaults.removeObject(forKey: ThemePreference.migrationDoneKey)
        return store
    }

    @Test func themeSelectorInitReadsTheStoreDefaultsWithoutMigrating() {
        let store = makeStore()
        let view = ThemeSelectorView(isPresented: .constant(true), store: store)
        #expect(view.activeThemeName == theme.name)
        #expect(testDefaults.defaults.object(forKey: ThemePreference.migrationDoneKey) == nil)
    }

    @Test func sessionThemeSelectorInitReadsTheStoreDefaultsWithoutMigrating() throws {
        let store = makeStore()
        let session = try #require(store.sessions.first)
        session.themeOverride = nil
        let view = SessionThemeSelectorView(isPresented: .constant(true), store: store, session: session)
        #expect(view.activeThemeName == theme.name)
        #expect(testDefaults.defaults.object(forKey: ThemePreference.migrationDoneKey) == nil)
    }

    /// The selector marks whatever the global writer just committed: both
    /// resolve the appearance slot the same way, so a commit to the current
    /// appearance's slot is the Theme the next selector init outlines.
    @Test func themeSelectorMarksTheThemeTheGlobalWriterJustCommitted() throws {
        let store = makeStore()
        let committed = try #require(BattyThemeCatalog.allThemes.first { $0.name != theme.name })
        store.setGlobalTheme(named: committed.name)
        let view = ThemeSelectorView(isPresented: .constant(true), store: store)
        #expect(view.activeThemeName == committed.name)
    }
}
