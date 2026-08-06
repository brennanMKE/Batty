// BattyThemes.swift

import GhosttyTheme

// Batty-original themes, exclusive to this app. These are ordinary
// `GhosttyThemeDefinition` values constructed on Batty's side of the
// package boundary — the type's memberwise init is public, so no fork
// dependency is needed to add a theme (#0310).
//
// Source design: the eight preview pages under issues/0310/ (Batty issue
// #0310) — hackers-themes.html (4 pairs) plus blade-runner.html,
// max-headroom.html, nostromo.html, swordfish.html, tron.html,
// weird-science.html, and wopr.html (1 pair each), 11 collections / 22
// entries total. Each dark theme ships a light companion so Batty's
// per-appearance theme slots (ThemePreference.darkDefaultsKey /
// lightDefaultsKey) never fall back to TokyoNight Day when a user sets
// one of these as their global theme. The companion is usually named
// `<Name> Day`, but not always — `weird-science.html` inverts the
// convention: the light variant is the primary form and is named plain
// "Weird Science", while its dark companion is "Weird Science Night".
// Don't assume the `Day` suffix when reading or testing this file. One pair
// also diverges from its HTML source's name: tron.html calls its pair
// "Encom" / "Encom Day", but it ships here as "Tron" / "Tron Day" — see the
// MARK comment above that pair for why. Preserve authored names unless they
// collide; don't "fix" this rename back to match the HTML.
//
// Adding a theme here is not enough on its own — it also has to be
// added to `BattyThemeCatalog.battyThemes` or it will silently never
// reach `BattyThemeCatalog.allThemes`.

public extension GhosttyThemeDefinition {
    // MARK: - Hackers (issues/0310/hackers-themes.html)

    static let hackers = GhosttyThemeDefinition(
        name: "Hackers",
        background: "140a2e",
        foreground: "d6dcea",
        cursorColor: "ff2fb9",
        cursorText: "140a2e",
        selectionBackground: "3a1163",
        selectionForeground: "ffffff",
        palette: [0: "1c1038", 1: "ff2b5e", 2: "a8f52c", 3: "f0e800", 4: "5b6bff", 5: "ff2fb9", 6: "35d6ff", 7: "d6dcea", 8: "6a5590", 9: "ff6b8a", 10: "c8ff5e", 11: "fff23d", 12: "8a95ff", 13: "ff7ad4", 14: "7ce8ff", 15: "ffffff"]
    )

    static let hackersDay = GhosttyThemeDefinition(
        name: "Hackers Day",
        background: "f2edfb",
        foreground: "4a2b7a",
        cursorColor: "c2008a",
        cursorText: "f2edfb",
        selectionBackground: "d3bdf2",
        selectionForeground: "2a1746",
        palette: [0: "e9e2f6", 1: "d10f4e", 2: "4f7a1c", 3: "8a6a00", 4: "2f46c9", 5: "c2008a", 6: "00718f", 7: "6b5a94", 8: "a99cc4", 9: "d10f4e", 10: "4f7a1c", 11: "8a6a00", 12: "2f46c9", 13: "c2008a", 14: "00718f", 15: "4a2b7a"]
    )

    static let hackersBlue = GhosttyThemeDefinition(
        name: "Hackers Blue",
        background: "07101f",
        foreground: "a8cbe6",
        cursorColor: "4fd3ff",
        cursorText: "07101f",
        selectionBackground: "143c5e",
        selectionForeground: "dff0ff",
        palette: [0: "0d1728", 1: "f2637f", 2: "3fd6b0", 3: "d6bd6a", 4: "3d7fe0", 5: "9a8cf0", 6: "35b8e8", 7: "a8cbe6", 8: "3c5372", 9: "ff8ba3", 10: "6ff0cf", 11: "ecd88f", 12: "6fa6f2", 13: "bfaeff", 14: "72dcff", 15: "e4f3ff"]
    )

    static let hackersBlueDay = GhosttyThemeDefinition(
        name: "Hackers Blue Day",
        background: "eaf1f8",
        foreground: "1d4a70",
        cursorColor: "0f7fb5",
        cursorText: "eaf1f8",
        selectionBackground: "bcd6ec",
        selectionForeground: "10334f",
        palette: [0: "e0eaf4", 1: "c23a5c", 2: "1f7f68", 3: "8a6a1f", 4: "1f5fa8", 5: "6a4fc0", 6: "0f7395", 7: "4a6a88", 8: "9db6cd", 9: "c23a5c", 10: "1f7f68", 11: "8a6a1f", 12: "1f5fa8", 13: "6a4fc0", 14: "0f7395", 15: "1d4a70"]
    )

