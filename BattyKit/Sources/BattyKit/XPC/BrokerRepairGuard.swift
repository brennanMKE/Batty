// BrokerRepairGuard.swift

/// Guards the `SMAppService` unregister-then-register repair path
/// (RemoteControl #0016, `docs/xpc/xpc-cli-architecture.md` "`SMAppService
/// .status` can lie") so it runs **at most once per launch**.
///
/// `SMAppService.status` can report `.enabled` while launchd has no such
/// service — observed directly after `launchctl bootout`. The only honest
/// signal that the registration is wedged is a *failed call*, never
/// `.status`. But a failed call can recur indefinitely against a broker
/// that is genuinely, permanently gone (e.g. the user disabled the login
/// item), and unregister/register is not free — repeating it in a loop
/// would produce a flood of `SMAppService` churn instead of one clear
/// error. This type is the guard: the first `attemptRepair()` call after
/// construction returns `true` (repair should proceed); every call after
/// that returns `false` until the process relaunches, since a new launch
/// constructs a new instance.
///
/// Deliberately holds no reference to `SMAppService` or any XPC type — it is
/// pure state, so `AppXPCCoordinator`'s repair *decision* is testable
/// without performing a single real unregister/register call.
public final class BrokerRepairGuard {
    public private(set) var hasAttempted = false

    public init() {}

    /// Returns `true` exactly once: the first call transitions from
    /// "never attempted" to "attempted" and reports `true`; every
    /// subsequent call (this launch) reports `false` without changing state.
    @discardableResult
    public func attemptRepair() -> Bool {
        guard !hasAttempted else { return false }
        hasAttempted = true
        return true
    }
}
