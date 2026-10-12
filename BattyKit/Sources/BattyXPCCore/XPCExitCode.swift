// XPCExitCode.swift

/// Exit-code vocabulary for `batty` invocations that fail while talking to
/// the broker or the app over XPC, so scripts can tell failure modes apart.
///
/// `0` (success) and `1` (CLI-side input failure, e.g. an invalid path) are
/// already defined by the shipped CLI via `ArgumentParser.ExitCode` — see
/// `BattyKit/Sources/batty/SessionCommand.swift`. This type only adds the
/// codes the XPC path introduces; it stays `Int32` (matching
/// `Process.terminationStatus` and the C `exit()` signature) rather than
/// reaching for `ArgumentParser.ExitCode`, since `ArgumentParser` is a
/// dependency of the `batty` executable target only — `BattyXPCCore` must
/// not depend on it, so the CLI (or a future consumer) converts these to
/// `ExitCode` at its own call site.
public nonisolated enum XPCExitCode {
    /// Broker unreachable — agent not registered, or awaiting
    /// `SMAppService`'s `requiresApproval` state.
    public static let brokerUnreachable: Int32 = 2

    /// Broker answered but no app endpoint was registered, and the app
    /// could not be started.
    public static let appUnavailable: Int32 = 3

    /// Delivered to the app, which replied with a failure.
    public static let requestFailed: Int32 = 4

    /// The app terminated while a session was attached.
    public static let sessionTerminated: Int32 = 5

    /// The app is running but not registered with the broker, and did not
    /// re-register within the poll bound (#0361). Distinct from
    /// `appUnavailable`: launching would spawn a duplicate process
    /// alongside the one already running, so the CLI reports this instead
    /// of launching.
    public static let appRunningUnregistered: Int32 = 6

    /// Could not determine, deterministically, which on-disk app bundle to
    /// target (#0361 round 2) — neither the CLI's own embedded/symlinked
    /// location nor the well-known `/Applications` fallback resolved to a
    /// real bundle. Distinct from every other code here: this is reported
    /// instead of falling back to an ambiguous bundle-identifier lookup via
    /// LaunchServices, which is what let the CLI launch the wrong one of
    /// several bundles sharing `co.sstools.Batty` in the first place.
    public static let appBundleUnresolved: Int32 = 7

    /// `batty project open` reached the app, but the Project's startup
    /// commands need the user's approval and the prompt in Batty went
    /// unanswered within the app's bound (#0477). Nothing was opened.
    public static let awaitingConfirmation: Int32 = 8
}
