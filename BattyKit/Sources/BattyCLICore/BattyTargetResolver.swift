// BattyTargetResolver.swift

import Foundation

/// The shared target-resolution chain (#0257 Foundation §2, built by
/// #0281): explicit flag → `BATTY_*` env → focused element. `nil` means "no
/// explicit target — let the app resolve the focused element"; this
/// CLI-side helper never talks to the app itself, so a flag/env hit or that
/// fallthrough are its only two outcomes. Consumed by `batty session info`
/// (retrofit) and, later, `batty pane split`/`batty pane close` (#0282/#0283).
///
/// `nonisolated` at the type level — see `BattyContextEnvironment`'s doc for
/// why; callers invoke `resolve(flag:environmentKey:)` from a `nonisolated
/// func run()`.
public nonisolated enum BattyTargetResolver {
    public enum ResolutionError: Error, Equatable {
        /// The explicit `--session`/`--pane`/`--tab` flag was not a UUID.
        case malformedFlag(String)
    }

    /// - Parameters:
    ///   - flag: The raw flag string, if the caller passed one.
    ///   - environmentKey: Which `BATTY_*` var backs this target when no
    ///     flag is given.
    ///   - environment: Defaults to the real process environment; tests
    ///     inject a fixture so precedence is hermetic.
    /// - Returns: The resolved id, or `nil` to fall through to the app's
    ///   focused-element resolution.
    ///
    /// A malformed **env** value does not error — it's treated the same as
    /// absent and falls through to focused-element resolution. `BATTY_*` is
    /// a hint carried from spawn time (#0257: "env is a hint, not truth"),
    /// not something the user typed this time, so a stale or corrupted
    /// value should degrade gracefully rather than block a command that
    /// never mentioned it. A malformed **flag** always errors — the user
    /// typed it this time, so silently falling through would act on the
    /// wrong target without telling them.
    public static func resolve(
        flag: String?,
        environmentKey: BattyContextEnvironmentKey,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<UUID?, ResolutionError> {
        if let flag {
            guard let parsed = UUID(uuidString: flag) else {
                return .failure(.malformedFlag(flag))
            }
            return .success(parsed)
        }

        if case let .value(uuid) = BattyContextEnvironment.lookup(environmentKey, in: environment) {
            return .success(uuid)
        }

        return .success(nil)
    }
}
