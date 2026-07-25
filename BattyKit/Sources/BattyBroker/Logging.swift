// Logging.swift

import Foundation

// Duplicated (not imported) from `BattyKit/Sources/BattyKit/Util/Logging.swift`:
// the broker links only the dependency-free `BattyXPCCore` (#0252's @rpath
// constraint applies to it exactly as to the `batty` CLI), so it cannot
// import full `BattyKit`. The value is the same shared-subsystem string
// either way — for a bare Mach-O outside any bundle of its own,
// `Bundle.main.bundleIdentifier` resolves to `nil`, so this falls back to
// the same literal `BattyKit.Logging` falls back to.
nonisolated enum Logging {
    static let subsystem = Bundle.main.bundleIdentifier ?? "co.sstools.Batty"
}