    static let acidBurn = GhosttyThemeDefinition(
        name: "Acid Burn",
        background: "130a1c",
        foreground: "c9f24a",
        cursorColor: "ff2fb9",
        cursorText: "130a1c",
        selectionBackground: "45114a",
        selectionForeground: "f4ffd9",
        palette: [0: "1e1226", 1: "ff3b6b", 2: "8ef03c", 3: "ffe600", 4: "7a5cff", 5: "ff2fb9", 6: "2fe3d0", 7: "d8f5a8", 8: "705e7f", 9: "ff6f92", 10: "b6ff5c", 11: "fff45c", 12: "a08cff", 13: "ff7ad4", 14: "6cf2e4", 15: "f4ffd9"]
    )

    static let acidBurnDay = GhosttyThemeDefinition(
        name: "Acid Burn Day",
        background: "f7fbe8",
        foreground: "6b0a4f",
        cursorColor: "c2008a",
        cursorText: "f7fbe8",
        selectionBackground: "e6d3ee",
        selectionForeground: "3d0530",
        palette: [0: "eef4d8", 1: "c41347", 2: "4c7a10", 3: "806a00", 4: "5a3fc0", 5: "b3007f", 6: "0d7d70", 7: "6d6a4a", 8: "b3b48f", 9: "c41347", 10: "4c7a10", 11: "806a00", 12: "5a3fc0", 13: "b3007f", 14: "0d7d70", 15: "6b0a4f"]
    )

    static let theGibson = GhosttyThemeDefinition(
        name: "The Gibson",
        background: "000306",
        foreground: "7fdfff",
        cursorColor: "00ffe0",
        cursorText: "000306",
        selectionBackground: "07364a",
        selectionForeground: "e8feff",
        palette: [0: "001014", 1: "ff3b6b", 2: "00e39b", 3: "d8e04a", 4: "2f7fff", 5: "d36bff", 6: "00d5ff", 7: "9fd8e8", 8: "2a4b5c", 9: "ff6b93", 10: "4dffc4", 11: "f0f27a", 12: "6fa8ff", 13: "e79bff", 14: "6fe8ff", 15: "e8feff"]
    )

    static let theGibsonDay = GhosttyThemeDefinition(
        name: "The Gibson Day",
        background: "f2f9fc",
        foreground: "07414f",
        cursorColor: "008c9e",
        cursorText: "f2f9fc",
        selectionBackground: "bfe0ea",
        selectionForeground: "042d38",
        palette: [0: "e6f2f7", 1: "c02352", 2: "00755c", 3: "7a6a10", 4: "1f5fc0", 5: "8a3fb0", 6: "00707f", 7: "4a6f7a", 8: "9fbcc6", 9: "c02352", 10: "00755c", 11: "7a6a10", 12: "1f5fc0", 13: "8a3fb0", 14: "00707f", 15: "07414f"]
    )

    // MARK: - Blade Runner (issues/0310/blade-runner.html)

    static let bladeRunner = GhosttyThemeDefinition(
        name: "Blade Runner",
        background: "0b1416",
        foreground: "d9c7a3",
        cursorColor: "ffa62b",
        cursorText: "0b1416",
        selectionBackground: "1c3a3d",
        selectionForeground: "f4ead6",
        palette: [0: "121e21", 1: "e0533c", 2: "4fae8f", 3: "ffa62b", 4: "3f8fa8", 5: "c06a9e", 6: "5fc4c8", 7: "d9c7a3", 8: "47605f", 9: "ff7a5c", 10: "78d4b3", 11: "ffc46b", 12: "6fb4c9", 13: "e08fc0", 14: "8ee0e2", 15: "f4ead6"]
    )

    static let bladeRunnerDay = GhosttyThemeDefinition(
        name: "Blade Runner Day",
        background: "f5f0e6",
        foreground: "2e3b3d",
        cursorColor: "8a5a00",
        cursorText: "f5f0e6",
        selectionBackground: "d9d0bd",
        selectionForeground: "1c2527",
        palette: [0: "ebe4d6", 1: "b53c22", 2: "0f7a5c", 3: "8a5a00", 4: "1f6a86", 5: "9a3f78", 6: "0f6b70", 7: "5e6b6a", 8: "b8b3a4", 9: "b53c22", 10: "0f7a5c", 11: "8a5a00", 12: "1f6a86", 13: "9a3f78", 14: "0f6b70", 15: "2e3b3d"]
    )

    // MARK: - Max Headroom (issues/0310/max-headroom.html)

    static let maxHeadroom = GhosttyThemeDefinition(
        name: "Max Headroom",
        background: "1226c4",
        foreground: "ffe95c",
        cursorColor: "ff3ce0",
        cursorText: "1226c4",
        selectionBackground: "4a1fd6",
        selectionForeground: "ffffff",
        palette: [0: "0d1c8f", 1: "ff4b6e", 2: "4dffb0", 3: "ffe95c", 4: "62a0ff", 5: "ff3ce0", 6: "35e8ff", 7: "f2f0d8", 8: "5a6ae0", 9: "ff7f96", 10: "86ffcb", 11: "fff28f", 12: "9ac0ff", 13: "ff7aeb", 14: "84f2ff", 15: "ffffff"]
    )

