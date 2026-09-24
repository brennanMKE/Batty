// SMCThermalReaderTests.swift

import Testing
@testable import BattyKit

/// `SMCThermalReader.read(temperatureKeyCache:)` depends on real hardware (the `AppleSMC`
/// IOKit service) and model-specific key names
/// (`docs/design/system-metrics-view.md` §1.4) — this test asserts the
/// contract that holds on *any* Mac, not a specific reading: it never
/// crashes, and whatever it returns is internally consistent (a
/// temperature only comes with the key that produced it; a fan reading
/// only comes with a positive fan count).
struct SMCThermalReaderTests {

    @Test func readIsInternallyConsistentOnWhicheverMachineRunsThis() {
        var cache = SMCTemperatureKeyCache()
        let reading = SMCThermalReader.read(temperatureKeyCache: &cache)

        if let temperature = reading.cpuTemperatureCelsius {
            #expect(reading.cpuTemperatureKey != nil)
            // A plausible operating range for a CPU die sensor — wide
            // enough to never false-positive on real hardware, tight
            // enough to catch a garbage/unswapped-byte-order decode.
            #expect(temperature > -20)
            #expect(temperature < 150)
        } else {
            #expect(reading.cpuTemperatureKey == nil)
        }

        if let fanRPM = reading.fanRPM {
            #expect(reading.fanKey != nil)
            #expect((reading.fanCount ?? 0) > 0)
            #expect(fanRPM >= 0)
        }

        if let fanCount = reading.fanCount {
            #expect(fanCount >= 0)
        }
    }

    @Test func unavailableFallbackIsAllNil() {
        let reading = SMCThermalReading.unavailable
        #expect(reading.cpuTemperatureCelsius == nil)
        #expect(reading.cpuTemperatureKey == nil)
        #expect(reading.fanCount == nil)
        #expect(reading.fanRPM == nil)
        #expect(reading.fanKey == nil)
    }
}

/// A fake SMC probe — a `[String: SMCKeyProbeOutcome]` of what each candidate
/// key currently reports, mutable mid-test to simulate a key's outcome
/// changing between calls, plus a running count of how many times each key
/// was actually probed. This is the injectable seam
/// `SMCTemperatureKeyCache.temperature(candidates:probe:)` is built around
/// — #0351 exists because the real IOKit path has no such seam and
/// re-probes blindly every tick. A key with no explicit outcome set
/// defaults to `.definitivelyAbsent`, matching real SMC's own behavior for
/// a candidate that plain doesn't exist on this Mac.
private final class FakeSMCProbe {
    private var outcomes: [String: SMCKeyProbeOutcome]
    private(set) var callCounts: [String: Int] = [:]

    init(values: [String: Double] = [:]) {
        outcomes = values.mapValues { .value($0) }
    }

    func setValue(_ value: Double, for key: String) {
        outcomes[key] = .value(value)
    }

    func setDefinitivelyAbsent(_ key: String) {
        outcomes[key] = .definitivelyAbsent
    }

    func setTransientFailure(_ key: String) {
        outcomes[key] = .transientFailure
    }

    func callback() -> (String) -> SMCKeyProbeOutcome {
        { key in
            self.callCounts[key, default: 0] += 1
            return self.outcomes[key] ?? .definitivelyAbsent
        }
    }
}

/// Proves the behaviors `SMCTemperatureKeyCache` (#0351) is required to
/// have: a positive resolution is walked once and reused; a negative
/// resolution (every candidate definitively absent) is cached too, not
/// re-walked; a walk that hits a transient failure doesn't immediately
/// cache the negative result, on the first walk or a re-walk alike, but
/// that retry is bounded rather than forever; and a resolved key that
/// fails for `consecutiveFailuresBeforeReresolve` reads in a row triggers
/// exactly one fresh walk, not a permanent fall-back to unavailable or a
/// per-tick retry.
struct SMCTemperatureKeyCacheTests {

    @Test func resolutionHappensOnce() {
        let candidates = ["A", "B", "C"]
        let probe = FakeSMCProbe(values: ["C": 42.0])
        var cache = SMCTemperatureKeyCache()

        let first = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(first.value == 42.0)
        #expect(first.key == "C")
        #expect(probe.callCounts["A"] == 1)
        #expect(probe.callCounts["B"] == 1)
        #expect(probe.callCounts["C"] == 1)

        // Later ticks must read only the resolved key — the miss
        // candidates ("A", "B") are never probed again.
        for _ in 0..<5 {
            let result = cache.temperature(candidates: candidates, probe: probe.callback())
            #expect(result.value == 42.0)
            #expect(result.key == "C")
        }
        #expect(probe.callCounts["A"] == 1)
        #expect(probe.callCounts["B"] == 1)
        #expect(probe.callCounts["C"] == 6)
    }

