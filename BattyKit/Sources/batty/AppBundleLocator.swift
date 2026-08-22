// AppBundleLocator.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppBundleLocator")

/// The filesystem/process-shelling glue around `AppBundleResolution` (#0361):
/// resolves the CLI's own executable path (following symlinks), derives the
/// pure decision, and — only for the `.wellKnownApplicationsFallback` case —
/// confirms the guessed path actually exists before the caller trusts it.
///
/// Never mutates the LaunchServices database (no `lsregister -kill`/`-r`):
/// pruning stale registrations is the user's call, not this CLI's.
nonisolated enum AppBundleLocator {
    enum Failure: Error, Equatable {
        /// Neither the embedded/symlinked case nor the well-known
        /// `/Applications` fallback resolved to a real bundle on disk.
        /// `otherClaimants` is a best-effort, read-only `mdfind` query (not
        /// authoritative, never longer than a few seconds) listing other
        /// bundles Spotlight knows claim the same identifier — exactly the
        /// #0361 symptom, surfaced to the user instead of guessed past.
        case expectedBundleMissing(expectedPath: String, otherClaimants: [String])

        var diagnosticMessage: String {
            switch self {
            case .expectedBundleMissing(let expectedPath, let otherClaimants):
                var message = "no app bundle found at the expected install location (\(expectedPath)), and this copy of the CLI isn't embedded in (or symlinked into) any app bundle either"
                if !otherClaimants.isEmpty {
                    message += " — other bundles on this Mac claim the same identifier: \(otherClaimants.joined(separator: ", "))"
                }
                message += ". Reinstall the CLI from Batty's Settings, or run the copy embedded in the app you want to control."
                return message
            }
        }
    }

    /// Resolves the one app bundle this CLI invocation should target.
    /// `ownExecutablePath` defaults to `CommandLine.arguments[0]` — read at
    /// each call so a fake path can be injected in tests without touching
    /// the process's real argv.
    static func resolve(
        ownExecutablePath: String = CommandLine.arguments[0],
        variant: ServiceNames.Variant = ServiceNames.current,
        fileManager: FileManager = .default,
        findOtherClaimants: (String) -> [String] = { mdfindClaimants(bundleIdentifier: $0) }
    ) -> Swift.Result<URL, Failure> {
        let resolvedOwnPath = realPath(of: ownExecutablePath, fileManager: fileManager)
        let resolution = AppBundleResolution.resolve(resolvedOwnExecutablePath: resolvedOwnPath, variant: variant)
        switch resolution {
        case .derivedFromOwnLocation(let bundlePath):
            logger.info("resolve: derived \(bundlePath, privacy: .public) from this CLI's own location (\(resolvedOwnPath, privacy: .public))")
            return .success(URL(fileURLWithPath: bundlePath, isDirectory: true))
        case .wellKnownApplicationsFallback(let bundlePath):
            guard fileManager.fileExists(atPath: bundlePath) else {
                let claimants = findOtherClaimants(ServiceNames.appBundleIdentifier(for: variant)).filter { $0 != bundlePath }
                logger.error("resolve: expected bundle missing at \(bundlePath, privacy: .public); other claimants: \(claimants, privacy: .public)")
                return .failure(.expectedBundleMissing(expectedPath: bundlePath, otherClaimants: claimants))
            }
            logger.info("resolve: this CLI copy (\(resolvedOwnPath, privacy: .public)) isn't embedded in a bundle — falling back to \(bundlePath, privacy: .public)")
            return .success(URL(fileURLWithPath: bundlePath, isDirectory: true))
        }
    }

    private static func realPath(of path: String, fileManager: FileManager) -> String {
        let absolute = path.hasPrefix("/") ? path : fileManager.currentDirectoryPath + "/" + path
        return URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path
    }

    /// Best-effort, read-only Spotlight query — never `lsregister`, never a
    /// mutation. Bounded to `timeout` so a slow/wedged `mdfind` can't hang
    /// the one error path that calls this.
    private static func mdfindClaimants(bundleIdentifier: String, timeout: TimeInterval = 2.0) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemCFBundleIdentifier == '\(bundleIdentifier)'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.notice("mdfindClaimants: failed to launch mdfind: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