    static let maxHeadroomDay = GhosttyThemeDefinition(
        name: "Max Headroom Day",
        background: "f2f4ff",
        foreground: "1a1f8f",
        cursorColor: "bf00a0",
        cursorText: "f2f4ff",
        selectionBackground: "c9d0ff",
        selectionForeground: "0d1150",
        palette: [0: "e4e8ff", 1: "c8103f", 2: "0a7a5a", 3: "8a6a00", 4: "1f3fc0", 5: "bf00a0", 6: "0a6f96", 7: "4a52a8", 8: "a8b0e0", 9: "c8103f", 10: "0a7a5a", 11: "8a6a00", 12: "1f3fc0", 13: "bf00a0", 14: "0a6f96", 15: "1a1f8f"]
    )

    // MARK: - Nostromo / MU-TH-UR (issues/0310/nostromo.html)

    static let muthur = GhosttyThemeDefinition(
        name: "MU-TH-UR",
        background: "0d0800",
        foreground: "ffb000",
        cursorColor: "ffc233",
        cursorText: "0d0800",
        selectionBackground: "3d2600",
        selectionForeground: "fff0d0",
        palette: [0: "1a1000", 1: "ff5f1f", 2: "d99000", 3: "ffc233", 4: "b87400", 5: "e8901f", 6: "ffd166", 7: "ffb000", 8: "5c3a00", 9: "ff7a3d", 10: "ffb833", 11: "ffd98a", 12: "d99a2b", 13: "ffab5c", 14: "ffe0a3", 15: "fff0d0"]
    )

    static let muthurDay = GhosttyThemeDefinition(
        name: "MU-TH-UR Day",
        background: "fbf2df",
        foreground: "4a2c00",
        cursorColor: "8a5a00",
        cursorText: "fbf2df",
        selectionBackground: "e8d5a8",
        selectionForeground: "331e00",
        palette: [0: "f2e8cf", 1: "b03000", 2: "6b5200", 3: "8a5a00", 4: "7a4a00", 5: "9a4400", 6: "6b4a00", 7: "7a6440", 8: "cbb98f", 9: "b03000", 10: "6b5200", 11: "8a5a00", 12: "7a4a00", 13: "9a4400", 14: "6b4a00", 15: "4a2c00"]
    )

    // MARK: - Swordfish (issues/0310/swordfish.html)

    static let swordfish = GhosttyThemeDefinition(
        name: "Swordfish",
        background: "10151c",
        foreground: "d8c08a",
        cursorColor: "e8a33d",
        cursorText: "10151c",
        selectionBackground: "2b3644",
        selectionForeground: "efe3c6",
        palette: [0: "1a212b", 1: "e05a3c", 2: "6fbf8f", 3: "e8a33d", 4: "4f86c6", 5: "b06f9e", 6: "5fb8c0", 7: "d8c08a", 8: "44505f", 9: "ff7d5c", 10: "93d8ad", 11: "f2bd66", 12: "74a6dc", 13: "cc93bb", 14: "86d4da", 15: "efe3c6"]
    )

    static let swordfishDay = GhosttyThemeDefinition(
        name: "Swordfish Day",
        background: "f2f1ec",
        foreground: "2b3440",
        cursorColor: "9a6400",
        cursorText: "f2f1ec",
        selectionBackground: "d6d8d2",
        selectionForeground: "1a2029",
        palette: [0: "e8e7e0", 1: "b0432a", 2: "1f7a5c", 3: "8a5f00", 4: "1f5f96", 5: "8a4470", 6: "0f6b78", 7: "5a6470", 8: "b4b8b0", 9: "b0432a", 10: "1f7a5c", 11: "8a5f00", 12: "1f5f96", 13: "8a4470", 14: "0f6b78", 15: "2b3440"]
    )

    // MARK: - Tron (issues/0310/tron.html)
    //
    // Named "Encom" in the source HTML; renamed to "Tron" / "Tron Day"
    // (#0310, 2026-08-05) because upstream ships "ENCOM" (Themes_E.swift, a
    // genuine Tron reference, different palette) and the two names differ
    // only by case — `theme(named:)` and the merge's dedup are both
    // case-sensitive, so the pair would otherwise coexist as confusingly
    // similar, differently-colored entries in the Theme menu. Verified
    // "Tron" / "TRON" / "Encom Grid" / "Grid" / "Flynn" are all free
    // upstream before choosing "Tron". Palette values are unchanged from
    // the HTML source — this is a name-only rename. Contrast with "Weird
    // Science" / "Weird Science Night" below, which IS preserved exactly as
    // authored: the rule is "preserve authored names unless they collide,"
    // not "normalize."

