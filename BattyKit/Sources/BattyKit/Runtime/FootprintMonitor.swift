// FootprintMonitor.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "FootprintMonitor")

/// Turns a raw footprint sample into a step index above the configured soft
/// limit, so the state machine below can tell "still in the same band" from
/// "crossed into the next one" without caring about byte values directly.
///
/// Step 0 means "at or below the limit." Step 1 covers `[limit, limit +
/// stepBytes)`, step 2 covers `[limit + stepBytes, limit + 2*stepBytes)`, and
/// so on — `stepBytes` defaults to a quarter of the limit, so a 4 GB limit
/// re-warns every additional 1 GB. Pure value type; no I/O, no timers.
public struct FootprintWarningPolicy: Sendable, Equatable {
    public var limitBytes: UInt64
    public var stepBytes: UInt64

    public init(limitBytes: UInt64, stepBytes: UInt64? = nil) {
        self.limitBytes = limitBytes
        self.stepBytes = stepBytes ?? max(limitBytes / 4, 1)
    }

    public func step(forFootprintBytes bytes: UInt64) -> Int {
        guard bytes >= limitBytes else { return 0 }
        return Int((bytes - limitBytes) / stepBytes) + 1
    }
}

/// The nag-suppression state machine, isolated from the timer and from any
/// UI/notification side effect so it can be driven directly in unit tests.
///
/// Rule: a warning fires the first time a sample's step is greater than the
/// step the high-water *bytes* mark would land on under the *current*
/// policy. Dropping back to step 0 (at/below the limit) resets the high-water
/// mark, so a later re-crossing of the limit warns again from step 1.
/// Fluctuating between two already-warned steps without ever going back to 0
/// does not repeat — that is the "no nag" rule: once a footprint level has
/// been warned about, only a real escalation past it, or a fresh crossing
/// after dropping below the limit, fires again.
///
/// The high-water mark is stored as **bytes, not a step index**. A step index
/// is only meaningful relative to the policy that produced it — if the mark
/// were a bare `Int` and the soft limit changed (the user's natural reaction
/// to being warned), re-deriving the old step under the new policy would
/// silently reinterpret it, permanently suppressing further warnings while
/// the footprint kept climbing past the new limit. Storing bytes and
/// re-projecting through the current policy on every comparison keeps the
/// mark meaningful across a limit change.
public struct FootprintWarningState: Sendable, Equatable {
    private var highWaterBytes: UInt64 = 0

    public init() {}

    /// Feed one sample. Returns the step to warn about, or `nil` if this
    /// sample doesn't warrant a (new) warning.
    public mutating func evaluate(footprintBytes: UInt64, policy: FootprintWarningPolicy) -> Int? {
        let currentStep = policy.step(forFootprintBytes: footprintBytes)
        if currentStep == 0 {
            highWaterBytes = 0
            return nil
        }
        guard currentStep > policy.step(forFootprintBytes: highWaterBytes) else { return nil }
        highWaterBytes = footprintBytes
        return currentStep
    }
}

/// Periodically samples the process's own footprint and drives
/// ``FootprintWarningState`` to decide when to fire ``onWarn``. Owns the
/// sampling `Task`; everything it delegates to (``FootprintReader``,
/// ``FootprintWarningState``) is plain, synchronous, and independently
/// testable — this type is the thin timer wrapper around them.
///
/// Not started automatically: production wiring (`BattyAppDelegate`) calls
/// ``start()`` once at launch. Tests that construct `AppStateStore` (which
/// owns one of these) never call `start()`, so unit tests never spin up a
/// background sampling loop.
@MainActor
public final class FootprintMonitor {
    /// A slow-moving signal — footprint growth in #0285's field reports was
    /// measured in MB/hour, not per-frame. Sampling `task_info` itself costs
    /// microseconds, but there is no reason to poll faster than the signal
    /// actually moves, so this stays well off any hot path.
    public static let sampleInterval: Duration = .seconds(60)

    /// `(footprintBytes, step)` — `step` is provided for logging/diagnostics;
    /// callers that only need the byte count can ignore it.
    public var onWarn: ((UInt64, Int) -> Void)?

    /// Where the soft limit comes from. Defaults to the real preference;
    /// tests override this instead of touching `UserDefaults`, which keeps
    /// `sampleOnce()` runnable in isolation without racing other tests that
    /// read/write the same shared key (`UserDefaults.standard` is global
    /// process state, and Swift Testing runs test functions concurrently by
    /// default).
    public var limitBytesProvider: () -> UInt64 = { SettingsPreference.resolvedFootprintSoftLimitBytes() }

    /// Where the footprint sample comes from. Defaults to a real
    /// `task_info` read; tests override this to drive `sampleOnce()` with
    /// deterministic byte values instead of the live process's actual
    /// (constantly, if slowly, changing) footprint — the suppression rule
    /// this type exists to enforce can't be asserted against a moving
    /// target.
    public var footprintBytesProvider: () -> UInt64? = { FootprintReader.physFootprintBytes() }

    private var warningState = FootprintWarningState()
    private var samplingTask: Task<Void, Never>?

    public init() {}

    public func start() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleOnce()
                guard let interval = self?.samplingInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    /// Exposed for tests: injecting `Self.sampleInterval` on every call would
    /// otherwise make the loop above unmockable without waiting for real
    /// time to pass. Production always uses the static default.
    var samplingInterval: Duration { Self.sampleInterval }

    /// One sampling pass: read the footprint, evaluate it against the
    /// current soft-limit preference, and fire `onWarn` on a new crossing.
    /// Internal (not private) so tests can drive individual samples without
    /// going through the timer.
    func sampleOnce() {
        guard let bytes = footprintBytesProvider() else {
            logger.error("sampleOnce: footprintBytesProvider() failed")
            return
        }
        let policy = FootprintWarningPolicy(limitBytes: limitBytesProvider())
        guard let step = warningState.evaluate(footprintBytes: bytes, policy: policy) else { return }
        logger.notice("sampleOnce: soft limit crossed, step=\(step, privacy: .public) footprint=\(bytes, privacy: .public)")
        onWarn?(bytes, step)
    }
}
