// ProcessCPUDeltaTracker.swift

import Darwin
import Foundation

/// Converts raw mach-absolute-time ticks into nanoseconds. A process's
/// cumulative CPU ticks (`ProcessSample.cpuTicksUser`/`cpuTicksSystem`) are
/// not nanoseconds until scaled by this factor.
///
/// **Shared with #0305, which review round 1 found needed it**: an
/// earlier version of that issue's own CPU math treated
/// `ri_user_time`/`ri_system_time` as if they were already nanoseconds —
/// they are mach-absolute-time ticks, the same unit `ProcessSample`'s
/// `cpuTicksUser`/`cpuTicksSystem` carry — which under-reported a
/// single-core-pegging process's CPU% by roughly 42x (2.39% instead of
/// 99.46%, per the reviewer's measurement). #0305 adopted this type
/// instead of fixing its own copy of the same bug twice.
public enum MachTimebase {
    public static let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1.0 }
        return Double(info.numer) / Double(info.denom)
    }()
}

/// Turns two consecutive `ProcessSample` reads into a per-pid CPU
/// percentage, the same "delta over the refresh interval, not cumulative"
/// rule `docs/design/process-status-view.md` §3.2 establishes for a single
/// pid, applied per row here (`docs/design/system-metrics-view.md` §2/§5).
///
/// Deliberately caller-owned, not part of `ProcessMetricsReader` — each
/// view needs its own previous-tick baseline (`#0305`'s is one prior
/// sample; `#0314`'s is a per-pid map), and per
/// `docs/design/system-metrics-view.md` §4 that baseline is exactly the
/// state a hidden pane discards: a fresh `ProcessCPUDeltaTracker` per
/// `active`-entry, dropped on hide, is what makes "CPU% reads '—' for one
/// tick after every show" the documented (not accidental) consequence.
///
/// **Shared type, not just a shared idea**: review round 1 found #0305
/// carrying its own, independently-buggy per-pid CPU delta math (see
/// `MachTimebase`'s doc comment above) — #0305 deletes that copy and
/// instantiates this type instead, owning its own instance the same way
/// this issue's `SystemMetricsSampler` does.
public struct ProcessCPUDeltaTracker {
    private struct Baseline {
        let ticks: UInt64
        let at: Date
    }

    private var previous: [pid_t: Baseline] = [:]

    public init() {}

    /// Returns this tick's CPU percentage per pid that has both a current
    /// sample and a prior baseline. A pid absent from the result means "no
    /// baseline yet" (first tick after creation/show) or "ownership
    /// denied" (no ticks to baseline at all) — the view renders both as
    /// "—", never `0`.
    @discardableResult
    public mutating func percentages(for samples: [ProcessSample], at now: Date = Date()) -> [pid_t: Double] {
        var result: [pid_t: Double] = [:]
        var next: [pid_t: Baseline] = [:]
        next.reserveCapacity(samples.count)

        for sample in samples {
            guard let user = sample.cpuTicksUser, let system = sample.cpuTicksSystem else { continue }
            let ticks = user &+ system
            next[sample.pid] = Baseline(ticks: ticks, at: now)

            guard let prior = previous[sample.pid], ticks >= prior.ticks else { continue }
            let elapsedSeconds = now.timeIntervalSince(prior.at)
            guard elapsedSeconds > 0 else { continue }
            let deltaTicks = ticks - prior.ticks
            let deltaNanoseconds = Double(deltaTicks) * MachTimebase.nanosecondsPerTick
            let deltaSeconds = deltaNanoseconds / 1_000_000_000
            result[sample.pid] = (deltaSeconds / elapsedSeconds) * 100
        }

        previous = next
        return result
    }

    /// Drops every baseline. Not called by production code today — hiding
    /// a `system-metrics` pane discards the whole tracker instance instead
    /// (`docs/design/system-metrics-view.md` §4) — kept for a future
    /// caller (e.g. `#0305`) that wants to reset a long-lived tracker
    /// in place rather than replacing it.
    public mutating func reset() {
        previous.removeAll()
    }
}
