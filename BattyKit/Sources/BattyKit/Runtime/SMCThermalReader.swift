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
public struct SMCThermalReading: Equatable, Sendable {
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

/// Reads CPU temperature and fan speed from the `AppleSMC` IOKit service,
/// unprivileged, via the classic SMC struct-method technique
/// (`docs/design/system-metrics-view.md` §1.4). Opens, reads, and closes
/// the connection **within one call to `read()`** — never held between
/// ticks — per §6's correction: a full open+close cycle measured cheaper
/// than a single key read, so there is nothing to gain and real teardown
/// complexity to lose by holding the connection open across samples.
///
/// **Two caveats carried from the design doc, not resolved by this
/// implementation**: this exact read path has not been re-verified inside
/// the signed, notarized, hardened-runtime `Batty.app` (only inside an
/// ad-hoc `swift` script and a headless `xcodebuild` build, per this
/// issue's own Gotchas); and the candidate key list below is a best-effort
/// order, not a per-model table or a runtime discovery pass — both are
/// named as real, unresolved future work in the design doc and are not
/// built here, consistent with this issue's "get it working, iterate"
/// mandate.
public enum SMCThermalReader {
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

    public static func read() -> SMCThermalReading {
        guard let connection = openConnection() else { return .unavailable }
        defer { IOServiceClose(connection) }

        var temperature: Double?
        var temperatureKey: String?
        for key in cpuTemperatureCandidates {
            if let value = readFloat(connection, key: key) {
                temperature = value
                temperatureKey = key
                break
            }
        }

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

    private static func readFloat(_ connection: io_connect_t, key: String) -> Double? {
        guard let info = call(connection, key: key, selector: readKeyInfoSelector),
              info.result == 0, info.dataSize == 4, info.dataType == floatDataType
        else { return nil }
        guard let read = call(connection, key: key, selector: readBytesSelector, inputDataSize: info.dataSize),
              read.result == 0, read.bytes.count == 4
        else { return nil }
        let value = read.bytes.withUnsafeBytes { $0.load(as: Float32.self) }
        // Belt-and-suspenders alongside the dataType gate above: this
        // helper backs both a temperature key (plausibly -20...150 C) and
        // a fan-speed key (plausibly 0...~20,000 RPM on any Mac), so the
        // shared range has to cover both rather than tightly bound either
        // one -- wide enough to never reject a real reading, tight enough
        // to catch the kind of wildly-out-of-range garbage a byte-order or
        // wrong-type decode produces (the design spike's own example:
        // 1.15e-41 from mis-endianness).
        guard value.isFinite, value > -100, value < 20_000 else { return nil }
        return Double(value)
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
