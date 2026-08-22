// RunningAppChecker.swift

import AppKit
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "RunningAppChecker")

/// Whether a process for a *specific app bundle* is currently running,
/// independent of whether it has registered itself with the broker (#0361).
/// The CLI's connect dance uses this to tell "no app running, safe to
/// launch" apart from "the app is running but hasn't registered" —
/// launching in the second case would spawn a duplicate process alongside
/// the one already running.
///
/// Matches on the resolved bundle **path**, not the bundle **identifier**
/// (#0361 round 2): `NSRunningApplication.runningApplications(withBundleIdentifier:)`
/// finds every process claiming a given identifier, and on the reporting
/// machine eight different `.app` bundles claimed `co.sstools.Batty` at
/// once (DerivedData debug builds, stale DMG mounts, the installed app).
/// Filtering `NSWorkspace.shared.runningApplications` by `bundleURL`
/// instead answers "is *this exact* app bundle running", which is the
/// question that actually matters here.
///
/// Wraps `NSWorkspace`/`NSRunningApplication` behind a plain function so
/// `AppConnectDance.resolveEndpoint` can inject a fake for tests rather than
/// depending on a real running process.
nonisolated enum RunningAppChecker {
    static func isRunning(atBundleURL bundleURL: URL) -> Bool {
        let target = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let running = NSWorkspace.shared.runningApplications.contains { app in
            guard let appURL = app.bundleURL else { return false }
            return appURL.resolvingSymlinksInPath().standardizedFileURL == target
        }
        logger.info("isRunning(atBundleURL: \(bundleURL.path, privacy: .public)) -> \(running, privacy: .public)")
        return running
    }
}
