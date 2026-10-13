// ProcessPickerFilterTests.swift

import Testing
@testable import BattyKit

struct ProcessPickerFilterTests {
    private func proc(_ id: pid_t, _ name: String, start: UInt64 = 0, micro: UInt64 = 0) -> ProcessInspector.RunningProcess {
        ProcessInspector.RunningProcess(id: id, name: name, startSeconds: start, startMicroseconds: micro)
    }

    private var fixture: [ProcessInspector.RunningProcess] {
        [
            proc(4100, "zsh"),
            proc(41, "launchd"),
            proc(9000, "node"),
            proc(410, "node_helper"),
            proc(7, "Café"),
            proc(4123, "ssh-agent"),
        ]
    }

    @Test func emptyQueryReturnsEveryRowInOrder() {
        #expect(ProcessPickerFilter.apply("", to: fixture) == fixture)
    }

    @Test func whitespaceOnlyQueryReturnsEveryRow() {
        #expect(ProcessPickerFilter.apply("  \t ", to: fixture) == fixture)
    }

    @Test func nameSubstringIsCaseInsensitive() {
        let names = ProcessPickerFilter.apply("NODE", to: fixture).map(\.name)
        #expect(names == ["node", "node_helper"])
    }

    @Test func nameMatchIsDiacriticInsensitive() {
        #expect(ProcessPickerFilter.apply("cafe", to: fixture).map(\.id) == [7])
    }

    @Test func nameSubstringKeepsListOrderAndDoesNotReorder() {
        let names = ProcessPickerFilter.apply("sh", to: fixture).map(\.name)
        #expect(names == ["zsh", "ssh-agent"])
    }

    @Test func queryIsTrimmed() {
        #expect(ProcessPickerFilter.apply("  node  ", to: fixture).map(\.name) == ["node", "node_helper"])
    }

    @Test func digitQueryMatchesPidPrefixAndNameSubstring() {
        let extra = fixture + [proc(55, "tool2410")]
        let ids = ProcessPickerFilter.apply("41", to: extra).map(\.id)
        #expect(Set(ids) == [4100, 41, 410, 4123, 55])
        #expect(ProcessPickerFilter.apply("9", to: extra).map(\.id) == [9000])
    }

    @Test func digitQueryDoesNotMatchPidSubstringsThatAreNotPrefixes() {
        #expect(ProcessPickerFilter.apply("100", to: fixture).isEmpty)
    }

    @Test func exactPidFloatsFirstAndTheRestKeepListOrder() {
        let ids = ProcessPickerFilter.apply("41", to: fixture).map(\.id)
        #expect(ids == [41, 4100, 410, 4123])
    }

    @Test func nonMatchingQueryReturnsEmpty() {
        #expect(ProcessPickerFilter.apply("nonexistent", to: fixture).isEmpty)
    }

    @Test func listOrderSortsByNameThenStartTimeThenPid() {
        let a = proc(30, "node", start: 100, micro: 5)
        let b = proc(10, "node", start: 100, micro: 9)
        let c = proc(20, "node", start: 90, micro: 999_999)
        let d = proc(5, "node", start: 100, micro: 5)
        let apple = proc(99, "Apple", start: 500)
        let sorted = [a, b, c, d, apple, proc(1, "zed")].sorted(by: ProcessInspector.RunningProcess.listOrder)
        #expect(sorted.map(\.id) == [99, 20, 5, 30, 10, 1])
    }

    @Test func listOrderIsCaseInsensitiveOnName() {
        let upper = proc(2, "Node", start: 50)
        let lower = proc(1, "node", start: 60)
        #expect(ProcessInspector.RunningProcess.listOrder(upper, lower))
        #expect(!ProcessInspector.RunningProcess.listOrder(lower, upper))
    }
}
