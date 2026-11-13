// ProcessRowSortTests.swift

import Foundation
import Testing
@testable import BattyKit

struct ProcessRowSortTests {

    private func row(_ pid: pid_t, _ name: String = "p", cpu: Double? = 0, memory: UInt64? = 0) -> ProcessRow {
        ProcessRow(pid: pid, name: name, path: nil, cpuPercent: cpu, physFootprintBytes: memory)
    }

    /// Input order matches no field's ascending or descending order.
    private var fixture: [ProcessRow] {
        [
            row(3, "delta", cpu: 20, memory: 100),
            row(1, "bravo", cpu: 40, memory: 300),
            row(4, "alpha", cpu: 10, memory: 400),
            row(2, "charlie", cpu: 30, memory: 200),
        ]
    }

    private static let ascendingPids: [ProcessRowSort.Field: [pid_t]] = [
        .name: [4, 1, 2, 3],
        .pid: [1, 2, 3, 4],
        .cpu: [4, 3, 2, 1],
        .memory: [3, 2, 1, 4],
    ]

    @Test func defaultIsMemoryDescending() {
        #expect(ProcessRowSort.default == ProcessRowSort(field: .memory, ascending: false))
    }

    @Test(arguments: ProcessRowSort.Field.allCases)
    func sortsByEachFieldInBothDirections(field: ProcessRowSort.Field) throws {
        let expected = try #require(Self.ascendingPids[field])
        #expect(fixture.map(\.pid) != expected)
        #expect(fixture.map(\.pid) != Array(expected.reversed()))

        let ascending = ProcessRowSort(field: field, ascending: true).sorted(fixture)
        let descending = ProcessRowSort(field: field, ascending: false).sorted(fixture)

        #expect(ascending.map(\.pid) == expected)
        #expect(descending.map(\.pid) == Array(expected.reversed()))
    }

    @Test func equalKeysBreakTiesByPidAscendingInBothDirections() {
        let rows = [row(30, memory: 500), row(5, memory: 900), row(10, memory: 500), row(20, memory: 500)]

        let descending = ProcessRowSort(field: .memory, ascending: false).sorted(rows)
        let ascending = ProcessRowSort(field: .memory, ascending: true).sorted(rows)

        #expect(descending.map(\.pid) == [5, 10, 20, 30])
        #expect(ascending.map(\.pid) == [10, 20, 30, 5])
    }

    @Test func deniedRowsSortLastDescendingAndFirstAscending() {
        let rows = [row(1, cpu: 5, memory: 10), row(2, cpu: nil, memory: nil), row(3, cpu: 0, memory: 1)]

        for field in [ProcessRowSort.Field.cpu, .memory] {
            let descending = ProcessRowSort(field: field, ascending: false).sorted(rows)
            let ascending = ProcessRowSort(field: field, ascending: true).sorted(rows)
            #expect(descending.last?.pid == 2, "\(field)")
            #expect(ascending.first?.pid == 2, "\(field)")
        }
    }

    @Test func nameSortIgnoresCase() {
        let rows = [row(1, "beta"), row(2, "Alpha"), row(3, "gamma")]

        let sorted = ProcessRowSort(field: .name, ascending: true).sorted(rows)

        #expect(sorted.map(\.name) == ["Alpha", "beta", "gamma"])
    }

    @Test func toggledFlipsDirectionForTheSameFieldAndResetsToDescendingForANewOne() {
        let start = ProcessRowSort(field: .name, ascending: true)

        #expect(start.toggled(for: .name) == ProcessRowSort(field: .name, ascending: false))
        #expect(start.toggled(for: .name).toggled(for: .name) == start)
        #expect(start.toggled(for: .cpu) == ProcessRowSort(field: .cpu, ascending: false))
    }
}
