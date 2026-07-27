// SessionCommand.swift

import ArgumentParser
import BattyCLICore
import BattyXPCCore
import Foundation

// MARK: - Version

/// Resolves the version string for `batty --version`.
///
/// The installed CLI is a symlink into the app bundle at
/// `<App>.app/Contents/Resources/bin/batty`, so the app's `Info.plist` sits two
/// directories up at `Contents/Info.plist`. Reading `CFBundleShortVersionString`
/// from there keeps `batty --version` matched to the installed app with no
/// build-time stamping. Falls back to `"unknown"` when run outside a bundle
/// (e.g. straight from the SwiftPM build directory).
nonisolated func resolveAppVersion() -> String {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        return "unknown"
    }
    let infoPlist = executable
        .deletingLastPathComponent()  // bin/
        .deletingLastPathComponent()  // Resources/
        .deletingLastPathComponent()  // Contents/
        .appending(path: "Info.plist", directoryHint: .notDirectory)
    guard let data = try? Data(contentsOf: infoPlist),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let info = plist as? [String: Any],
          let version = info["CFBundleShortVersionString"] as? String
    else {
        return "unknown"
    }
    return version
}

// MARK: - Path resolution

/// Resolves a user-supplied path string into an absolute, standardized
/// directory path, validating that it exists and is a directory.
nonisolated func resolvePath(_ input: String) throws -> String {
    guard let resolved = SessionURLBuilder.resolve(path: input) else {
        fputs("batty: path does not exist or is not a directory: \(input)\n", stderr)
        throw ExitCode.failure
    }
    return resolved
}

// MARK: - URL dispatch

/// Opens the batty:// URL via `/usr/bin/open`, which activates and (if
/// needed) launches the Batty app and delivers the URL to its handler.
///
/// Targeted with `-b <bundleIdentifier>` — same precedent as
/// `AppLauncher.launch` — because both variants register the `batty`
/// scheme (`Configuration/Info.plist` is shared, #0279) and an untargeted
/// `open` lets LaunchServices pick either handler. Without `-b`, `batty
/// <path>` — the CLI's primary mutation verb — could silently land a
/// session in the wrong variant whenever both are installed.
nonisolated func openURL(_ url: URL, bundleIdentifier: String = ServiceNames.appBundleIdentifier) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/open")
    process.arguments = ["-b", bundleIdentifier, url.absoluteString]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fputs("batty: failed to open URL: \(error.localizedDescription)\n", stderr)
        throw ExitCode.failure
    }
    guard process.terminationStatus == 0 else {
        fputs("batty: open exited with status \(process.terminationStatus)\n", stderr)
        throw ExitCode.failure
    }
}
