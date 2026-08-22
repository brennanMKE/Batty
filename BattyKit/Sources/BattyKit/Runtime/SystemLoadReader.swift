// SystemLoadReader.swift

import Darwin
import Foundation

/// 1/5/15-minute load average (`docs/design/system-metrics-view.md` §1.6).
public struct LoadAverage: Equatable, Sendable {
    public let oneMinute: Double
    public let fiveMinute: Double
    public let fifteenMinute: Double

    public init(oneMinute: Double, fiveMinute: Double, fifteenMinute: Double) {
        self.oneMinute = oneMinute
        self.fiveMinute = fiveMinute
        self.fifteenMinute = fifteenMinute
    }

    public static let zero = LoadAverage(oneMinute: 0, fiveMinute: 0, fifteenMinute: 0)
}

/// Reads `getloadavg(3)` — the documented libc wrapper the design settled
/// on over the raw `sysctlbyname("vm.loadavg")` equivalent
/// (`docs/design/system-metrics-view.md` §1.6). Free, sub-millisecond.
public enum SystemLoadReader {
    public static func current() -> LoadAverage {
        var loads = [Double](repeating: 0, count: 3)
        let result = getloadavg(&loads, 3)
        guard result == 3 else { return .zero }
        return LoadAverage(oneMinute: loads[0], fiveMinute: loads[1], fifteenMinute: loads[2])
    }
}
