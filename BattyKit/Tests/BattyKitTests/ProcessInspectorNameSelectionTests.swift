// ProcessInspectorNameSelectionTests.swift

import Foundation
import Testing
@testable import BattyKit

/// `firstProcess(named:in:)` over synthetic records. In each test the
/// winning record is not first in the input, so input order can't pass it.
struct ProcessInspectorNameSelectionTests {

    private func record(_ pid: pid_t, _ name: String = "app", seconds: UInt64, micros: UInt64) -> ProcessInspector.RunningProcess {
        ProcessInspector.RunningProcess(id: pid, name: name, startSeconds: seconds, startMicroseconds: micros)
    }

    @Test func theEarliestStartSecondWinsEvenWithALargerMicrosecond() {
        let records = [record(10, seconds: 101, micros: 1), record(30, seconds: 100, micros: 900)]
        #expect(ProcessInspector.firstProcess(named: "app", in: records) == 30)
    }

    @Test func equalStartSecondsAreBrokenByStartMicroseconds() {
        let records = [record(10, seconds: 100, micros: 6), record(30, seconds: 100, micros: 5)]
        #expect(ProcessInspector.firstProcess(named: "app", in: records) == 30)
    }

    @Test func equalStartTimesAreBrokenByTheLowestPid() {
        let records = [record(40, seconds: 100, micros: 5), record(20, seconds: 100, micros: 5)]
        #expect(ProcessInspector.firstProcess(named: "app", in: records) == 20)
    }

    @Test func nameMatchingIsExactAndCaseSensitive() {
        let records = [
            record(11, "App", seconds: 1, micros: 0),
            record(12, "app ", seconds: 2, micros: 0),
            record(13, "apple", seconds: 3, micros: 0),
            record(14, "app", seconds: 50, micros: 0),
        ]
        #expect(ProcessInspector.firstProcess(named: "app", in: records) == 14)
        #expect(ProcessInspector.firstProcess(named: "APP", in: records) == nil)
    }

    @Test func noRecordWithTheNameIsNil() {
        #expect(ProcessInspector.firstProcess(named: "app", in: []) == nil)
        #expect(ProcessInspector.firstProcess(named: "app", in: [record(7, "other", seconds: 1, micros: 0)]) == nil)
    }
}
