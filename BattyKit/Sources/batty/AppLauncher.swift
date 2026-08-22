// AppLauncher.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppLauncher")

/// Launches Batty by an explicit, already-resolved bundle **path**, step 3
/// of the CLI's connect dance (`docs/xpc/xpc-cli-architecture.md`
/// "Launching the app on demand") — what makes `batty status` work as the
/// first thing a user types after a reboot, with the app not running.
///
/// #0361 round 2: this used to launch by bundle **identifier**
/// (`open -b <bundle-id>`), which asks LaunchServices to pick *some* bundle
/// claiming that identifier — and the reporting machine had eight, most of
/// them stale DerivedData debug builds. `open <path>` (no `-b`) launches
/// exactly the bundle at that path, with no LaunchServices arbitration at
/// all. `AppBundleLocator` is what resolves the path deterministically
/// before this is ever called.
nonisolated enum AppLauncher {
    /// `-g` keeps the launch from stealing focus — a status check
    /// shouldn't raise a window the user didn't ask to see.
    @discardableResult
    static func launch(bundleURL: URL) -> Bool {
        let path = bundleURL.path(percentEncoded: false)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-g", path]
        do {
            try process.run()
            process.waitUntilExit()
            let succeeded = process.terminationStatus == 0
            logger.info("launch \(path, privacy: .public) -> \(succeeded ? "ok" : "exit \(process.terminationStatus)", privacy: .public)")
            return succeeded
        } catch {
            logger.error("launch \(path, privacy: .public) -> failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
