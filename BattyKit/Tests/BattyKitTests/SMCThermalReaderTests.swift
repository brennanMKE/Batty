// SMCThermalReaderTests.swift

import Testing
@testable import BattyKit

/// `SMCThermalReader.read()` depends on real hardware (the `AppleSMC`
/// IOKit service) and model-specific key names
/// (`docs/design/system-metrics-view.md` §1.4) — this test asserts the
/// contract that holds on *any* Mac, not a specific reading: it never
/// crashes, and whatever it returns is internally consistent (a
/// temperature only comes with the key that produced it; a fan reading
/// only comes with a positive fan count).
struct SMCThermalReaderTests {

    @Test func readIsInternallyConsistentOnWhicheverMachineRunsThis() {
        let reading = SMCThermalReader.read()

        if let temperature = reading.cpuTemperatureCelsius {
            #expect(reading.cpuTemperatureKey != nil)
            // A plausible operating range for a CPU die sensor — wide
            // enough to never false-positive on real hardware, tight
            // enough to catch a garbage/unswapped-byte-order decode.
            #expect(temperature > -20)
            #expect(temperature < 150)
        } else {
            #expect(reading.cpuTemperatureKey == nil)
        }

        if let fanRPM = reading.fanRPM {
            #expect(reading.fanKey != nil)
            #expect((reading.fanCount ?? 0) > 0)
            #expect(fanRPM >= 0)
        }

        if let fanCount = reading.fanCount {
            #expect(fanCount >= 0)
        }
    }

    @Test func unavailableFallbackIsAllNil() {
        let reading = SMCThermalReading.unavailable
        #expect(reading.cpuTemperatureCelsius == nil)
        #expect(reading.cpuTemperatureKey == nil)
        #expect(reading.fanCount == nil)
        #expect(reading.fanRPM == nil)
        #expect(reading.fanKey == nil)
    }
}
