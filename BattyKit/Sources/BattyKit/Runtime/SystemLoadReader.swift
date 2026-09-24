// SystemLoadReader.swift

import Darwin
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SystemLoadReader")

/// `getloadavg` itself only reports success/failure (a returned count of 3
/// vs anything else) — the failing `errno` is the only detail available to
/// tell one failure apart from another (#0353).
public nonisolated enum LoadReadFailure: Equatable, Sendable {
    case getloadavgFailed(errno: Int32)
}

/// 1/5/15-minute load average (`docs/design/system-metrics-view.md` §1.6).
public nonisolated struct LoadAverage: Equatable, Sendable {
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
///
/// `nonisolated` — see `SystemCPUReader`'s doc comment for why every
/// stateless reader in this file group needs this against BattyKit's
/// package-wide default `MainActor` isolation.
public nonisolated enum SystemLoadReader {
    public static func current(failureGate: inout FailureLogGate<LoadReadFailure>) -> LoadAverage {
        var loads = [Double](repeating: 0, count: 3)
        errno = 0
        let result = getloadavg(&loads, 3)
        guard result == 3 else {
            logFailure(failureGate.record(failureCode: .getloadavgFailed(errno: errno)), errno: errno)
            return .zero
        }
        logFailure(failureGate.record(failureCode: nil), errno: 0)
        return LoadAverage(oneMinute: loads[0], fiveMinute: loads[1], fifteenMinute: loads[2])
    }

    private static func logFailure(_ disposition: FailureLogGate<LoadReadFailure>.Disposition, errno: Int32) {
        switch disposition {
        case .stillOK:
            return
        case .firstFailure, .changedFailure:
            logger.error("load: getloadavg failed, errno=\(errno, privacy: .public)")
        case .repeatedFailure:
            logger.debug("load: getloadavg still failing, errno=\(errno, privacy: .public)")
        case .recovered:
            logger.info("load: recovered")
        }
    }
}
