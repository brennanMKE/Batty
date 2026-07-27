// Logging.swift

import Foundation

// Duplicated (not imported) from `BattyKit/Sources/BattyKit/Util/Logging.swift`,
// `BattyKit/Sources/BattyBroker/Logging.swift`, and
// `BattyKit/Sources/batty/Logging.swift`: this target is linked by all three
// processes (app, broker, CLI) and stays dependency-free (#0252's @rpath
// constraint), so it can't import full `BattyKit` to reuse its copy. Same
// fallback reasoning as the other three — `Bundle.main.bundleIdentifier`
// resolves to `nil` for a bare Mach-O with no adjacent `Info.plist`.
//
// #0279: the fallback used to be the Prod literal unconditionally, so the
// broker and CLI (both bare Mach-Os) logged under Prod's subsystem
// regardless of which variant shipped them, contaminating the `log stream`
// predicate #0272 depends on. `ServiceNames.current` is baked at compile
// time via `-Xswiftc -DBATTY_VARIANT_BETA` (see `ServiceNames.swift`), so
// this fallback is variant-correct for exactly the two processes that need
// it — no change for the app, which always has a real `Bundle.main`.
public nonisolated enum Logging {
    /// Pulled out of `subsystem` as an injectable pure function so #0279's
    /// per-variant fallback is directly testable — `subsystem` itself stays
    /// a `static let` for the common case (every call site just reads it).
    public static func resolvedSubsystem(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        bundleIdentifier ?? ServiceNames.appBundleIdentifier
    }

    public static let subsystem = resolvedSubsystem()
}
