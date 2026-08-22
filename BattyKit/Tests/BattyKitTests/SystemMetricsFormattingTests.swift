// SystemMetricsFormattingTests.swift

import Testing
@testable import BattyKit

struct SystemMetricsFormattingTests {

    @Test func bytesUnderOneGibibyteFormatsAsMB() {
        #expect(SystemMetricsFormatting.bytes(830_472_192) == "792.0 MB")
    }

    @Test func bytesAtOrAboveOneGibibyteFormatsAsGB() {
        // 64 GiB, matching the design mockup's "64.00 GB" for a 64 GiB Mac.
        #expect(SystemMetricsFormatting.bytes(68_719_476_736) == "64.00 GB")
    }

    @Test func percentFormatsWithOneDecimalByDefault() {
        #expect(SystemMetricsFormatting.percent(19.66) == "19.7%")
    }

    @Test func celsiusFormatsWithDegreeSign() {
        #expect(SystemMetricsFormatting.celsius(40.0) == "40.0\u{00B0}C")
    }

    @Test func rpmRoundsToTheNearestWholeNumber() {
        #expect(SystemMetricsFormatting.rpm(999.6) == "1000 RPM")
    }

    @Test func loadAverageFormatsWithTwoDecimals() {
        #expect(SystemMetricsFormatting.loadAverage(3.5) == "3.50")
    }
}
