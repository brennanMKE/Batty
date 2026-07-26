// CLIInstaller.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "CLIInstaller")

nonisolated struct CLIInstaller {
    enum State: Equatable, Sendable {
        case notInstalled
        case installedHere
        case installedElsewhere(String)
        case blockedByFile
    }

    let installPath: String
    private let bundleURL: URL
    private let fileManager: FileManager

    init(
        installPath: String = Self.resolvedInstallPath(),
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) {
        self.installPath = installPath
        self.bundleURL = bundleURL
        self.fileManager = fileManager
    }

    /// The command name this installer symlinks to (the last path
    /// component of `installPath`) — `batty` for Prod, `batty-beta` for
    /// Beta. Exposed so UI copy (`SettingsView`) can name the actual
    /// command instead of hardcoding `batty` for both variants (#0277).
    var commandName: String {
        (installPath as NSString).lastPathComponent
    }

    /// This app's own install path, derived from
    /// `Bundle.main.bundleIdentifier` — see #0277 "The single-batty-on-PATH
    /// problem". Falls back to Prod's path (logged) for a bundle
    /// identifier that matches neither known variant.
    static func resolvedInstallPath(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        guard let variant = ServiceNames.Variant(bundleIdentifier: bundleIdentifier) else {
            logger.error("resolvedInstallPath: bundle identifier \(bundleIdentifier ?? "<nil>", privacy: .public) does not match any known Batty variant — defaulting to Prod's install path")
            return ServiceNames.Variant.prod.cliInstallPath
        }
        return variant.cliInstallPath
    }

    var bundledCLIPath: String? {
        bundleURL
            .appending(path: "Contents/Resources/bin/batty", directoryHint: .notDirectory)
            .path(percentEncoded: false)
    }

    /// Gates the *source* bundle (the app the symlink would point into), not the
    /// destination. A build launched straight from Xcode lives under `/DerivedData/`
    /// or `/Build/Products/`; installing a symlink into it breaks on the next clean
    /// build and surfaces much later as `command not found`. A quarantined app run
    /// straight from `~/Downloads` without first being dragged to `/Applications`
    /// is equally ephemeral: Gatekeeper app translocation runs it from a read-only,
    /// randomized `.../AppTranslocation/<uuid>/d/Batty.app` mount that disappears on
    /// the next relaunch or reboot.
    var isBundleDurable: Bool {
        let path = bundleURL.path(percentEncoded: false)
        return !path.contains("/DerivedData/")
            && !path.contains("/Build/Products/")
            && !path.contains("/AppTranslocation/")
    }

    private var isBundleTranslocated: Bool {
        bundleURL.path(percentEncoded: false).contains("/AppTranslocation/")
    }

    func inspectInstallState() -> State {
        Self.inspect(installPath: installPath, expecting: bundledCLIPath, fileManager: fileManager)
    }

    /// `attributesOfItem(atPath:)` does NOT follow symlinks, which is what makes it
    /// usable for telling a link apart from a real file. `fileExists(atPath:)` DOES
    /// follow, so it reports false for a dangling link -- exactly the state left
    /// behind when the target app is deleted -- and that would read as "nothing
    /// installed" while a broken command still sat on PATH.
    static func inspect(installPath: String, expecting target: String?, fileManager: FileManager) -> State {
        guard let attributes = try? fileManager.attributesOfItem(atPath: installPath) else {
            return .notInstalled
        }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            return .blockedByFile
        }
        guard let resolved = try? fileManager.destinationOfSymbolicLink(atPath: installPath) else {
            return .notInstalled
        }
        guard let target, resolved == target else {
            return .installedElsewhere(resolved)
        }
        return .installedHere
    }

    func install() throws {
        guard let bundledPath = bundledCLIPath, fileManager.fileExists(atPath: bundledPath) else {
            throw CLIInstallerError.bundledBinaryNotFound
        }
        guard isBundleDurable else {
            let path = bundleURL.path(percentEncoded: false)
            throw isBundleTranslocated
                ? CLIInstallerError.bundleTranslocated(path)
                : CLIInstallerError.bundleNotDurable(path)
        }
        // Detected before the privileged command runs: a plain file at the
        // destination must never be clobbered by `rm -f`, auth dialog or not.
        guard inspectInstallState() != .blockedByFile else {
            throw CLIInstallerError.blockedByFile(installPath)
        }

        let dir = shellEscape(
            URL(filePath: installPath).deletingLastPathComponent().path(percentEncoded: false)
        )
        let dst = shellEscape(installPath)
        let src = shellEscape(bundledPath)
        // Self-heal for a stale symlink (installedElsewhere) is intentional here:
        // rm -f only ever removes what inspectInstallState() already confirmed is a
        // symlink, never the plain-file case guarded above.
        try runPrivileged(
            "mkdir -p \(dir) && rm -f \(dst) && ln -s \(src) \(dst)",
            prompt: "Batty needs administrator access to install the CLI to /usr/local/bin."
        )
    }

    func uninstall() throws {
        let state = inspectInstallState()
        guard state != .notInstalled else { return }
        guard state != .blockedByFile else {
            throw CLIInstallerError.blockedByFile(installPath)
        }
        try runPrivileged(
            "rm -f \(shellEscape(installPath))",
            prompt: "Batty needs administrator access to uninstall the CLI from /usr/local/bin."
        )
    }

    // NSAppleScript must run on the main thread; callers are @MainActor.
    private func runPrivileged(_ command: String, prompt: String) throws {
        let cmd = command.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
        let p = prompt.replacing("\"", with: "\\\"")
        let source = "do shell script \"\(cmd)\" with prompt \"\(p)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            throw CLIInstallerError.installFailed("Failed to prepare authorization script.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else {
            if (errorInfo?[NSAppleScript.errorNumber] as? Int) == -128 {
                throw CLIInstallerError.cancelled
            }
            let message = errorInfo?[NSAppleScript.errorMessage] as? String ?? ""
            throw CLIInstallerError.installFailed(message)
        }
    }
}

private nonisolated func shellEscape(_ value: String) -> String {
    "'" + value.replacing("'", with: "'\\''") + "'"
}

public enum CLIInstallerError: Error, LocalizedError, Equatable, Sendable {
    case bundledBinaryNotFound
    case bundleNotDurable(String)
    case bundleTranslocated(String)
    case blockedByFile(String)
    case cancelled
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bundledBinaryNotFound:
            "The CLI binary was not found in the app bundle."
        case .bundleNotDurable(let path):
            "Batty is running from a build folder (\(path)). Move Batty.app to /Applications, then try installing again."
        case .bundleTranslocated(let path):
            "Batty is running from a temporary location (\(path)) because it was launched without first being moved to /Applications. Drag Batty.app to /Applications, then relaunch Batty before trying to install the CLI — a translocated copy stays temporary until relaunched from its new location."
        case .blockedByFile(let path):
            "\(path) already exists and isn't a symlink Batty created. Remove it manually, then try installing again."
        case .cancelled:
            nil
        case .installFailed(let reason):
            reason.isEmpty ? "Installation failed." : reason
        }
    }
}
