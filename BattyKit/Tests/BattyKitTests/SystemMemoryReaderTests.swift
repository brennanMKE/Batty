// SystemMemoryReaderTests.swift

import Testing
@testable import BattyKit

struct SystemMemoryReaderTests {

    @Test func currentReturnsAPlausibleTotalAndUsedComputedFromTheThreeCategories() {
        guard let reading = SystemMemoryReader.current() else {
            Issue.record("Expected a non-nil memory reading on a real Mac")
            return
        }
        // Any Mac this test suite runs on has at least 4 GiB of physical memory.
        #expect(reading.totalBytes > 4_000_000_000)
        #expect(reading.usedBytes == reading.activeBytes + reading.wiredBytes + reading.compressedBytes)
        #expect(reading.usedBytes <= reading.totalBytes + reading.freeBytes)
    }

    @Test func pressureLevelMapsKnownKernelValuesAndFallsBackToUnknown() {
        #expect(MemoryReading.PressureLevel(rawValue: 1) == .normal)
        #expect(MemoryReading.PressureLevel(rawValue: 2) == .warn)
        #expect(MemoryReading.PressureLevel(rawValue: 4) == .critical)
        #expect(MemoryReading.PressureLevel(rawValue: 0) == .unknown)
        #expect(MemoryReading.PressureLevel(rawValue: 99) == .unknown)
    }

    @Test func unavailableFallbackIsAllZeroesWithUnknownPressure() {
        let reading = MemoryReading.unavailable
        #expect(reading.totalBytes == 0)
        #expect(reading.usedBytes == 0)
        #expect(reading.pressureLevel == .unknown)
    }
}
