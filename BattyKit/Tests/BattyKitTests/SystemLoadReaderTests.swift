// SystemLoadReaderTests.swift

import Testing
@testable import BattyKit

struct SystemLoadReaderTests {

    @Test func currentReturnsNonNegativeValues() {
        var failureGate = FailureLogGate<LoadReadFailure>()
        let load = SystemLoadReader.current(failureGate: &failureGate)
        #expect(load.oneMinute >= 0)
        #expect(load.fiveMinute >= 0)
        #expect(load.fifteenMinute >= 0)
    }

    @Test func zeroIsAllZeroes() {
        let load = LoadAverage.zero
        #expect(load.oneMinute == 0)
        #expect(load.fiveMinute == 0)
        #expect(load.fifteenMinute == 0)
    }
}
