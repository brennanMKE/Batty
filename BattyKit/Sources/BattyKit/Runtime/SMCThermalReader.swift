// SMCThermalReader.swift

import Foundation
import IOKit

/// CPU temperature and fan reading, sourced via the classic SMC
/// struct-method protocol (`docs/design/system-metrics-view.md` §1.4/§2).
/// Every field is `nil`, never a fabricated `0`, when the corresponding key
/// doesn't resolve on the running Mac or the SMC service can't be opened —
/// SMC key names are model-specific (§1.4's second open caveat), so a key
/// resolving on one Mac and not another is an expected, not exceptional,
/// outcome this type must represent honestly.
public nonisolated struct SMCThermalReading: Equatable, Sendable {
    public let cpuTemperatureCelsius: Double?
    public let cpuTemperatureKey: String?
    public let fanCount: Int?
    public let fanRPM: Double?
    public let fanKey: String?

    public init(
        cpuTemperatureCelsius: Double?,
        cpuTemperatureKey: String?,
        fanCount: Int?,
        fanRPM: Double?,
        fanKey: String?
    ) {
        self.cpuTemperatureCelsius = cpuTemperatureCelsius
        self.cpuTemperatureKey = cpuTemperatureKey
        self.fanCount = fanCount
        self.fanRPM = fanRPM
        self.fanKey = fanKey
    }

    public static let unavailable = SMCThermalReading(
        cpuTemperatureCelsius: nil, cpuTemperatureKey: nil,
        fanCount: nil, fanRPM: nil, fanKey: nil
    )
}

/// The three outcomes a single-key SMC probe can report — the distinction
/// `SMCTemperatureKeyCache` needs to tell a permanently missing candidate
/// key apart from a one-off IOKit/SMC hiccup, so only the former ever gets
/// cached as a miss. `.definitivelyAbsent` covers what
/// `docs/design/system-metrics-view.md`
/// actually documents about a missing key: §1.4's round 2 (~L221)
/// identifies `smcResult = 0x84` as SMC's own "key not found" code, and
/// §1.4's own spike (~L297) observed the Intel-era `TC0P` guess fail
/// cleanly with that code, not a protocol error, on this Mac. A `keyInfo`
/// reply whose `dataSize`/`dataType` don't match what a temperature
/// candidate should look like is this reader's own classification, not an
/// SMC-reported code, but is bucketed with `.definitivelyAbsent` for the
/// same reason: the key's shape is a hardware fact, not something that
/// comes and goes tick to tick. Everything else — a non-`KERN_SUCCESS`
/// `IOConnectCallStructMethod` result, any other non-zero `smcResult`, or
/// a reply that doesn't decode to a plausible value — is
/// `.transientFailure`: not confirmed permanent, though
/// `SMCTemperatureKeyCache`'s own walk bound (below) stops an
/// always-transient key from being retried forever.
enum SMCKeyProbeOutcome: Sendable, Equatable {
    case value(Double)
    case definitivelyAbsent
    case transientFailure
}

