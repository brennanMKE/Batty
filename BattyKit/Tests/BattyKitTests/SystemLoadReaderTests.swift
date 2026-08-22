// SystemLoadReaderTests.swift

import Testing
@testable import BattyKit

struct SystemLoadReaderTests {

    @Test func currentReturnsNonNegativeValues() {
        let load = SystemLoadReader.current()
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
