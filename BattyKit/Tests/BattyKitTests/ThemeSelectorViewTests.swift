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
