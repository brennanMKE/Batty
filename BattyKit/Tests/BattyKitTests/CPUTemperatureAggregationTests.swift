// CPUTemperatureAggregationTests.swift

import Testing
@testable import BattyKit

struct CPUTemperatureAggregationTests {
    private func t(_ name: String, _ value: Double) -> NamedTemperature {
        NamedTemperature(name: name, celsius: value)
    }

    @Test func m4ProReadingsAggregateToTheHottestDieSensorAndIgnoreGarbageAndNonCPU() {
        var readings: [NamedTemperature] = []
        for n in 1...14 {
            let value = 62.0 + Double(n % 7)
            for _ in 0..<3 { readings.append(t("PMU tdie\(n)", value)) }
        }
        readings.append(t("PMU tdev1", 90.2))
        readings.append(t("PMU tdev2", -9201.14))
        readings.append(t("PMU tcal", 55))
        readings.append(t("NAND CH0 temp", 49))
        let aggregate = CPUTemperatureAggregation.aggregate(readings)
        #expect(aggregate == CPUTemperatureAggregate(celsius: 68, sensorCount: 14))
        #expect(CPUTemperatureAggregation.detail(for: aggregate!) == "max of 14 die sensors")
    }

    @Test func garbageDieReadingIsIgnoredButTheNameStillCountsFromItsOtherServices() {
        let readings = [t("PMU tdie1", -9201.14), t("PMU tdie1", 64), t("PMU tdie2", 0), t("PMU tdie3", .nan)]
        #expect(CPUTemperatureAggregation.aggregate(readings) == CPUTemperatureAggregate(celsius: 64, sensorCount: 1))
    }

    @Test func m1StyleClusterSensorsAreCPU() {
        let readings = [t("pACC MTR Temp Sensor1", 51), t("pACC MTR Temp Sensor2", 55), t("eACC MTR Temp Sensor0", 47), t("gas gauge battery", 30)]
        #expect(CPUTemperatureAggregation.aggregate(readings) == CPUTemperatureAggregate(celsius: 55, sensorCount: 3))
    }

    @Test func duplicatesByNameFoldToOneSensor() {
        let readings = [t("PMU tdie1", 60), t("PMU tdie1", 61), t("PMU tdie1", 59)]
        #expect(CPUTemperatureAggregation.aggregate(readings) == CPUTemperatureAggregate(celsius: 61, sensorCount: 1))
    }

    @Test func emptyAndNonCPUOnlySetsYieldNil() {
        #expect(CPUTemperatureAggregation.aggregate([]) == nil)
        #expect(CPUTemperatureAggregation.aggregate([t("PMU tdev1", 70), t("NAND CH0 temp", 40)]) == nil)
    }

    @Test func plausibilityBounds() {
        #expect(!CPUTemperatureAggregation.isPlausible(-9201.14))
        #expect(!CPUTemperatureAggregation.isPlausible(0))
        #expect(!CPUTemperatureAggregation.isPlausible(150.5))
        #expect(!CPUTemperatureAggregation.isPlausible(.infinity))
        #expect(CPUTemperatureAggregation.isPlausible(150))
        #expect(CPUTemperatureAggregation.isPlausible(35.5))
    }

    @Test func unavailableReasonDistinguishesTheThreeSituations() {
        #expect(ThermalUnavailableReason.resolve(isVirtualMachine: true, smcConnectionFailed: true) == .virtualMachine)
        #expect(ThermalUnavailableReason.resolve(isVirtualMachine: false, smcConnectionFailed: true) == .sensorServiceUnavailable)
        #expect(ThermalUnavailableReason.resolve(isVirtualMachine: false, smcConnectionFailed: false) == .noCPUSensor)
        #expect(ThermalUnavailableReason.virtualMachine.copy.hasPrefix("Virtual machine"))
        #expect(ThermalUnavailableReason.noCPUSensor.copy == "No CPU sensor found")
        #expect(ThermalUnavailableReason.virtualMachine.fanCopy.hasPrefix("Virtual machine"))
    }

    @Test func liveHIDReadIsConsistentOnWhicheverMachineRunsThis() {
        switch HIDThermalReader.readAll() {
        case .success(let readings):
            for reading in readings { #expect(CPUTemperatureAggregation.isCPUDieSensor(reading.name)) }
            if let aggregate = CPUTemperatureAggregation.aggregate(readings) {
                #expect(CPUTemperatureAggregation.isPlausible(aggregate.celsius))
                #expect(aggregate.sensorCount > 0)
            }
        case .failure:
            break
        }
    }
}

struct SMCPayloadTests {
    @Test func payloadLengthComesFromTheRequestedSizeNotTheReply() {
        let reply = [UInt8](repeating: 0xAB, count: 32)
        #expect(SMCThermalReader.payload(reply, requestedSize: 4).count == 4)
        #expect(SMCThermalReader.payload(reply, requestedSize: 0).isEmpty)
        #expect(SMCThermalReader.payload(reply, requestedSize: 99).count == 32)
    }

    @Test func floatPayloadDecodesFromTheFirstFourBytes() {
        var reply = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: Float32(77.7)) { for (i, b) in $0.enumerated() { reply[i] = b } }
        let value = SMCThermalReader.payload(reply, requestedSize: 4).withUnsafeBytes { $0.load(as: Float32.self) }
        #expect(value == 77.7)
    }
}

struct SMCFixedPointTests {
    @Test func sp78DecodesSignedEightPointEight() {
        #expect(SMCFixedPoint.sp78(0x2B, 0x80) == 43.5)
        #expect(SMCFixedPoint.sp78(0x00, 0x00) == 0)
        #expect(SMCFixedPoint.sp78(0xFF, 0x00) == -1)
        #expect(SMCFixedPoint.sp78(0x7F, 0xFF) == 127.99609375)
    }

    @Test func fpe2DecodesUnsignedFourteenPointTwo() {
        #expect(SMCFixedPoint.fpe2(0x0F, 0xA0) == 1000)
        #expect(SMCFixedPoint.fpe2(0x00, 0x01) == 0.25)
    }

    @Test func numericDecodeAcceptsOnlyMatchingTypeAndLength() {
        let flt = SMCThermalReader.decodeNumeric(dataType: 0x666C7420, payload: [0, 0, 0x20, 0x42])
        #expect(flt == 40)
        #expect(SMCThermalReader.decodeNumeric(dataType: 0x73703738, payload: [0x2B, 0x80]) == 43.5)
        #expect(SMCThermalReader.decodeNumeric(dataType: 0x66706532, payload: [0x0F, 0xA0]) == 1000)
        #expect(SMCThermalReader.decodeNumeric(dataType: 0x73703738, payload: [0x2B]) == nil)
        #expect(SMCThermalReader.decodeNumeric(dataType: 0x75693820, payload: [1, 2]) == nil)
    }
}
