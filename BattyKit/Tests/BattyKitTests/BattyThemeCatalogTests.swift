// BattyThemeCatalogTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers the Batty-original theme catalog (#0310): all 22 entries — 11
/// dark/light pairs (Hackers, Hackers Blue, Acid Burn, The Gibson, Blade
/// Runner, Max Headroom, MU-TH-UR, Swordfish, Tron, Weird Science, WOPR)
/// drawn from 8 preview-page files under `issues/0310/` — land in
/// `BattyThemeCatalog.allThemes`, sorted correctly among the ~485 upstream
/// entries, resolve by name, hold their palette values exactly as authored,
/// follow the light-companion slot convention, and can never silently lose
/// to (or silently overwrite) an upstream name collision.
///
/// The dark→light companion naming is **not** uniformly `<Name> Day`:
/// `weird-science.html` inverts it — the light variant is the primary form
/// named plain "Weird Science", and its dark companion is "Weird Science
/// Night". Tests here key off the actual authored pairing, not an assumed
/// suffix.
struct BattyThemeCatalogTests {

    // MARK: - Fixtures

    /// All 22 Batty-original theme names, in authored order — mirrors
    /// `BattyThemeCatalog.battyThemes`.
    private static let battyThemeNames = [
        "Hackers", "Hackers Day",
        "Hackers Blue", "Hackers Blue Day",
        "Acid Burn", "Acid Burn Day",
        "The Gibson", "The Gibson Day",
        "Blade Runner", "Blade Runner Day",
        "Max Headroom", "Max Headroom Day",
        "MU-TH-UR", "MU-TH-UR Day",
        "Swordfish", "Swordfish Day",
        "Tron", "Tron Day",
        "Weird Science Night", "Weird Science",
        "WOPR", "WOPR Day",
    ]

    /// Dark → light companion name pairs. Deliberately NOT derived by
    /// appending " Day" to the dark name — `weird-science.html` inverts the
    /// convention (dark = "Weird Science Night", light = plain "Weird
    /// Science"), so each pair is spelled out explicitly.
    private static let companionPairs: [(dark: String, light: String)] = [
        ("Hackers", "Hackers Day"),
        ("Hackers Blue", "Hackers Blue Day"),
        ("Acid Burn", "Acid Burn Day"),
        ("The Gibson", "The Gibson Day"),
        ("Blade Runner", "Blade Runner Day"),
        ("Max Headroom", "Max Headroom Day"),
        ("MU-TH-UR", "MU-TH-UR Day"),
        ("Swordfish", "Swordfish Day"),
        ("Tron", "Tron Day"),
        ("Weird Science Night", "Weird Science"),
        ("WOPR", "WOPR Day"),
    ]

    // MARK: - Presence

    @Test func allBattyThemesArePresentInMergedCatalog() {
        let names = Set(BattyThemeCatalog.allThemes.map(\.name))
        for name in Self.battyThemeNames {
            #expect(names.contains(name), "expected '\(name)' in BattyThemeCatalog.allThemes")
        }
    }

    @Test func battyThemesBucketHasExactlyTwentyTwoEntries() {
        // Pins the count so a silently-dropped or silently-duplicated entry
        // in BattyThemes.swift fails immediately, independent of the merge.
        #expect(BattyThemeCatalog.battyThemes.count == 22)
    }

    @Test func companionPairsCoverEveryBattyTheme() {
        // Every name in battyThemeNames must appear exactly once across the
        // companionPairs fixture (as either the dark or light side) — this
        // guards the fixture itself against drifting out of sync with
        // battyThemeNames as themes are added.
        let paired = Set(Self.companionPairs.flatMap { [$0.dark, $0.light] })
        #expect(paired == Set(Self.battyThemeNames))
        #expect(Self.companionPairs.count * 2 == Self.battyThemeNames.count)
    }

    @Test func themeNamedResolvesEveryBattyTheme() {
        for name in Self.battyThemeNames {
            #expect(BattyThemeCatalog.theme(named: name)?.name == name)
        }
    }

    @Test func themeNamedReturnsNilForUnknownName() {
        #expect(BattyThemeCatalog.theme(named: "Definitely Not A Theme Name") == nil)
    }

    // MARK: - Sort order

