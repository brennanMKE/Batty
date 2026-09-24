// TeardownReapGate.swift

/// Lets a test prove "returns without blocking" *structurally*, instead of
/// timing the call (`#0428`). `ProcessGitStatusScanner.scheduleTeardownReap`
/// and, as `#0429` migrates it, `LMStudioDashboardPaneContent`'s own
/// per-process `Task.detached` reap both do the same thing: send `SIGTERM`
/// synchronously, then hand the bounded wait/`SIGKILL` escalation to a
/// detached task so the caller (`tearDown()`) returns immediately. A test
/// holds this gate closed before triggering that path, so the detached
/// task's `reapAfterTerminate` call can't even start; the caller returning
/// while the child is still alive and the gate is still closed is the
/// proof it didn't wait on the reap — not an `elapsed < .milliseconds(50)`
/// guess. The test then opens the gate and awaits the scanner's own
/// `awaitPendingTeardownReapsForTesting()`.
///
/// `nonisolated` and `Sendable`: the detached reap task runs off the main
/// actor by construction (`Task.detached`), so `waitUntilOpen()` must be
/// callable there without an actor hop, and this type must cross the
/// boundary into that detached closure — the same `nonisolated`
/// `@unchecked Sendable` + lock shape `PendingTeardownReapRegistry` already
/// uses for the same reason (#0422/#0425), and the same reason
/// `SchedulingClock` (`SchedulingClock.swift`) is `nonisolated`/`Sendable`
/// too: an actor-isolated conformer would force its cancellation/completion
/// callbacks to hop through the actor before mutating state, reopening the
/// ordering gap these types exist to close.
public protocol TeardownReapGate: Sendable {
    /// Returns immediately in production (`OpenTeardownReapGate`). A test's
    /// closed gate suspends here until the test calls `open()`.
    nonisolated func waitUntilOpen() async
}

/// The production gate — always open, so `waitUntilOpen()` never actually
/// suspends. `ProcessGitStatusScanner.init` defaults `reapGate:` to
/// `OpenTeardownReapGate()` and no production construction site overrides
/// it (`GitStatusPaneContent.init` itself defaults `scanner:` to
/// `ProcessGitStatusScanner()` with no arguments — `GitStatusPaneContent.swift`
/// — and `SplitTree.makePane` constructs `GitStatusPaneContent` with only
/// `directoryPath:`, `SplitTree.swift`), so production genuinely relies on
/// this default the same way it relies on `SystemClock()` — see that type's
/// doc comment for why a default that is simply the honest production
/// behavior isn't the #0359 hazard.
public nonisolated final class OpenTeardownReapGate: TeardownReapGate, Sendable {
    public init() {}
    public func waitUntilOpen() async {}
}
