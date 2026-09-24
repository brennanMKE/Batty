// FailureLogGate.swift

/// Shared rate-limiting decision for a stateless reader's failure logging,
/// mirroring `SMCTemperatureKeyCache`'s "caller owns the state between
/// ticks" shape (#0351): the reader function itself stays a pure,
/// stateless `static func`, and whichever actor calls it every tick
/// (`SystemMetricsSampler`) threads one `FailureLogGate` per distinct
/// failure category through as an `inout` parameter.
///
/// `Code` is whatever a reader uses to tell one failure cause from another
/// (a `kern_return_t`, an `errno`, or a small enum naming the failing
/// syscall) — `nil` always means "this tick succeeded." Two consecutive
/// failures with the same `Code` collapse to one `.error` log (on the
/// transition into failure, or when `Code` itself changes) followed by
/// `.debug`-level repeats — still one line every tick, just at a quieter
/// level, not skipped — so a steady-state failure logs once loudly and
/// then quietly forever after, not once per second at `.error` (#0353).
/// The first success after a run of failures reports `.recovered` once.
public nonisolated struct FailureLogGate<Code: Equatable & Sendable>: Sendable {
    public enum Disposition: Equatable, Sendable {
        /// Success following success; nothing to log.
        case stillOK
        case firstFailure
        case changedFailure
        case repeatedFailure
        case recovered
    }

    private var lastFailureCode: Code?

    public init() {}

    /// Pass `nil` for a successful read, or the cause for a failed one.
    /// Pure and side-effect-free beyond updating this gate's own stored
    /// state, so it's testable without capturing any log output.
    public mutating func record(failureCode: Code?) -> Disposition {
        defer { lastFailureCode = failureCode }
        switch (lastFailureCode, failureCode) {
        case (nil, nil):
            return .stillOK
        case (nil, .some):
            return .firstFailure
        case (.some, nil):
            return .recovered
        case (.some(let previous), .some(let current)):
            return previous == current ? .repeatedFailure : .changedFailure
        }
    }
}
