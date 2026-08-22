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

    nonisolated func run() throws {
        switch AppConnectDance.resolveEndpoint() {
        case .failure(.brokerUnreachable):
            fputs("batty: broker unreachable\n", stderr)
            throw ExitCode(XPCExitCode.brokerUnreachable)
        case .failure(.appUnavailable):
            fputs("batty: app unavailable\n", stderr)
            throw ExitCode(XPCExitCode.appUnavailable)
        case .failure(.appRunningUnregistered):
            fputs("batty: Batty is running but isn't responding to the broker — try relaunching it\n", stderr)
            throw ExitCode(XPCExitCode.appRunningUnregistered)
        case .failure(.appBundleUnresolved(let message)):
            fputs("batty: \(message)\n", stderr)
            throw ExitCode(XPCExitCode.appBundleUnresolved)
        case .success(let endpoint):
            switch AppServiceClient.status(endpoint: endpoint, timeout: 3.0) {
            case .success(let payload):
                // #0361: `path=`/`version=` is the diagnostic this issue
                // was missing entirely — which on-disk app bundle actually
                // answered, straight from that process's own `Bundle.main`,
                // not a CLI-side guess.
                print("batty: pid \(payload.pid) uptime \(Self.formatUptime(payload.uptimeSeconds))s windows \(payload.windowCount) sessions \(payload.sessionCount) tabs \(payload.tabCount) path=\(payload.bundlePath) version=\(payload.appVersion)")
            case .unreachable:
                fputs("batty: app unavailable\n", stderr)
                throw ExitCode(XPCExitCode.appUnavailable)
            case .requestFailed(let message):
                fputs("batty: request failed — \(message)\n", stderr)
                throw ExitCode(XPCExitCode.requestFailed)
            case .appTerminated:
                fputs("batty: app terminated\n", stderr)
                throw ExitCode(XPCExitCode.sessionTerminated)
            }
        }
    }

    private static func formatUptime(_ seconds: Double) -> String {
        String(format: "%.1f", seconds)
    }
}
