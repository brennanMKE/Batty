// BattyThemeCatalog.swift

import GhosttyTheme

/// Batty's theme catalog facade: the upstream `GhosttyThemeCatalog.allThemes`
/// merged with Batty-original themes (`BattyThemes.swift`, #0310).
///
/// This exists entirely inside Batty — no fork, no `BattyKit/Package.swift`
/// change, no `Package.resolved` bump. `GhosttyThemeDefinition` has a public
/// memberwise init, so Batty-original themes are ordinary values constructed
/// on this side of the package boundary and merged in at call time.
///
/// Batty code should always read the catalog through here, never through
/// `GhosttyThemeCatalog` directly — otherwise Batty-original themes silently
/// disappear from whatever menu, picker, or lookup bypassed this facade.
public enum BattyThemeCatalog {
    /// Batty-original themes (#0310). Adding one here is the only step
    /// needed to make it reach `allThemes` — no fork, no package bump.
    static let battyThemes: [GhosttyThemeDefinition] = [
        .hackers, .hackersDay,
        .hackersBlue, .hackersBlueDay,
        .acidBurn, .acidBurnDay,
        .theGibson, .theGibsonDay,
        .bladeRunner, .bladeRunnerDay,
        .maxHeadroom, .maxHeadroomDay,
        .muthur, .muthurDay,
        .swordfish, .swordfishDay,
        .tron, .tronDay,
        .weirdScienceNight, .weirdScience,
        .wopr, .woprDay,
    ]

    /// Merges a Batty bucket with an upstream catalog, sorted
    /// case-insensitively by name.
    ///
    /// Collision policy: if a name appears in both, **Batty wins** — `batty`
    /// is deduplicated into the merge first, so a same-named upstream entry
    /// is dropped rather than the other way around. Factored out from
    /// `allThemes` so `BattyThemeCatalogTests` can exercise the policy
    /// directly with a synthetic collision, since no real collision exists
    /// in the current upstream catalog to test against.
    static func merge(
        batty: [GhosttyThemeDefinition],
        upstream: [GhosttyThemeDefinition]
    ) -> [GhosttyThemeDefinition] {
        var seen = Set<String>()
        var merged: [GhosttyThemeDefinition] = []
        for theme in batty + upstream where seen.insert(theme.name).inserted {
            merged.append(theme)
        }
        return merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Upstream catalog (~485 entries) merged with Batty-original themes,
    /// sorted case-insensitively by name so Batty themes take their
    /// alphabetical place instead of trailing the list.
    public static let allThemes: [GhosttyThemeDefinition] = merge(
        batty: battyThemes,
        upstream: GhosttyThemeCatalog.allThemes
    )

    /// Resolves a theme by name across both the Batty-original bucket and
    /// the upstream catalog.
    public static func theme(named name: String) -> GhosttyThemeDefinition? {
        allThemes.first { $0.name == name }
    }
}
