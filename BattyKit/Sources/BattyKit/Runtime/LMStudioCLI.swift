// LMStudioCLI.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "LMStudioCLI")

public nonisolated enum LMStudioHTTPError: Error, Sendable {
    case badStatus(Int)
}

/// HTTP access to LM Studio's REST API. `nonisolated` throughout — these
/// are plain, stateless network calls with no affinity to the main actor,
/// callable from a poll `Task` without hopping.
public nonisolated enum LMStudioHTTPClient {
    public static let defaultBaseURL = URL(string: "http://localhost:1234")!

    /// `GET /api/v1/models` — see `LMStudioModels.swift` for why this
    /// endpoint over `/api/v0/models` (design doc §1.6).
    nonisolated public static func fetchModels(
        baseURL: URL = defaultBaseURL,
        timeout: TimeInterval = 3
    ) async throws -> LMStudioModelsResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/models"))
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LMStudioHTTPError.badStatus(code)
        }
        return try JSONDecoder().decode(LMStudioModelsResponse.self, from: data)
    }
}

/// Locates and drives the `lms` CLI. `nonisolated` throughout so its
/// synchronous, potentially-blocking calls (`runPs`) can run inside a
/// detached `Task` off the main actor — `lms ps --json` measured
/// ~130-160 ms/call live (design doc §1.7), too slow to ever call directly
/// from a UI-affecting context.
public nonisolated enum LMStudioCLI {
    /// Checked in this order: the standard LM Studio CLI install location
    /// (confirmed live on this machine, `~/.lmstudio/bin/lms`), then the two
    /// common Homebrew prefixes. Not a `PATH` search — `Process` doesn't
    /// resolve `PATH` for `executableURL` the way a shell would, and this
    /// project's other CLI shell-outs (`AppLauncher.swift`) use an absolute
    /// path for the same reason.
    nonisolated public static func resolveExecutableURL(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = [
            homeDirectory + "/.lmstudio/bin/lms",
            "/usr/local/bin/lms",
            "/opt/homebrew/bin/lms",
        ]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Builds (but does not launch) an `lms log stream` subprocess.
    /// `--stats` is passed defensively even though the design doc §1.3
    /// found the `stats` block present without it on the installed build —
    /// it's the documented, stable way to *request* the block, and costs
    /// nothing.
    nonisolated public static func makeLogStreamProcess(
        executableURL: URL,
        source: String,
        includeStats: Bool
    ) -> Process {
        let process = Process()
        process.executableURL = executableURL
        var arguments = ["log", "stream", "--json", "-s", source]
        if includeStats {
            arguments.append("--stats")
        }
        process.arguments = arguments
        return process
    }

    /// Synchronous `lms ps --json` invocation. Callers must not call this
    /// directly from the main actor — see `runPsAsync`, which is the
    /// intended entry point for production use.
    nonisolated public static func runPs(executableURL: URL) throws -> [LMStudioPsEntry] {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["ps", "--json"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        // Review round 1, S3: an undrained stderr pipe blocks the child
        // once its stderr write buffer fills (>64 KB — a stack trace from
        // a drifted build is enough), and `waitUntilExit()` below then
        // never returns, wedging `psPollTask` permanently. This function
        // has no use for `lms ps --json`'s stderr, so routing it straight
        // to `/dev/null` avoids needing a second drain loop entirely.
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            logger.error("runPs: lms ps --json exited \(process.terminationStatus, privacy: .public)")
            throw LMStudioHTTPError.badStatus(Int(process.terminationStatus))
        }
        return try JSONDecoder().decode([LMStudioPsEntry].self, from: data)
    }

    /// Off-main wrapper around `runPs` — `Process.run()` +
    /// `waitUntilExit()` blocks the calling thread for the call's duration
    /// (~130-160 ms measured live, design doc §1.7), so this always hops to
    /// a detached `Task` rather than being called directly from the main
    /// actor.
    nonisolated public static func runPsAsync(executableURL: URL) async throws -> [LMStudioPsEntry] {
        try await Task.detached(priority: .utility) {
            try runPs(executableURL: executableURL)
        }.value
    }
}