    @Test func negativeResultIsCachedWhenEveryCandidateIsDefinitivelyAbsent() {
        let candidates = ["A", "B"]
        let probe = FakeSMCProbe(values: [:])
        var cache = SMCTemperatureKeyCache()

        let first = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(first.value == nil)
        #expect(first.key == nil)
        #expect(probe.callCounts["A"] == 1)
        #expect(probe.callCounts["B"] == 1)

        // A known-unavailable cache skips the probe entirely on later
        // ticks — the call counts must not move again.
        for _ in 0..<5 {
            let result = cache.temperature(candidates: candidates, probe: probe.callback())
            #expect(result.value == nil)
            #expect(result.key == nil)
        }
        #expect(probe.callCounts["A"] == 1)
        #expect(probe.callCounts["B"] == 1)
    }

    /// A one-off SMC hiccup during the very first walk — a non-`KERN_SUCCESS`
    /// transport result or an unexpected `smcResult`, not evidence the key
    /// is missing — must not cache `.unavailable` for the whole pane show.
    /// A walk that sees even one transient failure must stay `.unresolved`
    /// and retry the full walk next tick instead.
    @Test func firstWalkTransientFailureStaysUnresolvedAndRetries() {
        let candidates = ["A", "B"]
        let probe = FakeSMCProbe()
        probe.setTransientFailure("A")
        probe.setDefinitivelyAbsent("B")
        var cache = SMCTemperatureKeyCache()

        let first = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(first.value == nil)
        #expect(first.key == nil)
        #expect(cache.resolution == .unresolved)
        #expect(probe.callCounts["A"] == 1)
        #expect(probe.callCounts["B"] == 1)

        // Still unresolved, so the next tick walks the full list again —
        // this is what "retries" means, in contrast to a cached negative
        // result, which never re-probes (negativeResultIsCached… above).
        let second = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(second.value == nil)
        #expect(second.key == nil)
        #expect(probe.callCounts["A"] == 2)
        #expect(probe.callCounts["B"] == 2)

        // Once the hiccup passes, the very next walk resolves normally.
        probe.setValue(7.0, for: "A")
        let third = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(third.value == 7.0)
        #expect(third.key == "A")
    }

    @Test func reResolveRuleWorksAfterConsecutiveFailuresOnTheResolvedKey() {
        let candidates = ["A", "B"]
        let probe = FakeSMCProbe(values: ["B": 10.0])
        var cache = SMCTemperatureKeyCache()

        let first = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(first.value == 10.0)
        #expect(first.key == "B")

        let threshold = SMCTemperatureKeyCache.consecutiveFailuresBeforeReresolve
        probe.setTransientFailure("B")

        // Every failure short of the threshold reports (nil, nil), not
        // (nil, "B") — `key` names the source of a value, so it must not
        // outlive the value that failed to arrive
        // (SMCThermalReading's key-iff-value contract). "A" is never
        // re-probed during this grace period.
        for _ in 0..<(threshold - 1) {
            let result = cache.temperature(candidates: candidates, probe: probe.callback())
            #expect(result.value == nil)
            #expect(result.key == nil)
        }
        #expect(probe.callCounts["A"] == 1)

        // The threshold-th consecutive failure fires exactly one fresh
        // walk in the same call — this test exercises the walk actually
        // restarting from the top of the candidate list (finding "A"
        // here) rather than continuing to poll only "B".
        probe.setValue(5.0, for: "A")
        let reResolved = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(reResolved.value == 5.0)
        #expect(reResolved.key == "A")

        // Now cached on "A" — later ticks read only it.
        let after = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(after.value == 5.0)
        #expect(after.key == "A")
        #expect(probe.callCounts["A"] == 3)
    }

    /// The re-walk a threshold-hit triggers must obey the same "don't
    /// cache a negative over a transient failure" rule as the first walk.
    /// If every candidate the re-walk tries comes back transient (rather
    /// than definitively absent), the cache must stay `.unresolved`, not
    /// fall to `.unavailable`.
    @Test func reWalkAfterThresholdWithATransientFailureStaysUnresolved() {
        let candidates = ["A", "B"]
        let probe = FakeSMCProbe(values: ["B": 10.0])
        var cache = SMCTemperatureKeyCache()

        _ = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(cache.resolution == .resolved(key: "B"))

        let threshold = SMCTemperatureKeyCache.consecutiveFailuresBeforeReresolve
        probe.setTransientFailure("B")
        for _ in 0..<(threshold - 1) {
            _ = cache.temperature(candidates: candidates, probe: probe.callback())
        }

        // The threshold-th failure triggers the re-walk; make every
        // candidate the re-walk tries report transient, not absent.
        probe.setTransientFailure("A")
        let reWalked = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(reWalked.value == nil)
        #expect(reWalked.key == nil)
        #expect(cache.resolution == .unresolved)

        // Confirms it didn't settle on .unavailable: recovery still works
        // on the very next tick.
        probe.setValue(3.0, for: "B")
        let recovered = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(recovered.value == 3.0)
        #expect(recovered.key == "B")
    }

