// WaitTimeoutTests.swift

import BattyXPCCore
import Foundation
import Testing

struct WaitTimeoutTests {
    @Test(arguments: [Double.infinity, -Double.infinity, Double.nan, 0, -0.0, -1, -Double.greatestFiniteMagnitude])
    nonisolated func nonFiniteAndNonPositiveAreRejected(_ seconds: Double) {
        #expect(WaitTimeout.validationError(seconds) == "must be a positive number of seconds")
        #expect(WaitTimeout.duration(seconds) == nil)
    }

    @Test(arguments: [WaitTimeout.maximumSeconds + 1, WaitTimeout.maximumSeconds.nextUp, 1e300, Double.greatestFiniteMagnitude])
    nonisolated func aboveTheMaximumIsRejected(_ seconds: Double) {
        #expect(WaitTimeout.validationError(seconds) == "must be at most 86400 seconds")
        #expect(WaitTimeout.duration(seconds) == nil)
    }

    @Test nonisolated func theMaximumIsAccepted() {
        #expect(WaitTimeout.maximumSeconds == 86_400)
        #expect(WaitTimeout.validationError(WaitTimeout.maximumSeconds) == nil)
        #expect(WaitTimeout.duration(WaitTimeout.maximumSeconds) == .seconds(86_400))
    }

    @Test nonisolated func normalValuesConvertToMilliseconds() {
        #expect(WaitTimeout.duration(600) == .seconds(600))
        #expect(WaitTimeout.duration(1.5) == .milliseconds(1500))
        #expect(WaitTimeout.duration(0.001) == .milliseconds(1))
    }
}
