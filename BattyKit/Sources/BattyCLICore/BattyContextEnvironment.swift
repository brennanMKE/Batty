// BattyContextEnvironment.swift

import Foundation

/// The `BATTY_*` environment variables Batty injects into every surface at
/// spawn (#0281), so every child process in the pane — the shell, `batty`
/// itself, an agent like Claude Code — inherits them.
///
/// `nonisolated` at the type level: under this package's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, an unannotated type's
/// synthesized conformances (and its static members) are themselves
/// main-actor-isolated, which fails to compile from `batty`'s `nonisolated
/// func run()` command bodies (`ArgumentParser`'s own requirement). Same
/// discipline as `BattyXPCCore`'s payload types.
public nonisolated enum BattyContextEnvironmentKey: String, Sendable, CaseIterable {
    case sessionID = "BATTY_SESSION_ID"
    case paneID = "BATTY_PANE_ID"
    case tabID = "BATTY_TAB_ID"
}

/// Foundation-only environment lookup shared by ``BattyIdentityContext``
/// (`batty id`) and ``BattyTargetResolver`` (the explicit-flag → env →
/// focused-element chain). No XPC, no app round-trip.
public nonisolated enum BattyContextEnvironment {
    /// Distinguishes "not set" from "set but not a UUID" — callers need
    /// both cases, and they treat them differently (`BattyIdentityContext`
    /// errors on either; `BattyTargetResolver` treats a malformed env value
    /// as absent — see its doc for why).
    public enum LookupResult: Equatable, Sendable {
        case absent
        case malformed(String)
        case value(UUID)
    }

    /// Reads and parses one `BATTY_*` variable from `environment`, which
    /// defaults to the real process environment. Tests should always pass
    /// an explicit fixture dictionary so the absent/malformed paths are
    /// hermetic rather than depending on the test runner's own env.
    public static func lookup(
        _ key: BattyContextEnvironmentKey,
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LookupResult {
        guard let raw = environment[key.rawValue], !raw.isEmpty else { return .absent }
        guard let uuid = UUID(uuidString: raw) else { return .malformed(raw) }
        return .value(uuid)
    }
}
