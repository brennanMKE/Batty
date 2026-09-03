// CapabilitiesPayload.swift

import Foundation

/// The `batty capabilities [--json]` wire shape (#0384): a static,
/// compiled-in description of this CLI build's verb roster and exit-code
/// vocabulary. Never crosses XPC — the CLI and the app ship in the same
/// bundle, so the CLI already knows its own surface without asking the app,
/// and this must succeed even when Batty is not running at all.
public nonisolated struct CapabilitiesVerbPayload: Codable, Sendable, Equatable {
    public let name: String
    public let abstract: String
    public let aliases: [String]

    public init(name: String, abstract: String, aliases: [String]) {
        self.name = name
        self.abstract = abstract
        self.aliases = aliases
    }
}

public nonisolated struct CapabilitiesExitCodePayload: Codable, Sendable, Equatable {
    public let code: Int32
    public let meaning: String

    public init(code: Int32, meaning: String) {
        self.code = code
        self.meaning = meaning
    }
}

public nonisolated struct CapabilitiesPayload: Codable, Sendable, Equatable {
    public let cliVersion: String
    public let verbs: [CapabilitiesVerbPayload]
    public let exitCodes: [CapabilitiesExitCodePayload]

    public init(cliVersion: String, verbs: [CapabilitiesVerbPayload], exitCodes: [CapabilitiesExitCodePayload]) {
        self.cliVersion = cliVersion
        self.verbs = verbs
        self.exitCodes = exitCodes
    }

    /// The exit-code vocabulary in numeric order: `ArgumentParser`'s own
    /// `0`/`1`/`64` (success, CLI-side failure, invalid syntax — see
    /// `XPCExitCode.swift`'s doc comment) plus every code `XPCExitCode`
    /// itself defines. `BattyXPCCore` must not depend on `ArgumentParser`
    /// (same discipline as `XPCExitCode`), so the three framework codes are
    /// passed in by the caller (`ExitCode.success/.failure
    /// /.validationFailure.rawValue`) rather than hardcoded here — this
    /// stays the single place the *numbers* are assembled, so
    /// `docs/batty-cli-agent-workflows.md`'s failure table (#0368) and this
    /// verb read the same vocabulary and cannot drift apart silently.
    public static func standardExitCodes(success: Int32, failure: Int32, validationFailure: Int32) -> [CapabilitiesExitCodePayload] {
        [
            CapabilitiesExitCodePayload(code: success, meaning: "Success."),
            CapabilitiesExitCodePayload(code: failure, meaning: "CLI-side failure — invalid path, malformed id, or a bad option combination."),
            CapabilitiesExitCodePayload(code: XPCExitCode.brokerUnreachable, meaning: "Broker unreachable — agent not registered, or awaiting SMAppService approval."),
            CapabilitiesExitCodePayload(code: XPCExitCode.appUnavailable, meaning: "Broker answered but no app endpoint was registered, and the app could not be started."),
            CapabilitiesExitCodePayload(code: XPCExitCode.requestFailed, meaning: "Delivered to the app, which replied with a failure."),
            CapabilitiesExitCodePayload(code: XPCExitCode.sessionTerminated, meaning: "The app terminated while the request was in flight."),
            CapabilitiesExitCodePayload(code: XPCExitCode.appRunningUnregistered, meaning: "The app is running but not registered with the broker, and did not re-register within the poll bound."),
            CapabilitiesExitCodePayload(code: XPCExitCode.appBundleUnresolved, meaning: "Could not determine, deterministically, which on-disk app bundle to target."),
            CapabilitiesExitCodePayload(code: validationFailure, meaning: "Invalid CLI syntax (ArgumentParser usage error)."),
        ].sorted { $0.code < $1.code }
    }
}
