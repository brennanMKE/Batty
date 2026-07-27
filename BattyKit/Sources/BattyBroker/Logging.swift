// Logging.swift

import BattyXPCCore
import Foundation

// Duplicated (not imported) from `BattyKit/Sources/BattyKit/Util/Logging.swift`:
// the broker links only the dependency-free `BattyXPCCore` (#0252's @rpath
// constraint applies to it exactly as to the `batty` CLI), so it cannot
// import full `BattyKit`. The value is the same either way — for a bare
// Mach-O outside any bundle of its own, `Bundle.main.bundleIdentifier`
// resolves to `nil`, so this falls back to the same value
// `BattyKit.Logging` falls back to.
//
// #0279: the fallback used to be the Prod literal unconditionally, so the
// Beta broker logged under Prod's subsystem regardless of which variant
// launchd started. `ServiceNames.current` is baked at compile time via
// `-Xswiftc -DBATTY_VARIANT_BETA` (the "Embed Broker" build phase), so this
// fallback is variant-correct now.
nonisolated enum Logging {
    static let subsystem = Bundle.main.bundleIdentifier ?? ServiceNames.appBundleIdentifier
}
