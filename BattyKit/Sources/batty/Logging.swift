// Logging.swift

import BattyXPCCore
import Foundation

// Duplicated (not imported) from `BattyKit/Sources/BattyKit/Util/Logging.swift`
// and `BattyKit/Sources/BattyBroker/Logging.swift`: the `batty` executable
// links only the dependency-free `BattyCLICore`/`BattyXPCCore` (#0252's
// @rpath constraint), so it cannot import full `BattyKit`. Same fallback
// reasoning as the broker's copy — `Bundle.main.bundleIdentifier` resolves
// to `nil` for a bare Mach-O with no adjacent `Info.plist`, so this falls
// back to the same value `BattyKit.Logging` falls back to. Wiring this in
// from #0271's first commit is what makes `log stream` usable to watch the
// CLI's half of the handoff, not just the app's.
//
// #0279: the fallback used to be the Prod literal unconditionally, so
// `batty-beta` logged under Prod's subsystem regardless of which variant
// installed it. `ServiceNames.current` is baked at compile time via
// `-Xswiftc -DBATTY_VARIANT_BETA` (the "Embed CLI" build phase), so this
// fallback is variant-correct now.
nonisolated enum Logging {
    static let subsystem = Bundle.main.bundleIdentifier ?? ServiceNames.appBundleIdentifier
}
