// GridSelectionTests.swift

import Observation
import Testing
@testable import BattyKit

private nonisolated final class SelectionNotified: @unchecked Sendable {
    var fired = false
}

@MainActor
struct GridSelectionTests {
    private func notifies(_ selection: GridSelection<String>, _ write: () -> Void) -> Bool {
        let flag = SelectionNotified()
        withObservationTracking { _ = selection.id } onChange: { flag.fired = true }
        write()
        return flag.fired
    }

    @Test func selectingTheSameIDDoesNotNotify() {
        let selection = GridSelection<String>()
        selection.select("a")
        #expect(!notifies(selection) { selection.select("a") })
        #expect(selection.id == "a")
    }

    @Test func selectingADifferentIDNotifies() {
        let selection = GridSelection<String>()
        selection.select("a")
        #expect(notifies(selection) { selection.select("b") })
        #expect(selection.id == "b")
    }

    @Test func clearingANilSelectionDoesNotNotify() {
        let selection = GridSelection<String>()
        #expect(!notifies(selection) { selection.select(nil) })
    }
}