/// Caller-owned cache of which CPU-temperature candidate key resolves on
/// this Mac. Which key answers never changes while the machine is up
/// (#0351), so a Mac that has already resolved one, or already confirmed
/// none resolve, doesn't need the five-key/ten-round-trip walk repeated on
/// every tick — `SMCThermalReader.read(temperatureKeyCache:)` consults this
/// instead. Discarded on hide the same way `CoreCPUDeltaTracker`'s baseline
/// is: `SystemMetricsSampler` owns one instance per its own lifetime and
/// rebuilds it from scratch on the next show, so re-walking once per show
/// (not per tick) is the accepted cost, not something this type prevents.
///
/// A walk (first resolution, or a re-walk below) only caches `.unavailable`
/// when every candidate came back `.definitivelyAbsent` — a walk that hits
/// even one `.transientFailure` stays `.unresolved` so a transient
/// SMC/IOKit hiccup during the walk can never be mistaken for "this Mac
/// has no such sensor." That retry is bounded, not unconditional — a
/// candidate permanently misclassified as transient (a `flt `-typed key
/// that always decodes out of range, or one that always answers a
/// non-`0x84` error code) would otherwise re-walk all five keys every tick
/// forever, exactly the cost this cache exists to remove. After
/// `consecutiveInconclusiveWalksBeforeUnavailable` walks in a row end with
/// no value (whether the very first walks, or later ones a resolved key's
/// own failures triggered), the cache gives up and settles on
/// `.unavailable` for the rest of the show, the same way it would have if
/// every candidate had come back definitively absent from the start.
///
/// Re-resolve policy: a resolved key that fails (transiently or
/// definitively) `consecutiveFailuresBeforeReresolve` reads in a row
/// triggers exactly one fresh walk of the candidate list. This exists
/// purely to recover from a run of transient failures on the resolved key
/// — e.g. a temporary SMC/IOKit hiccup — by re-confirming (almost always
/// re-finding the same key) rather than being stuck reporting "no reading"
/// forever after a few bad ticks; it is not premised on the key itself
/// ever changing while the machine is up.
///
/// One consequence of that policy: a key that fails
/// `consecutiveFailuresBeforeReresolve` ticks, succeeds once, then repeats
/// that pattern indefinitely re-walks every `consecutiveFailuresBeforeReresolve
/// + 1` ticks (four, at the current threshold) for as long as the pattern
/// continues, rather than ever settling into a steady state. This is by
/// design, not a gap the walk bound above is meant to close: every
/// successful tick in the pattern is a real reading reaching the caller,
/// so there is no permanently-bad state to detect, and each re-walk
/// immediately re-finds the same key at negligible cost against the
/// per-tick budget.
///
/// One accepted consequence of walking candidates in a fixed priority
/// order: if a higher-priority candidate returns `.transientFailure` on
/// the very walk that a lower-priority one answers with a value, the
/// cache locks onto that lower-priority key for the rest of the show — the
/// walk doesn't hold off and retry the transient candidate before
/// accepting the next one that answers. Simpler than reordering probes
/// around a single blip, and harmless: every candidate the list carries is
/// an equally valid CPU-temperature reading if it resolves at all.
public nonisolated struct SMCTemperatureKeyCache: Sendable {
    enum Resolution: Sendable, Equatable {
        case unresolved
        case resolved(key: String)
        case unavailable
    }

    static let consecutiveFailuresBeforeReresolve = 3
    static let consecutiveInconclusiveWalksBeforeUnavailable = 3

    private(set) var resolution: Resolution = .unresolved
    private var consecutiveFailures = 0
    private var consecutiveInconclusiveWalks = 0

    public init() {}

    /// `probe` attempts one candidate key — the injectable seam tests use
    /// to fake SMC responses without touching IOKit.
    ///
    /// During the grace period before a re-walk triggers, a failure on the
    /// resolved key reports `(nil, nil)`, not `(nil, key)` — `key` names
    /// the source of a value, so it must not outlive the value that failed
    /// to arrive (`SMCThermalReading`'s own key-iff-value contract).
    mutating func temperature(
        candidates: [String],
        probe: (String) -> SMCKeyProbeOutcome
    ) -> (value: Double?, key: String?) {
        switch resolution {
        case .unresolved:
            return walk(candidates: candidates, probe: probe)
        case .unavailable:
            return (nil, nil)
        case .resolved(let key):
            switch probe(key) {
            case .value(let value):
                consecutiveFailures = 0
                return (value, key)
            case .definitivelyAbsent, .transientFailure:
                consecutiveFailures += 1
                guard consecutiveFailures >= Self.consecutiveFailuresBeforeReresolve else {
                    return (nil, nil)
                }
                consecutiveFailures = 0
                resolution = .unresolved
                return walk(candidates: candidates, probe: probe)
            }
        }
    }

    private mutating func walk(
        candidates: [String],
        probe: (String) -> SMCKeyProbeOutcome
    ) -> (value: Double?, key: String?) {
        var sawTransientFailure = false
        for key in candidates {
            switch probe(key) {
            case .value(let value):
                resolution = .resolved(key: key)
                consecutiveInconclusiveWalks = 0
                return (value, key)
            case .definitivelyAbsent:
                continue
            case .transientFailure:
                sawTransientFailure = true
            }
        }
        guard sawTransientFailure else {
            resolution = .unavailable
            consecutiveInconclusiveWalks = 0
            return (nil, nil)
        }
        consecutiveInconclusiveWalks += 1
        if consecutiveInconclusiveWalks >= Self.consecutiveInconclusiveWalksBeforeUnavailable {
            resolution = .unavailable
            consecutiveInconclusiveWalks = 0
        }
        return (nil, nil)
    }
}

