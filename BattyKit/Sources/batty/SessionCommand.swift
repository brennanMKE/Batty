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
/// #0361 round 3 (review B1): this was the CLI's **default** subcommand
/// path (bare `batty` / `batty <path>` — `NewSessionCommand`, `BattyCLI`'s
/// `defaultSubcommand`) and, uniquely among the CLI's verbs, never went
/// through `AppConnectDance`/`AppBundleLocator` at all — it targeted
/// `open -b <bundleIdentifier>`, which asks LaunchServices to resolve the
/// identifier and, on a machine with several bundles claiming it (every
/// `./build.sh` run adds one), can resolve to any of them. That made
/// the most-typed invocation of the CLI exempt from every fix this issue
/// otherwise made to every other verb.
///
/// Now resolves the same way every other verb does — `AppBundleLocator
/// .resolve()` — and targets that resolved bundle by **path**: `open -a
/// <bundlePath> <url>`. `-a <path>` is strictly stronger than `-b
/// <bundleIdentifier>` for the reason `-b` was added in the first place
/// (#0279: keep the shared `batty://` scheme registration — both variants
/// register it, `Configuration/Info.plist` is shared — from resolving to
/// the wrong variant): a path names one exact bundle, so it can never
/// resolve to the other variant's, or to a stale/DerivedData one, the way
/// an unqualified `open <url>` or an ambiguous `-b <id>` can.
nonisolated func openURL(
    _ url: URL,
    resolveAppBundle: () -> Swift.Result<URL, AppBundleLocator.Failure> = { AppBundleLocator.resolve() },
    runProcess: (URL, [String]) throws -> Int32 = { executableURL, arguments in
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
) throws {
    let bundleURL: URL
    switch resolveAppBundle() {
    case .failure(let failure):
        fputs("batty: \(failure.diagnosticMessage)\n", stderr)
        throw ExitCode(XPCExitCode.appBundleUnresolved)
    case .success(let resolved):
        bundleURL = resolved
    }
    let terminationStatus: Int32
    do {
        terminationStatus = try runProcess(
            URL(filePath: "/usr/bin/open"),
            ["-a", bundleURL.path(percentEncoded: false), url.absoluteString]
        )
    } catch {
        fputs("batty: failed to open URL: \(error.localizedDescription)\n", stderr)
        throw ExitCode.failure
    }
    guard terminationStatus == 0 else {
        fputs("batty: open exited with status \(terminationStatus)\n", stderr)
        throw ExitCode.failure
    }
}
