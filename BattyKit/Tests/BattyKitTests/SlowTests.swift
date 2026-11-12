// SlowTests.swift

import Foundation

/// Gate for the opt-in full tier. Slow tests carry
/// `.enabled(if: SlowTests.enabled, …)` and run only under
/// `./build.sh unit --full` or `BATTY_FULL_TESTS=1 swift test`.
nonisolated enum SlowTests {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["BATTY_FULL_TESTS"] == "1"
    }
}