    @Test func mergedCatalogIsSortedCaseInsensitivelyByName() {
        let names = BattyThemeCatalog.allThemes.map(\.name)
        for (a, b) in zip(names, names.dropFirst()) {
            #expect(
                a.localizedCaseInsensitiveCompare(b) != .orderedDescending,
                "'\(a)' should not sort after '\(b)'"
            )
        }
    }

    @Test func eachBattyThemeSitsBetweenItsSortedNeighbours() {
        let all = BattyThemeCatalog.allThemes
        for name in Self.battyThemeNames {
            guard let index = all.firstIndex(where: { $0.name == name }) else {
                Issue.record("'\(name)' missing from allThemes")
                continue
            }
            if index > all.startIndex {
                let previous = all[all.index(before: index)]
                #expect(
                    previous.name.localizedCaseInsensitiveCompare(name) != .orderedDescending,
                    "'\(previous.name)' should not sort after '\(name)'"
                )
            }
            let next = all.index(after: index)
            if next < all.endIndex {
                #expect(
                    name.localizedCaseInsensitiveCompare(all[next].name) != .orderedDescending,
                    "'\(name)' should not sort after '\(all[next].name)'"
                )
            }
        }
    }

    // MARK: - No collision with the real upstream catalog

    @Test func noBattyThemeNameCollidesExactlyWithRealUpstreamCatalog() {
        let upstreamNames = Set(GhosttyThemeCatalog.allThemes.map(\.name))
        for name in Self.battyThemeNames {
            #expect(!upstreamNames.contains(name), "'\(name)' unexpectedly already exists upstream")
        }
    }

    /// General guard: NO Batty theme may collide with any upstream theme
    /// name, case-insensitively, across all 22. This is the durable
    /// replacement for a once-instance-specific check — Batty's "Encom" was
    /// found to collide case-insensitively with upstream's "ENCOM"
    /// (`Themes_E.swift`, a genuine Tron reference, different palette) and
    /// was renamed to "Tron" (#0310) rather than special-cased here, so this
    /// test can assert zero collisions rather than carrying an allowlist of
    /// known exceptions. Catches the next theme someone adds with a
    /// colliding name, instead of only pinning this one past instance.
    @Test func noBattyThemeNameCollidesCaseInsensitivelyWithRealUpstreamCatalog() {
        let upstreamByLowercasedName = Dictionary(
            GhosttyThemeCatalog.allThemes.map { ($0.name.lowercased(), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        for name in Self.battyThemeNames {
            let upstreamName = upstreamByLowercasedName[name.lowercased()]
            #expect(
                upstreamName == nil,
                "'\(name)' case-insensitively collides with upstream '\(upstreamName ?? "")'"
            )
        }
    }

    @Test func mergedCatalogHasNoDuplicateNames() {
        let names = BattyThemeCatalog.allThemes.map(\.name)
        #expect(names.count == Set(names).count)
    }

    // MARK: - Collision policy: Batty wins (tested against a synthetic collision)

    @Test func mergePolicyPrefersBattyOnNameCollision() {
        let realBatty = GhosttyThemeDefinition.hackers
        let fakeUpstreamHackers = GhosttyThemeDefinition(
            name: "Hackers",
            background: "ffffff",
            foreground: "000000"
        )
        let merged = BattyThemeCatalog.merge(batty: [realBatty], upstream: [fakeUpstreamHackers])
        let resolved = merged.first { $0.name == "Hackers" }
        #expect(resolved?.background == realBatty.background)
        #expect(merged.filter { $0.name == "Hackers" }.count == 1)
    }

    @Test func mergeDropsUpstreamDuplicateRatherThanBattyDuplicate() {
        let batty = GhosttyThemeDefinition.hackers
        let upstream = [
            GhosttyThemeDefinition(name: "Aardvark", background: "111111", foreground: "eeeeee"),
            GhosttyThemeDefinition(name: "Hackers", background: "222222", foreground: "dddddd"),
            GhosttyThemeDefinition(name: "Zorro", background: "333333", foreground: "cccccc"),
        ]
        let merged = BattyThemeCatalog.merge(batty: [batty], upstream: upstream)
        #expect(merged.count == 3)
        #expect(merged.first { $0.name == "Hackers" }?.background == "140a2e")
    }

    // MARK: - Palette values pinned to issues/0310/*.html

    @Test func hackersDarkMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.hackers
        #expect(t.background == "140a2e")
        #expect(t.foreground == "d6dcea")
        #expect(t.cursorColor == "ff2fb9")
        #expect(t.cursorText == "140a2e")
        #expect(t.selectionBackground == "3a1163")
        #expect(t.selectionForeground == "ffffff")
        #expect(t.palette == [
            0: "1c1038", 1: "ff2b5e", 2: "a8f52c", 3: "f0e800",
            4: "5b6bff", 5: "ff2fb9", 6: "35d6ff", 7: "d6dcea",
            8: "6a5590", 9: "ff6b8a", 10: "c8ff5e", 11: "fff23d",
            12: "8a95ff", 13: "ff7ad4", 14: "7ce8ff", 15: "ffffff",
        ])
    }

    @Test func hackersDayMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.hackersDay
        #expect(t.background == "f2edfb")
        #expect(t.foreground == "4a2b7a")
        #expect(t.cursorColor == "c2008a")
        #expect(t.cursorText == "f2edfb")
        #expect(t.selectionBackground == "d3bdf2")
        #expect(t.selectionForeground == "2a1746")
        #expect(t.palette == [
            0: "e9e2f6", 1: "d10f4e", 2: "4f7a1c", 3: "8a6a00",
            4: "2f46c9", 5: "c2008a", 6: "00718f", 7: "6b5a94",
            8: "a99cc4", 9: "d10f4e", 10: "4f7a1c", 11: "8a6a00",
            12: "2f46c9", 13: "c2008a", 14: "00718f", 15: "4a2b7a",
        ])
    }

    @Test func hackersBlueDarkMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.hackersBlue
        #expect(t.background == "07101f")
        #expect(t.foreground == "a8cbe6")
        #expect(t.cursorColor == "4fd3ff")
        #expect(t.cursorText == "07101f")
        #expect(t.selectionBackground == "143c5e")
        #expect(t.selectionForeground == "dff0ff")
        #expect(t.palette == [
            0: "0d1728", 1: "f2637f", 2: "3fd6b0", 3: "d6bd6a",
            4: "3d7fe0", 5: "9a8cf0", 6: "35b8e8", 7: "a8cbe6",
            8: "3c5372", 9: "ff8ba3", 10: "6ff0cf", 11: "ecd88f",
            12: "6fa6f2", 13: "bfaeff", 14: "72dcff", 15: "e4f3ff",
        ])
    }

    @Test func hackersBlueDayMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.hackersBlueDay
        #expect(t.background == "eaf1f8")
        #expect(t.foreground == "1d4a70")
        #expect(t.cursorColor == "0f7fb5")
        #expect(t.cursorText == "eaf1f8")
        #expect(t.selectionBackground == "bcd6ec")
        #expect(t.selectionForeground == "10334f")
        #expect(t.palette == [
            0: "e0eaf4", 1: "c23a5c", 2: "1f7f68", 3: "8a6a1f",
            4: "1f5fa8", 5: "6a4fc0", 6: "0f7395", 7: "4a6a88",
            8: "9db6cd", 9: "c23a5c", 10: "1f7f68", 11: "8a6a1f",
            12: "1f5fa8", 13: "6a4fc0", 14: "0f7395", 15: "1d4a70",
        ])
    }

    @Test func acidBurnDarkMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.acidBurn
        #expect(t.background == "130a1c")
        #expect(t.foreground == "c9f24a")
        #expect(t.cursorColor == "ff2fb9")
        #expect(t.cursorText == "130a1c")
        #expect(t.selectionBackground == "45114a")
        #expect(t.selectionForeground == "f4ffd9")
        #expect(t.palette == [
            0: "1e1226", 1: "ff3b6b", 2: "8ef03c", 3: "ffe600",
            4: "7a5cff", 5: "ff2fb9", 6: "2fe3d0", 7: "d8f5a8",
            8: "705e7f", 9: "ff6f92", 10: "b6ff5c", 11: "fff45c",
            12: "a08cff", 13: "ff7ad4", 14: "6cf2e4", 15: "f4ffd9",
        ])
    }

    @Test func acidBurnDayMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.acidBurnDay
        #expect(t.background == "f7fbe8")
        #expect(t.foreground == "6b0a4f")
        #expect(t.cursorColor == "c2008a")
        #expect(t.cursorText == "f7fbe8")
        #expect(t.selectionBackground == "e6d3ee")
        #expect(t.selectionForeground == "3d0530")
        #expect(t.palette == [
            0: "eef4d8", 1: "c41347", 2: "4c7a10", 3: "806a00",
            4: "5a3fc0", 5: "b3007f", 6: "0d7d70", 7: "6d6a4a",
            8: "b3b48f", 9: "c41347", 10: "4c7a10", 11: "806a00",
            12: "5a3fc0", 13: "b3007f", 14: "0d7d70", 15: "6b0a4f",
        ])
    }

    @Test func theGibsonDarkMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.theGibson
        #expect(t.background == "000306")
        #expect(t.foreground == "7fdfff")
        #expect(t.cursorColor == "00ffe0")
        #expect(t.cursorText == "000306")
        #expect(t.selectionBackground == "07364a")
        #expect(t.selectionForeground == "e8feff")
        #expect(t.palette == [
            0: "001014", 1: "ff3b6b", 2: "00e39b", 3: "d8e04a",
            4: "2f7fff", 5: "d36bff", 6: "00d5ff", 7: "9fd8e8",
            8: "2a4b5c", 9: "ff6b93", 10: "4dffc4", 11: "f0f27a",
            12: "6fa8ff", 13: "e79bff", 14: "6fe8ff", 15: "e8feff",
        ])
    }

    @Test func theGibsonDayMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.theGibsonDay
        #expect(t.background == "f2f9fc")
        #expect(t.foreground == "07414f")
        #expect(t.cursorColor == "008c9e")
        #expect(t.cursorText == "f2f9fc")
        #expect(t.selectionBackground == "bfe0ea")
        #expect(t.selectionForeground == "042d38")
        #expect(t.palette == [
            0: "e6f2f7", 1: "c02352", 2: "00755c", 3: "7a6a10",
            4: "1f5fc0", 5: "8a3fb0", 6: "00707f", 7: "4a6f7a",
            8: "9fbcc6", 9: "c02352", 10: "00755c", 11: "7a6a10",
            12: "1f5fc0", 13: "8a3fb0", 14: "00707f", 15: "07414f",
        ])
    }

    @Test func bladeRunnerMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.bladeRunner
        #expect(t.background == "0b1416")
        #expect(t.foreground == "d9c7a3")
        #expect(t.cursorColor == "ffa62b")
        #expect(t.cursorText == "0b1416")
        #expect(t.selectionBackground == "1c3a3d")
        #expect(t.selectionForeground == "f4ead6")
        #expect(t.palette == [0: "121e21", 1: "e0533c", 2: "4fae8f", 3: "ffa62b", 4: "3f8fa8", 5: "c06a9e", 6: "5fc4c8", 7: "d9c7a3", 8: "47605f", 9: "ff7a5c", 10: "78d4b3", 11: "ffc46b", 12: "6fb4c9", 13: "e08fc0", 14: "8ee0e2", 15: "f4ead6"])
    }

    @Test func bladeRunnerDayMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.bladeRunnerDay
        #expect(t.background == "f5f0e6")
        #expect(t.foreground == "2e3b3d")
        #expect(t.cursorColor == "8a5a00")
        #expect(t.cursorText == "f5f0e6")
        #expect(t.selectionBackground == "d9d0bd")
        #expect(t.selectionForeground == "1c2527")
        #expect(t.palette == [0: "ebe4d6", 1: "b53c22", 2: "0f7a5c", 3: "8a5a00", 4: "1f6a86", 5: "9a3f78", 6: "0f6b70", 7: "5e6b6a", 8: "b8b3a4", 9: "b53c22", 10: "0f7a5c", 11: "8a5a00", 12: "1f6a86", 13: "9a3f78", 14: "0f6b70", 15: "2e3b3d"])
    }

    @Test func maxHeadroomMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.maxHeadroom
        #expect(t.background == "1226c4")
        #expect(t.foreground == "ffe95c")
        #expect(t.cursorColor == "ff3ce0")
        #expect(t.cursorText == "1226c4")
        #expect(t.selectionBackground == "4a1fd6")
        #expect(t.selectionForeground == "ffffff")
        #expect(t.palette == [0: "0d1c8f", 1: "ff4b6e", 2: "4dffb0", 3: "ffe95c", 4: "62a0ff", 5: "ff3ce0", 6: "35e8ff", 7: "f2f0d8", 8: "5a6ae0", 9: "ff7f96", 10: "86ffcb", 11: "fff28f", 12: "9ac0ff", 13: "ff7aeb", 14: "84f2ff", 15: "ffffff"])
    }

    @Test func maxHeadroomDayMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.maxHeadroomDay
        #expect(t.background == "f2f4ff")
        #expect(t.foreground == "1a1f8f")
        #expect(t.cursorColor == "bf00a0")
        #expect(t.cursorText == "f2f4ff")
        #expect(t.selectionBackground == "c9d0ff")
        #expect(t.selectionForeground == "0d1150")
        #expect(t.palette == [0: "e4e8ff", 1: "c8103f", 2: "0a7a5a", 3: "8a6a00", 4: "1f3fc0", 5: "bf00a0", 6: "0a6f96", 7: "4a52a8", 8: "a8b0e0", 9: "c8103f", 10: "0a7a5a", 11: "8a6a00", 12: "1f3fc0", 13: "bf00a0", 14: "0a6f96", 15: "1a1f8f"])
    }

    @Test func muthurMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.muthur
        #expect(t.background == "0d0800")
        #expect(t.foreground == "ffb000")
        #expect(t.cursorColor == "ffc233")
        #expect(t.cursorText == "0d0800")
        #expect(t.selectionBackground == "3d2600")
        #expect(t.selectionForeground == "fff0d0")
        #expect(t.palette == [0: "1a1000", 1: "ff5f1f", 2: "d99000", 3: "ffc233", 4: "b87400", 5: "e8901f", 6: "ffd166", 7: "ffb000", 8: "5c3a00", 9: "ff7a3d", 10: "ffb833", 11: "ffd98a", 12: "d99a2b", 13: "ffab5c", 14: "ffe0a3", 15: "fff0d0"])
    }

    @Test func muthurDayMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.muthurDay
        #expect(t.background == "fbf2df")
        #expect(t.foreground == "4a2c00")
        #expect(t.cursorColor == "8a5a00")
        #expect(t.cursorText == "fbf2df")
        #expect(t.selectionBackground == "e8d5a8")
        #expect(t.selectionForeground == "331e00")
        #expect(t.palette == [0: "f2e8cf", 1: "b03000", 2: "6b5200", 3: "8a5a00", 4: "7a4a00", 5: "9a4400", 6: "6b4a00", 7: "7a6440", 8: "cbb98f", 9: "b03000", 10: "6b5200", 11: "8a5a00", 12: "7a4a00", 13: "9a4400", 14: "6b4a00", 15: "4a2c00"])
    }

    @Test func swordfishMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.swordfish
        #expect(t.background == "10151c")
        #expect(t.foreground == "d8c08a")
        #expect(t.cursorColor == "e8a33d")
        #expect(t.cursorText == "10151c")
        #expect(t.selectionBackground == "2b3644")
        #expect(t.selectionForeground == "efe3c6")
        #expect(t.palette == [0: "1a212b", 1: "e05a3c", 2: "6fbf8f", 3: "e8a33d", 4: "4f86c6", 5: "b06f9e", 6: "5fb8c0", 7: "d8c08a", 8: "44505f", 9: "ff7d5c", 10: "93d8ad", 11: "f2bd66", 12: "74a6dc", 13: "cc93bb", 14: "86d4da", 15: "efe3c6"])
    }

    @Test func swordfishDayMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.swordfishDay
        #expect(t.background == "f2f1ec")
        #expect(t.foreground == "2b3440")
        #expect(t.cursorColor == "9a6400")
        #expect(t.cursorText == "f2f1ec")
        #expect(t.selectionBackground == "d6d8d2")
        #expect(t.selectionForeground == "1a2029")
        #expect(t.palette == [0: "e8e7e0", 1: "b0432a", 2: "1f7a5c", 3: "8a5f00", 4: "1f5f96", 5: "8a4470", 6: "0f6b78", 7: "5a6470", 8: "b4b8b0", 9: "b0432a", 10: "1f7a5c", 11: "8a5f00", 12: "1f5f96", 13: "8a4470", 14: "0f6b78", 15: "2b3440"])
    }

    @Test func tronMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.tron
        #expect(t.background == "000c11")
        #expect(t.foreground == "9fe7f5")
        #expect(t.cursorColor == "6fc3df")
        #expect(t.cursorText == "000c11")
        #expect(t.selectionBackground == "0a3a4a")
        #expect(t.selectionForeground == "dff6ff")
        #expect(t.palette == [0: "03151c", 1: "ff5a3c", 2: "27d1a0", 3: "ffae00", 4: "2f8fd6", 5: "b06cff", 6: "6fc3df", 7: "9fe7f5", 8: "2b5566", 9: "ff7a5c", 10: "4fe8bd", 11: "ffc63d", 12: "5fb0ea", 13: "c78dff", 14: "a8ecff", 15: "eafcff"])
    }

    @Test func tronDayMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.tronDay
        #expect(t.background == "eef7fa")
        #expect(t.foreground == "0d3a48")
        #expect(t.cursorColor == "0d6f88")
        #expect(t.cursorText == "eef7fa")
        #expect(t.selectionBackground == "bfe0ea")
        #expect(t.selectionForeground == "072a35")
        #expect(t.palette == [0: "e2eef3", 1: "c1441f", 2: "0f7a60", 3: "9a6a00", 4: "1a6ba8", 5: "7a3fc0", 6: "0d6f88", 7: "456a78", 8: "9ab8c4", 9: "c1441f", 10: "0f7a60", 11: "9a6a00", 12: "1a6ba8", 13: "7a3fc0", 14: "0d6f88", 15: "0d3a48"])
    }

    @Test func weirdScienceNightMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.weirdScienceNight
        #expect(t.background == "1d0f2b")
        #expect(t.foreground == "ffd6f2")
        #expect(t.cursorColor == "ff4d9e")
        #expect(t.cursorText == "1d0f2b")
        #expect(t.selectionBackground == "4a1f5c")
        #expect(t.selectionForeground == "fff0fa")
        #expect(t.palette == [0: "2a1740", 1: "ff4d9e", 2: "52e6b8", 3: "ffd166", 4: "6f8cff", 5: "d46bff", 6: "4fe0ff", 7: "ffd6f2", 8: "6b4a80", 9: "ff7ab8", 10: "86f5d3", 11: "ffe29a", 12: "9db0ff", 13: "e79bff", 14: "8aeaff", 15: "fff0fa"])
    }

    @Test func weirdScienceMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.weirdScience
        #expect(t.background == "fdf2f8")
        #expect(t.foreground == "5a2a6b")
        #expect(t.cursorColor == "d4145a")
        #expect(t.cursorText == "fdf2f8")
        #expect(t.selectionBackground == "f3cfe4")
        #expect(t.selectionForeground == "3a1548")
        #expect(t.palette == [0: "f6e6f0", 1: "d4145a", 2: "1f8a6d", 3: "9a6b00", 4: "2f5fd0", 5: "a11fa1", 6: "0a7f9e", 7: "7a5a8a", 8: "c9a8d4", 9: "d4145a", 10: "1f8a6d", 11: "9a6b00", 12: "2f5fd0", 13: "a11fa1", 14: "0a7f9e", 15: "5a2a6b"])
    }

    @Test func woprMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.wopr
        #expect(t.background == "000000")
        #expect(t.foreground == "bfe9f2")
        #expect(t.cursorColor == "ff2b2b")
        #expect(t.cursorText == "000000")
        #expect(t.selectionBackground == "13343d")
        #expect(t.selectionForeground == "eafbff")
        #expect(t.palette == [0: "000000", 1: "ff2b2b", 2: "8fdcea", 3: "d8f4fa", 4: "6fc3d6", 5: "a9dfe8", 6: "9fdcea", 7: "cfeef5", 8: "3a5a63", 9: "ff5c5c", 10: "b4e9f4", 11: "eafbff", 12: "8fd6e6", 13: "c4ecf3", 14: "bfe9f2", 15: "ffffff"])
    }

    @Test func woprDayMatchesHTMLSource() {
        let t = GhosttyThemeDefinition.woprDay
        #expect(t.background == "eef6f8")
        #expect(t.foreground == "0a3a44")
        #expect(t.cursorColor == "c01818")
        #expect(t.cursorText == "eef6f8")
        #expect(t.selectionBackground == "c2dde4")
        #expect(t.selectionForeground == "062b33")
        #expect(t.palette == [0: "e2eef1", 1: "c01818", 2: "2d6b78", 3: "14505c", 4: "3a7d8a", 5: "24606d", 6: "1a5762", 7: "4a6f78", 8: "a3c2ca", 9: "c01818", 10: "2d6b78", 11: "14505c", 12: "3a7d8a", 13: "24606d", 14: "1a5762", 15: "0a3a44"])
    }

    // MARK: - Light-companion slot convention

    /// Slot 15 (bright white) must be byte-equal to `foreground` — the
    /// convention that the "brightest" slot is the ink itself on paper,
    /// not a lighter white.
    @Test func lightCompanionsUseForegroundAsSlot15() {
        for pair in Self.companionPairs {
            guard let light = BattyThemeCatalog.theme(named: pair.light) else {
                Issue.record("missing light companion for \(pair.dark)")
                continue
            }
            #expect(light.palette[15] == light.foreground, "\(pair.light): slot 15 should equal foreground")
        }
    }

    /// Slots 9–14 (the "bright" ANSI variants) must repeat slots 1–6 exactly
    /// rather than brightening, because a brighter accent on a light
    /// background is less legible and bold text would vanish.
    @Test func lightCompanionsRepeatBrightSlotsFromNormalSlots() {
        for pair in Self.companionPairs {
            guard let palette = BattyThemeCatalog.theme(named: pair.light)?.palette else {
                Issue.record("missing light companion for \(pair.dark)")
                continue
            }
            for base in 1...6 {
                #expect(
                    palette[base + 8] == palette[base],
                    "\(pair.light): slot \(base + 8) should repeat slot \(base)"
                )
            }
        }
    }

    /// The dark side of each pair must NOT follow the repeat convention —
    /// its bright slots are genuinely brighter, distinct colors. This is
    /// what stops the light-companion tests above from passing vacuously
    /// on both sides of a pair.
    @Test func darkThemesDoNotRepeatBrightSlotsFromNormalSlots() {
        for pair in Self.companionPairs {
            guard let palette = BattyThemeCatalog.theme(named: pair.dark)?.palette else {
                Issue.record("missing dark theme for \(pair.dark)")
                continue
            }
            let matches = (1...6).filter { palette[$0 + 8] == palette[$0] }
            #expect(matches.isEmpty, "\(pair.dark): expected bright slots to differ from normal slots, but \(matches) matched")
        }
    }

    // MARK: - WCAG contrast (acceptance criterion: foreground/background >= 4.5:1)

    @Test func allBattyThemesMeetWCAGContrastMinimum() {
        for name in Self.battyThemeNames {
            guard let theme = BattyThemeCatalog.theme(named: name) else {
                Issue.record("missing theme '\(name)'")
                continue
            }
            let ratio = Self.contrastRatio(theme.foreground, theme.background)
            #expect(ratio >= 4.5, "\(name): fg/bg contrast \(ratio) is below WCAG 4.5:1")
        }
    }

    // MARK: - WCAG luminance helpers (mirrors the contrast formula used by
    // the issues/0310/*.html preview pages)

    private static func srgb(_ channel: Double) -> Double {
        let v = channel / 255
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func luminance(_ hex: String) -> Double {
        guard let n = UInt32(hex, radix: 16) else { return 0 }
        let r = Double((n >> 16) & 0xFF)
        let g = Double((n >> 8) & 0xFF)
        let b = Double(n & 0xFF)
        return 0.2126 * srgb(r) + 0.7152 * srgb(g) + 0.0722 * srgb(b)
    }

    private static func contrastRatio(_ a: String, _ b: String) -> Double {
        let l1 = luminance(a)
        let l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
