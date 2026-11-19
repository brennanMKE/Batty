// CommandWaitCLI.swift

import BattyXPCCore
import Foundation

/// `--wait`/`--timeout` on `pane split -c` and `tab new -c` (#0668).
nonisolated enum CommandWaitCLI {
    static let waitDescription = "Type the command into a shell and wait for it to finish, then report its exit status. Needs bash or zsh. Blocks up to --timeout; MCP callers should pass a timeout below their client's tool-call limit."
    static let timeoutDescription = "Seconds --wait waits, at most 86400. Defaults to 600. The command keeps running after a timeout."

    static func validationError(wait: Bool, timeout: Double?, command: String?) -> String? {
        let command = command.flatMap { $0.isEmpty ? nil : $0 }
        if let timeout {
            guard wait else { return "--timeout requires --wait" }
            if let error = WaitTimeout.validationError(timeout) { return "--timeout \(error)" }
        }
        guard wait else { return nil }
        guard let command else { return "--wait requires -c/--command" }
        if command.contains("\n") || command.contains("\r") {
            return "--wait needs a single-line command"
        }
        return nil
    }

    /// The CLI's exit status and stderr line for a wait outcome.
    static func exit(for result: CommandWaitResult?, exitCode: Int?, timeoutSeconds: Double) -> (status: Int32, message: String?) {
        let failed = XPCExitCode.requestFailed
        switch result {
        case nil:
            return (0, nil)
        case .exited:
            guard let exitCode else { return (failed, "command finished without an exit status") }
            return exitCode == 0 ? (0, nil) : (failed, "command exited \(exitCode)")
        case .timedOut:
            return (failed, "still running after \(format(timeoutSeconds)) seconds")
        case .shellNotReady:
            return (failed, "not started after \(format(timeoutSeconds)) seconds: the shell has not reported ready (shell integration missing?)")
        case .notStarted:
            return (failed, "the command was not run")
        case .tabClosed:
            return (failed, "the tab closed before the command finished")
        }
    }

    static func clientTimeout(wait: Bool, timeout: Double?) -> TimeInterval {
        wait ? (timeout ?? CommandWaitDefaults.timeoutSeconds) + 10 : 3.0
    }

    static func waitProperties() -> [String: CapabilitiesPropertyPayload] {
        [
            "wait": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--wait"], type: "boolean", description: waitDescription, required: false, defaultValue: "false"),
            "timeout": CapabilitiesPropertyPayload(cliKind: .option, names: ["--timeout"], type: "number", description: timeoutDescription, required: false, defaultValue: "600", maximum: Int(WaitTimeout.maximumSeconds)),
        ]
    }

    static let waitConflicts: [CapabilitiesConstraintPayload] = [
        .requires(parameter: "wait", requiresParameter: "command", allowedValues: nil, allowsOmission: false, description: "--wait requires -c/--command"),
        .requires(parameter: "timeout", requiresParameter: "wait", allowedValues: ["true"], allowsOmission: false, description: "--timeout requires --wait"),
    ]

    private static func format(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}
