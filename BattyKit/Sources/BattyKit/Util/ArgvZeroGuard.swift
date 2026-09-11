// ArgvZeroGuard.swift

import Foundation

/// Backstop for #0364: refuses to let the app's own main binary act as the
/// `batty` CLI when it is reached by that name instead of the real,
/// resolved bundle path LaunchServices always launches with.
///
/// `TabRuntimeCLIPathSeam` closes the primary route (the `PATH` every Batty
/// Pane inherits), but this guard is the backstop for anything that reaches
/// the binary a different way — a shell that re-exports `PATH`, a stale
/// `/usr/local/bin/batty` pointed at the wrong place, or a script that hard
/// -codes `Contents/MacOS/batty`. On a case-insensitive APFS volume that
/// path names the same inode as the app's own executable
/// (`Contents/MacOS/Batty`), so without this guard, exec'ing it under the
/// name `batty` starts a brand-new `NSApplication` with no LaunchServices
/// involvement, no dedupe, and no CLI code path at all.
///
/// The check cannot be a plain "is argv[0]'s basename `batty`,
/// case-insensitively" test: the app's own `CFBundleExecutable` *is*
/// `Batty`, so a normal LaunchServices launch already satisfies that on its
/// own. The exemption also cannot be "does `argv0` equal
/// `Bundle.main.executablePath`" — an earlier version of this guard used
/// that and was wrong. `Bundle`/`CoreFoundation` derive `executablePath`
/// from the process's own recorded exec path (absolutized against cwd if
/// relative); they perform **no** symlink resolution and **no** case
/// canonicalization. So exec'ing the exact string
/// `/Applications/Batty.app/Contents/MacOS/batty` (lowercase — reachable via
/// a stale `/usr/local/bin/batty` symlink, a hard-coded script path, or
/// pasting `which batty`'s output) makes `executablePath` echo back that
/// same lowercase string, identical to `argv0` — so a path-equality
/// exemption fires and lets the exact invocation this guard exists to catch
/// straight through.
///
/// The exemption that's actually safe compares the invoked *name* against
/// the bundle's declared executable name (`CFBundleExecutable`, e.g.
/// `Batty` or `Batty Beta`) case-*sensitively* — that's static bundle
/// metadata, not anything derived from how the process was reached, so it
/// can't be spoofed by which path or which case was used to exec it. `batty`
/// (any case) matches the bundle name only when the case is exactly right
/// (`Batty`/`Batty Beta`); any other casing, including the exact lowercase
/// spelling reached by any path, is refused.
public enum ArgvZeroGuard {
    public static let refusalMessage = "batty: this is the Batty app's main executable, not the CLI. Use the real CLI instead — Contents/Resources/bin/batty inside the app bundle, or the /usr/local/bin/batty symlink installed from Settings \u{2192} Advanced."

    /// - Parameters:
    ///   - argv0: the invoking process's `argv[0]` (`CommandLine.arguments.first` in production).
    ///   - executableName: the bundle's declared executable name
    ///     (`Bundle.main.infoDictionary?["CFBundleExecutable"] as? String` in
    ///     production — `"Batty"` for Prod, `"Batty Beta"` for Beta). This is
    ///     static bundle metadata, not derived from `argv0` or from any
    ///     on-disk path, so it can't be defeated by which path or which case
    ///     was used to invoke the binary. `nil` fails closed (refuses).
    public static func isSpuriousCLIInvocation(argv0: String?, executableName: String?) -> Bool {
        guard let argv0, !argv0.isEmpty else { return false }
        let invokedName = (argv0 as NSString).lastPathComponent
        guard invokedName.caseInsensitiveCompare("batty") == .orderedSame else {
            return false
        }
        return invokedName != executableName
    }

    /// Runs the guard's actual effect: when `isSpuriousCLIInvocation` is
    /// true, reports `refusalMessage` through `write` and terminates the
    /// process through `terminate`; otherwise does nothing. Split out from
    /// `main.swift` so the effect itself — not just the boolean decision —
    /// is reachable from a unit test, with `write`/`terminate` injected so
    /// the test doesn't have to actually exit the test process.
    ///
    /// `terminate` is expected not to return in production (it calls
    /// `exit(_:)`), but this function does not assume that — it always
    /// calls `write` before `terminate`, and calls neither when the
    /// invocation isn't spurious.
    public static func enforce(
        argv0: String?,
        executableName: String?,
        write: (String) -> Void,
        terminate: (Int32) -> Void
    ) {
        guard isSpuriousCLIInvocation(argv0: argv0, executableName: executableName) else {
            return
        }
        write(refusalMessage + "\n")
        terminate(EXIT_FAILURE)
    }
}
