// Logging.swift

import Foundation

// Duplicated (not imported) from `BattyKit/Sources/BattyKit/Util/Logging.swift`,
// `BattyKit/Sources/BattyBroker/Logging.swift`, and
// `BattyKit/Sources/batty/Logging.swift`: this target is linked by all three
// processes (app, broker, CLI) and stays dependency-free (#0252's @rpath
// constraint), so it can't import full `BattyKit` to reuse its copy. Same
// fallback reasoning as the other three — `Bundle.main.bundleIdentifier`
// resolves to `nil` for a bare Mach-O with no adjacent `Info.plist`.
public nonisolated enum Logging {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "co.sstools.Batty"
}
