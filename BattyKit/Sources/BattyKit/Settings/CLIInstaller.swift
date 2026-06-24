// CLIInstaller.swift

import Foundation

nonisolated struct CLIInstaller {
    private static let installPath = "/usr/local/bin/batty"

    static var bundledCLIPath: String? {
        Bundle.main.resourceURL?
            .appending(path: "bin/batty", directoryHint: .notDirectory)
            .path(percentEncoded: false)
    }

    func isInstalled() -> Bool {
        guard let bundledPath = Self.bundledCLIPath,
              let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: Self.installPath)
        else { return false }
        return dest == bundledPath
    }

    func install() throws {
        guard let bundledPath = Self.bundledCLIPath,
              FileManager.default.fileExists(atPath: bundledPath)
        else { throw CLIInstallerError.bundledBinaryNotFound }

        let dir = shellEscape(
            URL(filePath: Self.installPath)
                .deletingLastPathComponent()
                .path(percentEncoded: false)
        )
        let dst = shellEscape(Self.installPath)
        let src = shellEscape(bundledPath)
        try runPrivileged(
            "mkdir -p \(dir) && rm -f \(dst) && ln -s \(src) \(dst)",
            prompt: "Batty needs administrator access to install the CLI to /usr/local/bin."
        )
    }

    func uninstall() throws {
        guard isInstalled() else { return }
        try runPrivileged(
            "rm -f \(shellEscape(Self.installPath))",
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
    case cancelled
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bundledBinaryNotFound:
            "The CLI binary was not found in the app bundle."
        case .cancelled:
            nil
        case .installFailed(let reason):
            reason.isEmpty ? "Installation failed." : reason
        }
    }
}
