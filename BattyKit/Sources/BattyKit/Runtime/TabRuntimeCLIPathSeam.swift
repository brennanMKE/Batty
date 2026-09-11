// TabRuntimeCLIPathSeam.swift

import Foundation

/// The `batty` CLI's real location is `Contents/Resources/bin/batty` inside
/// the app bundle (see `CLIInstaller.bundledCLIPath`), but every pane
/// libghostty spawns inherits `Contents/MacOS` on `PATH` instead — libghostty
/// stamps `GHOSTTY_BIN_DIR` (its own executable directory) into the spawned
/// environment and appends it to `PATH`. On a case-insensitive APFS volume,
/// `Contents/MacOS/batty` collides with the app's own main executable
/// `Contents/MacOS/Batty`, so typing `batty` inside a Batty Pane can resolve
/// to a second app instance instead of the CLI (#0364).
///
/// `TabRuntime` overrides the spawned shell's `PATH` via libghostty's `env`
/// config directive to point at the real CLI directory instead, and strips
/// the app's own `Contents/MacOS` out of the inherited `PATH` so the
/// collision can't resurface even if something upstream re-adds it. This is
/// safe because `env` behaves as a single key/value map applied on top of
/// the rest of the spawned environment, not as an appended `PATH` segment —
/// confirmed against the pinned libghostty's actual source
/// (`src/termio/Exec.zig:819-827` at ref `c4e16970`, pin `a2565cc`, tag
/// `1.5.20260903`): `env_override` is applied last, after `GHOSTTY_BIN_DIR`'s
/// own bin-dir append, so a later `env = PATH=...` assignment replaces
/// whatever `PATH` libghostty already computed rather than merely adding to
/// it.
///
/// The CLI directory is **appended**, not prepended, to what's left after
/// stripping — review round 1 (#0364, N1) flagged that prepending would
/// undo #0277's deliberate decision to keep exactly one `/usr/local/bin`
/// symlink serving exactly one variant (`batty` → Prod, `batty-beta` →
/// Beta), since both variants embed a binary literally named `batty` at
/// `Contents/Resources/bin/batty` (`CLIInstaller.bundledCLIPath`) —
/// prepending Beta's own bundle directory would put a `batty` ahead of
/// `/usr/local/bin/batty` in every Beta pane, silently reintroducing the
/// cross-variant hazard #0277 killed, in any shell whose `PATH` isn't
/// rebuilt by `/etc/zprofile`'s `path_helper` (a non-login shell). Stripping
/// `Contents/MacOS` is what actually fixes #0364; appending still makes the
/// bundled CLI discoverable on a fresh install with no symlink at all,
/// without outranking a real install of either variant's symlink.
enum TabRuntimeCLIPathSeam {
    /// Builds the `PATH` value to inject into every spawned shell.
    ///
    /// - Parameters:
    ///   - basePath: the app process's own inherited `PATH` (typically
    ///     `ProcessInfo.processInfo.environment["PATH"]`) — this is
    ///     evaluated before libghostty appends `GHOSTTY_BIN_DIR`, so it
    ///     normally does not already contain the app's own directory.
    ///     `nil` or empty falls back to the standard macOS default path.
    ///   - bundlePath: the app bundle's own path (`Bundle.main.bundlePath`),
    ///     used to derive both the CLI's real directory
    ///     (`Contents/Resources/bin`) and the app's own directory
    ///     (`Contents/MacOS`) to strip defensively.
    static func injectedPath(basePath: String?, bundlePath: String) -> String {
        let fallback = "/usr/bin:/bin:/usr/sbin:/sbin"
        let cliDirectory = bundlePath + "/Contents/Resources/bin"
        let appBinDirectory = bundlePath + "/Contents/MacOS"
        let effectiveBase = (basePath?.isEmpty == false) ? basePath! : fallback

        var components = effectiveBase
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != appBinDirectory }

        if !components.contains(cliDirectory) {
            components.append(cliDirectory)
        }

        return components.joined(separator: ":")
    }
}
