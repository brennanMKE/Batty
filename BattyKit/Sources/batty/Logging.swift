// Logging.swift

import Foundation

// Duplicated (not imported) from `BattyKit/Sources/BattyKit/Util/Logging.swift`
// and `BattyKit/Sources/BattyBroker/Logging.swift`: the `batty` executable
// links only the dependency-free `BattyCLICore`/`BattyXPCCore` (#0252's
// @rpath constraint), so it cannot import full `BattyKit`. Same fallback
// reasoning as the broker's copy — `Bundle.main.bundleIdentifier` resolves
// to `nil` for a bare Mach-O with no adjacent `Info.plist`, so this falls
// back to the same literal `BattyKit.Logging` falls back to. Wiring this in
// from #0271's first commit is what makes `log stream` usable to watch the
// CLI's half of the handoff, not just the app's.
nonisolated enum Logging {
    static let subsystem = Bundle.main.bundleIdentifier ?? "co.sstools.Batty"
}