    /// Staying `.unresolved` after a transient failure must not become an
    /// unconditional retry-forever. A candidate permanently misclassified
    /// as `.transientFailure` (a `flt`-typed key that always decodes out
    /// of range, or one that always answers a non-`0x84` error code) would
    /// otherwise re-walk all five candidates every tick, forever — the
    /// exact per-tick cost #0351 exists to remove. After
    /// `consecutiveInconclusiveWalksBeforeUnavailable` walks in a row end
    /// with no value, the cache must give up and settle on `.unavailable`
    /// for the rest of the show, and stop probing entirely from then on —
    /// the same as the all-definitively-absent case.
    @Test func permanentlyMisclassifiedTransientFailureEventuallySettlesOnUnavailable() {
        let candidates = ["A", "B"]
        let probe = FakeSMCProbe()
        probe.setTransientFailure("A")
        probe.setDefinitivelyAbsent("B")
        var cache = SMCTemperatureKeyCache()

        let bound = SMCTemperatureKeyCache.consecutiveInconclusiveWalksBeforeUnavailable
        for _ in 0..<bound {
            let result = cache.temperature(candidates: candidates, probe: probe.callback())
            #expect(result.value == nil)
            #expect(result.key == nil)
        }
        #expect(cache.resolution == .unavailable)
        #expect(probe.callCounts["A"] == bound)
        #expect(probe.callCounts["B"] == bound)

        // Settled — later ticks skip the probe entirely, exactly like the
        // all-definitively-absent case (negativeResultIsCached… above).
        let after = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(after.value == nil)
        #expect(after.key == nil)
        #expect(probe.callCounts["A"] == bound)
        #expect(probe.callCounts["B"] == bound)
    }

    /// A walk that resolves a key must reset the inconclusive-walk counter
    /// to zero — otherwise an inconclusive walk from before a resolution
    /// and an inconclusive walk from after it (e.g. one a re-resolve
    /// threshold triggers, that itself doesn't find a value) accumulate
    /// across the resolution as if it never happened, reaching
    /// `.unavailable` sooner than the bound is meant to allow.
    @Test func consecutiveInconclusiveWalksResetsWhenAWalkResolves() {
        let candidates = ["A", "B"]
        let probe = FakeSMCProbe()
        probe.setTransientFailure("A")
        probe.setDefinitivelyAbsent("B")
        var cache = SMCTemperatureKeyCache()

        // Walk 1: inconclusive (A transient, B absent) — one walk toward
        // the unavailable bound, if it were never reset.
        _ = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(cache.resolution == .unresolved)

        // Walk 2 resolves B.
        probe.setValue(10.0, for: "B")
        let resolved = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(resolved.value == 10.0)
        #expect(resolved.key == "B")
        #expect(cache.resolution == .resolved(key: "B"))

        // B fails consecutiveFailuresBeforeReresolve times in a row; the
        // last failure triggers a fresh walk in the same call — make that
        // walk inconclusive too (both candidates transient).
        let failureThreshold = SMCTemperatureKeyCache.consecutiveFailuresBeforeReresolve
        probe.setTransientFailure("B")
        for _ in 0..<(failureThreshold - 1) {
            _ = cache.temperature(candidates: candidates, probe: probe.callback())
        }
        probe.setTransientFailure("A")
        let reWalked = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(reWalked.value == nil)
        #expect(cache.resolution == .unresolved)

        // One more inconclusive walk. With the reset in walk 2, this is
        // only the second inconclusive walk since that resolution (the
        // re-walk above, then this one), still short of the
        // three-in-a-row bound. Without that reset, walk 1's count would
        // have carried through the resolution, making this the third
        // inconclusive walk overall and settling `.unavailable` here
        // instead — this assertion is what catches that.
        let stillUnresolved = cache.temperature(candidates: candidates, probe: probe.callback())
        #expect(stillUnresolved.value == nil)
        #expect(cache.resolution == .unresolved)
    }
}
