// AppLauncher.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppLauncher")

/// Launches the Batty app by bundle identifier, step 3 of the CLI's connect
/// dance (`docs/xpc/xpc-cli-architecture.md` "Launching the app on demand")
/// — what makes `batty status` work as the first thing a user types after a
/// reboot, with the app not running.
nonisolated enum AppLauncher {
    /// `-g` keeps the launch from stealing focus — a status check
    /// shouldn't raise a window the user didn't ask to see.
    @discardableResult
    static func launch(bundleIdentifier: String = ServiceNames.appBundleIdentifier) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-b", bundleIdentifier, "-g"]
        do {
            try process.run()
            process.waitUntilExit()
            let succeeded = process.terminationStatus == 0
            logger.info("launch \(bundleIdentifier, privacy: .public) -> \(succeeded ? "ok" : "exit \(process.terminationStatus)", privacy: .public)")
            return succeeded
        } catch {
            logger.error("launch \(bundleIdentifier, privacy: .public) -> failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
