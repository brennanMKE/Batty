// CPUTemperatureAggregation.swift

import Foundation

/// One named temperature sensor reading, source-agnostic: the HID reader
/// produces these from `Product` names, tests inject them directly.
public nonisolated struct NamedTemperature: Equatable, Sendable {
    public let name: String
    public let celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

/// The CPU-die temperature chosen from a set of sensor readings.
public nonisolated struct CPUTemperatureAggregate: Equatable, Sendable {
    public let celsius: Double
    public let sensorCount: Int
}

/// Pure sensor selection and aggregation (#0455). No IOKit, so the policy
/// is testable with injected readings.
public nonisolated enum CPUTemperatureAggregation {
    /// A sensor outside this range is a failed read, not a temperature:
    /// one `PMU tdev2` service on an M4 Pro reports -9201.14 while healthy.
    public static func isPlausible(_ celsius: Double) -> Bool {
        celsius.isFinite && celsius > 0 && celsius <= 150
    }

    /// CPU die sensors by `Product` name: `PMU tdie<n>` as observed on an
    /// M4 Pro, `pACC`/`eACC MTR Temp Sensor<n>` as reported for M1-era chips
    /// by third-party tools (not verified here). `PMU tdev*`,
    /// `PMU tcal`, and NAND/battery sensors are deliberately excluded.
    public static func isCPUDieSensor(_ name: String) -> Bool {
        name.hasPrefix("PMU tdie")
            || name.hasPrefix("pACC MTR Temp Sensor")
            || name.hasPrefix("eACC MTR Temp Sensor")
    }

    /// The maximum over distinct CPU die sensor names. The HID service list
    /// repeats each name (three services per name on an M4 Pro), so readings
    /// are folded by name before counting. Max, not mean: it tracks a single
    /// busy core, which is what moves under load.
    public static func aggregate(_ readings: [NamedTemperature]) -> CPUTemperatureAggregate? {
        var hottestByName: [String: Double] = [:]
        for reading in readings where isCPUDieSensor(reading.name) && isPlausible(reading.celsius) {
            hottestByName[reading.name] = max(hottestByName[reading.name] ?? -.infinity, reading.celsius)
        }
        guard let hottest = hottestByName.values.max() else { return nil }
        return CPUTemperatureAggregate(celsius: hottest, sensorCount: hottestByName.count)
    }

    public static func detail(for aggregate: CPUTemperatureAggregate) -> String {
        "max of \(aggregate.sensorCount) die sensor\(aggregate.sensorCount == 1 ? "" : "s")"
    }
}

/// Why no CPU temperature could be produced, so the view can say which
/// situation applies rather than one sentence for all of them.
public nonisolated enum ThermalUnavailableReason: Equatable, Sendable {
    case virtualMachine
    case noCPUSensor
    case sensorServiceUnavailable

    public var copy: String {
        switch self {
        case .virtualMachine: return "Virtual machine \u{2014} no thermal sensors"
        case .noCPUSensor: return "No CPU sensor found"
        case .sensorServiceUnavailable: return "Thermal sensors unreachable"
        }
    }

    public var fanCopy: String {
        switch self {
        case .virtualMachine: return "Virtual machine \u{2014} no fan sensors"
        case .sensorServiceUnavailable: return "Fan sensors unreachable"
        case .noCPUSensor: return "Not available on this Mac"
        }
    }

    /// A guest has no `AppleSMC` service; a failed open on real hardware is
    /// a different, exceptional condition.
    public static func resolve(isVirtualMachine: Bool, smcConnectionFailed: Bool) -> ThermalUnavailableReason {
        if isVirtualMachine { return .virtualMachine }
        return smcConnectionFailed ? .sensorServiceUnavailable : .noCPUSensor
    }
}

/// Big-endian SMC fixed-point decoders for the Intel-era data types.
public nonisolated enum SMCFixedPoint {
    /// `sp78`: signed 8.8, as Intel `TC*` temperature keys.
    public static func sp78(_ high: UInt8, _ low: UInt8) -> Double {
        Double(Int16(bitPattern: UInt16(high) << 8 | UInt16(low))) / 256
    }

    /// `fpe2`: unsigned 14.2, as Intel fan-speed keys.
    public static func fpe2(_ high: UInt8, _ low: UInt8) -> Double {
        Double(UInt16(high) << 8 | UInt16(low)) / 4
    }
}
