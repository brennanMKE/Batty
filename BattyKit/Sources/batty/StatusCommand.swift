// StatusCommand.swift

import ArgumentParser
import BattyXPCCore
import Foundation

/// `batty status` — the first XPC verb that returns real app state and a
/// real exit code, closing the gap `docs/batty-cli-install.md`
/// §"Known limitations" records for the `batty://` URL scheme: a
/// `batty /valid/dir` reaching a running-but-broken Batty still exits `0`
/// there, because success only means LaunchServices accepted the URL.
struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report live state (pid, uptime, windows, sessions) from a running Batty."
    )

    /// #0384: unlike the other `--json` verbs, this one must also cover
    /// every failure branch below — `status`'s whole job is diagnosing a
    /// wedged or unreachable broker/app, so a script asking for JSON must
    /// never see empty stdout on exactly the paths it cares about most.
    @Flag(name: .long, help: "Emit JSON instead of a plain-text summary. Reports failure states as JSON too, so a script never sees empty stdout.")
    var json = false

    nonisolated func run() throws {
        switch AppConnectDance.resolveEndpoint() {
        case .failure(.brokerUnreachable):
            try fail(state: "brokerUnreachable", exitCode: XPCExitCode.brokerUnreachable, message: "batty: broker unreachable")
        case .failure(.appUnavailable):
            try fail(state: "appUnavailable", exitCode: XPCExitCode.appUnavailable, message: "batty: app unavailable")
        case .failure(.appRunningUnregistered):
            try fail(state: "appRunningUnregistered", exitCode: XPCExitCode.appRunningUnregistered, message: "batty: Batty is running but isn't responding to the broker — try relaunching it")
        case .failure(.appBundleUnresolved(let message)):
            try fail(state: "appBundleUnresolved", exitCode: XPCExitCode.appBundleUnresolved, message: "batty: \(message)")
        case .success(let endpoint):
            switch AppServiceClient.status(endpoint: endpoint, timeout: 3.0) {
            case .success(let payload):
                if json {
                    guard let text = Self.encodeJSON(.ok(payload)) else {
                        fputs("batty: failed to encode status as JSON\n", stderr)
                        throw ExitCode.failure
                    }
                    print(text)
                } else {
                    // #0361: `path=`/`version=` is the diagnostic this issue
                    // was missing entirely — which on-disk app bundle actually
                    // answered, straight from that process's own `Bundle.main`,
                    // not a CLI-side guess.
                    print("batty: pid \(payload.pid) uptime \(Self.formatUptime(payload.uptimeSeconds))s windows \(payload.windowCount) sessions \(payload.sessionCount) tabs \(payload.tabCount) path=\(payload.bundlePath) version=\(payload.appVersion)")
                }
            case .unreachable:
                try fail(state: "appUnavailable", exitCode: XPCExitCode.appUnavailable, message: "batty: app unavailable")
            case .requestFailed(let message):
                try fail(state: "requestFailed", exitCode: XPCExitCode.requestFailed, message: "batty: request failed — \(message)")
            case .appTerminated:
                try fail(state: "sessionTerminated", exitCode: XPCExitCode.sessionTerminated, message: "batty: app terminated")
            }
        }
    }

    /// Always writes the prose line to stderr (unchanged from before
    /// `--json` existed) and, when `--json` was requested, a machine-
    /// readable `StatusJSONPayload` to stdout whose `state`/`exitCode`
    /// name the exact failure the process is about to exit with — never a
    /// generic `ExitCode.failure` that would disagree with the JSON.
    private func fail(state: String, exitCode: Int32, message: String) throws -> Never {
        fputs(message + "\n", stderr)
        if json {
            if let text = Self.encodeJSON(.failure(state: state, exitCode: exitCode, message: message)) {
                print(text)
            } else {
                fputs("batty: failed to encode status as JSON\n", stderr)
            }
        }
        throw ExitCode(exitCode)
    }

    private static func encodeJSON(_ payload: StatusJSONPayload) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func formatUptime(_ seconds: Double) -> String {
        String(format: "%.1f", seconds)
    }
}

extension StatusCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON instead of a plain-text summary. Reports failure states as JSON too, so a script never sees empty stdout.", required: false, defaultValue: "false"),
        ])
    }
}
