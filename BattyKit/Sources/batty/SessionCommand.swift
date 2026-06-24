// SessionCommand.swift

import ArgumentParser
import BattyKit
import Foundation

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
nonisolated func openURL(_ url: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
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