    static let tron = GhosttyThemeDefinition(
        name: "Tron",
        background: "000c11",
        foreground: "9fe7f5",
        cursorColor: "6fc3df",
        cursorText: "000c11",
        selectionBackground: "0a3a4a",
        selectionForeground: "dff6ff",
        palette: [0: "03151c", 1: "ff5a3c", 2: "27d1a0", 3: "ffae00", 4: "2f8fd6", 5: "b06cff", 6: "6fc3df", 7: "9fe7f5", 8: "2b5566", 9: "ff7a5c", 10: "4fe8bd", 11: "ffc63d", 12: "5fb0ea", 13: "c78dff", 14: "a8ecff", 15: "eafcff"]
    )

    static let tronDay = GhosttyThemeDefinition(
        name: "Tron Day",
        background: "eef7fa",
        foreground: "0d3a48",
        cursorColor: "0d6f88",
        cursorText: "eef7fa",
        selectionBackground: "bfe0ea",
        selectionForeground: "072a35",
        palette: [0: "e2eef3", 1: "c1441f", 2: "0f7a60", 3: "9a6a00", 4: "1a6ba8", 5: "7a3fc0", 6: "0d6f88", 7: "456a78", 8: "9ab8c4", 9: "c1441f", 10: "0f7a60", 11: "9a6a00", 12: "1a6ba8", 13: "7a3fc0", 14: "0d6f88", 15: "0d3a48"]
    )

    // MARK: - Weird Science (issues/0310/weird-science.html)
    //
    // Inverted naming convention: the LIGHT variant is the primary form
    // and is named plain "Weird Science"; its dark companion is "Weird
    // Science Night", not "Weird Science Day".

    static let weirdScienceNight = GhosttyThemeDefinition(
        name: "Weird Science Night",
        background: "1d0f2b",
        foreground: "ffd6f2",
        cursorColor: "ff4d9e",
        cursorText: "1d0f2b",
        selectionBackground: "4a1f5c",
        selectionForeground: "fff0fa",
        palette: [0: "2a1740", 1: "ff4d9e", 2: "52e6b8", 3: "ffd166", 4: "6f8cff", 5: "d46bff", 6: "4fe0ff", 7: "ffd6f2", 8: "6b4a80", 9: "ff7ab8", 10: "86f5d3", 11: "ffe29a", 12: "9db0ff", 13: "e79bff", 14: "8aeaff", 15: "fff0fa"]
    )

    static let weirdScience = GhosttyThemeDefinition(
        name: "Weird Science",
        background: "fdf2f8",
        foreground: "5a2a6b",
        cursorColor: "d4145a",
        cursorText: "fdf2f8",
        selectionBackground: "f3cfe4",
        selectionForeground: "3a1548",
        palette: [0: "f6e6f0", 1: "d4145a", 2: "1f8a6d", 3: "9a6b00", 4: "2f5fd0", 5: "a11fa1", 6: "0a7f9e", 7: "7a5a8a", 8: "c9a8d4", 9: "d4145a", 10: "1f8a6d", 11: "9a6b00", 12: "2f5fd0", 13: "a11fa1", 14: "0a7f9e", 15: "5a2a6b"]
    )

    // MARK: - WarGames / WOPR (issues/0310/wopr.html)

    static let wopr = GhosttyThemeDefinition(
        name: "WOPR",
        background: "000000",
        foreground: "bfe9f2",
        cursorColor: "ff2b2b",
        cursorText: "000000",
        selectionBackground: "13343d",
        selectionForeground: "eafbff",
        palette: [0: "000000", 1: "ff2b2b", 2: "8fdcea", 3: "d8f4fa", 4: "6fc3d6", 5: "a9dfe8", 6: "9fdcea", 7: "cfeef5", 8: "3a5a63", 9: "ff5c5c", 10: "b4e9f4", 11: "eafbff", 12: "8fd6e6", 13: "c4ecf3", 14: "bfe9f2", 15: "ffffff"]
    )

    static let woprDay = GhosttyThemeDefinition(
        name: "WOPR Day",
        background: "eef6f8",
        foreground: "0a3a44",
        cursorColor: "c01818",
        cursorText: "eef6f8",
        selectionBackground: "c2dde4",
        selectionForeground: "062b33",
        palette: [0: "e2eef1", 1: "c01818", 2: "2d6b78", 3: "14505c", 4: "3a7d8a", 5: "24606d", 6: "1a5762", 7: "4a6f78", 8: "a3c2ca", 9: "c01818", 10: "2d6b78", 11: "14505c", 12: "3a7d8a", 13: "24606d", 14: "1a5762", 15: "0a3a44"]
    )
}