/// Reads CPU temperature and fan speed from the `AppleSMC` IOKit service,
/// unprivileged, via the classic SMC struct-method technique
/// (`docs/design/system-metrics-view.md` §1.4). Opens, reads, and closes
/// the connection **within one call to `read()`** — never held between
/// ticks — per §6's correction: a full open+close cycle measured cheaper
/// than a single key read, so there is nothing to gain and real teardown
/// complexity to lose by holding the connection open across samples.
///
/// **One caveat carried from the design doc, not resolved by this
/// implementation**: this exact read path has not been re-verified inside
/// the signed, notarized, hardened-runtime `Batty.app` (only inside an
/// ad-hoc `swift` script and a headless `xcodebuild` build, per this
/// issue's own Gotchas). The candidate key list below is still a
/// best-effort order, not a per-model table or a runtime discovery pass —
/// that's named as real, unresolved future work in the design doc — but
/// which candidate resolves is now cached by the caller-owned
/// `SMCTemperatureKeyCache` (#0351), so the list is only walked once per
/// cache lifetime rather than on every tick.
///
/// `nonisolated` — see `SystemCPUReader`'s doc comment for why every
/// stateless reader in this file group needs this against BattyKit's
/// package-wide default `MainActor` isolation; `SystemMetricsSampler` calls
/// this from its own actor executor, not the main actor.
public nonisolated enum SMCThermalReader {
    private static let handleYPCEventSelector: UInt32 = 2
    private static let readKeyInfoSelector: UInt8 = 9
    private static let readBytesSelector: UInt8 = 5

    /// Candidate CPU-temperature keys, tried in order until one resolves.
    /// `Tp09` is the key the design's spike found on its Apple Silicon Mac
    /// mini M4; `Tp0T`/`Tp01`/`Tp05` are other commonly-cited Apple Silicon
    /// performance-core keys; `TC0P` is the classic Intel-era key
    /// (confirmed by the design's own spike to fail cleanly —
    /// `kSMCKeyNotFound`, not a protocol error — rather than crash or hang
    /// when absent).
    private static let cpuTemperatureCandidates = ["Tp09", "Tp0T", "Tp01", "Tp05", "TC0P"]
    private static let fanCountKey = "FNum"
    private static let firstFanSpeedKey = "F0Ac"

    /// The connection still opens and closes on every call regardless of
    /// `temperatureKeyCache`'s state — the fan keys below need it too, and
    /// §6's open+close-is-cheaper finding applies to the whole call, not
    /// just the temperature candidates. Only the up-to-five-key candidate
    /// walk is what the cache skips on a warm cache (#0351).
    public static func read(temperatureKeyCache: inout SMCTemperatureKeyCache) -> SMCThermalReading {
        guard let connection = openConnection() else { return .unavailable }
        defer { IOServiceClose(connection) }

        let (temperature, temperatureKey) = temperatureKeyCache.temperature(
            candidates: cpuTemperatureCandidates
        ) { key in probeFloat(connection, key: key) }

        let fanCount = readUInt8(connection, key: fanCountKey).map(Int.init)

        var fanRPM: Double?
        var fanKey: String?
        if let fanCount, fanCount > 0, let value = readFloat(connection, key: firstFanSpeedKey) {
            fanRPM = value
            fanKey = firstFanSpeedKey
        }

        return SMCThermalReading(
            cpuTemperatureCelsius: temperature,
            cpuTemperatureKey: temperatureKey,
            fanCount: fanCount,
            fanRPM: fanRPM,
            fanKey: fanKey
        )
    }

    private static func openConnection() -> io_connect_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { return nil }
        return connection
    }

    /// The wire format is "the arithmetic value produced by packing the
    /// four ASCII bytes MSB-first, stored in the caller's native byte
    /// order" — `docs/design/system-metrics-view.md` §1.4's round-2 fix.
    /// Building the `UInt32` this way and writing it with a native
    /// (non-byte-swapped) store, as `call(_:key:...)` below does via
    /// `storeBytes(of:toByteOffset:as:)`, reproduces that exactly.
    private static func fourCharCode(_ key: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in key.utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    private struct RawReply {
        let result: UInt8
        let dataSize: UInt32
        let dataType: UInt32
        let bytes: [UInt8]
    }

    /// One `IOConnectCallStructMethod` round trip against a raw, hand-offset
    /// 80-byte buffer — not a Swift struct, deliberately. §1.4's round-1
    /// failure was a Swift-synthesized struct measuring 76 bytes where the
    /// driver expects 80 (`SMCKeyInfoData`'s 9 real bytes padding to a
    /// 12-byte member stride is not reproduced by Swift's automatic
    /// layout); building the request at fixed byte offsets sidesteps that
    /// ambiguity entirely. Offsets: `key` at 0, `keyInfo.dataSize` at 28,
    /// `keyInfo.dataType` at 32, `result` at 40, the selector byte at 42,
    /// `bytes` at 48 — matching the classic 80-byte `SMCParamStruct`.
    private static func call(
        _ connection: io_connect_t,
        key: String,
        selector: UInt8,
        inputDataSize: UInt32 = 0
    ) -> RawReply? {
        var input = [UInt8](repeating: 0, count: 80)
        input.withUnsafeMutableBytes {
            $0.storeBytes(of: fourCharCode(key), toByteOffset: 0, as: UInt32.self)
            $0.storeBytes(of: inputDataSize, toByteOffset: 28, as: UInt32.self)
        }
        input[42] = selector

        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = output.count
        let result = input.withUnsafeBytes { inputPointer -> kern_return_t in
            output.withUnsafeMutableBytes { outputPointer -> kern_return_t in
                IOConnectCallStructMethod(
                    connection,
                    handleYPCEventSelector,
                    inputPointer.baseAddress, inputPointer.count,
                    outputPointer.baseAddress, &outputSize
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let smcResult = output[40]
        let dataSize = output.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) }
        let dataType = output.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt32.self) }
        let byteCount = min(Int(dataSize), 32)
        let bytes = Array(output[48..<(48 + byteCount)])
        return RawReply(result: smcResult, dataSize: dataSize, dataType: dataType, bytes: bytes)
    }

    /// SMC data-type codes, packed the same way `fourCharCode(_:)` packs a
    /// key — review round 1 (#0314): `readFloat` originally accepted any
    /// key that merely reported `dataSize == 4`, with no check that the
    /// SMC driver had actually described it as a 4-byte float. A 4-byte
    /// non-float value behind a candidate key name that happens to resolve
    /// on some Mac would decode as `Float32` garbage and render as a
    /// plausible-looking temperature. Gating on the reported type, plus
    /// the sanity range this file's own test already asserted without the
    /// code enforcing it, closes that.
    private static let floatDataType = fourCharCode("flt ")
    private static let uint8DataType = fourCharCode("ui8 ")

    /// `docs/design/system-metrics-view.md` §1.4 (~L221): a missing key
    /// replies `kr = KERN_SUCCESS` (the IOKit call itself worked) with
    /// `smcResult = 132` — SMC's own "key not found" code. Every other
    /// non-zero `smcResult` is treated as possibly transient here; the
    /// walk bound in `SMCTemperatureKeyCache` handles the case where one
    /// turns out to be permanent instead.
    private static let smcKeyNotFoundResult: UInt8 = 0x84

    /// The three-outcome probe `SMCTemperatureKeyCache` walks candidates
    /// with, distinguishing "this key doesn't exist on this Mac"
    /// (`.definitivelyAbsent`, safe to cache) from "IOKit/SMC hiccupped
    /// this one time" (`.transientFailure`, must not be cached as a
    /// permanent miss). `readFloat` below, used for the
    /// single fixed fan-speed key with no such cache, collapses this back
    /// to `Double?` since it has nothing to distinguish the outcome for.
    private static func probeFloat(_ connection: io_connect_t, key: String) -> SMCKeyProbeOutcome {
        guard let info = call(connection, key: key, selector: readKeyInfoSelector) else {
            return .transientFailure
        }
        guard info.result != smcKeyNotFoundResult else { return .definitivelyAbsent }
        guard info.result == 0 else { return .transientFailure }
        guard info.dataSize == 4, info.dataType == floatDataType else { return .definitivelyAbsent }
        guard let read = call(connection, key: key, selector: readBytesSelector, inputDataSize: info.dataSize) else {
            return .transientFailure
        }
        guard read.result != smcKeyNotFoundResult else { return .definitivelyAbsent }
        guard read.result == 0, read.bytes.count == 4 else { return .transientFailure }
        let value = read.bytes.withUnsafeBytes { $0.load(as: Float32.self) }
        // Belt-and-suspenders alongside the dataType gate above: this
        // helper backs both a temperature key (plausibly -20...150 C) and
        // a fan-speed key (plausibly 0...~20,000 RPM on any Mac), so the
        // shared range has to cover both rather than tightly bound either
        // one -- wide enough to never reject a real reading, tight enough
        // to catch the kind of wildly-out-of-range garbage a byte-order or
        // wrong-type decode produces (the design spike's own example:
        // 1.15e-41 from mis-endianness). A key correctly typed as a float
        // that decodes outside this range is treated as transient, not
        // proof the key doesn't exist — if it turns out to be permanent
        // instead, SMCTemperatureKeyCache's walk bound stops it from being
        // retried forever.
        guard value.isFinite, value > -100, value < 20_000 else { return .transientFailure }
        return .value(Double(value))
    }

    private static func readFloat(_ connection: io_connect_t, key: String) -> Double? {
        if case .value(let value) = probeFloat(connection, key: key) { return value }
        return nil
    }

    private static func readUInt8(_ connection: io_connect_t, key: String) -> UInt8? {
        guard let info = call(connection, key: key, selector: readKeyInfoSelector),
              info.result == 0, info.dataSize >= 1, info.dataType == uint8DataType
        else { return nil }
        guard let read = call(connection, key: key, selector: readBytesSelector, inputDataSize: info.dataSize),
              read.result == 0, !read.bytes.isEmpty
        else { return nil }
        return read.bytes[0]
    }
}
