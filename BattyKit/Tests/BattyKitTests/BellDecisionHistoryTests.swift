// BellDecisionHistoryTests.swift

import Foundation
import Testing
@testable import BattyKit

/// #0297's in-memory ring buffer. `BellDecisionHistory` collects
/// unconditionally (no Settings toggle — see its type doc comment), caps
/// at `capacity`, and evicts oldest-first, so these tests are the direct
/// coverage for "does the cap actually hold" and "is eviction really
/// oldest-first" — the two ways a ring buffer silently misbehaves.
@MainActor
struct BellDecisionHistoryTests {

    private func makeRecord(sessionTitle: String) -> BellDecisionRecord {
        BellDecisionFormatTests.makeRecord(trigger: .bel, sessionTitle: sessionTitle)
    }

    @Test func recordAppendsAndIsReadableImmediately() {
        let history = BellDecisionHistory()
        history.record(makeRecord(sessionTitle: "first"))
        #expect(history.records.count == 1)
        #expect(history.records[0].sessionTitle == "first")
    }

    @Test func recordAppendsInInsertionOrder() {
        let history = BellDecisionHistory()
        history.record(makeRecord(sessionTitle: "one"))
        history.record(makeRecord(sessionTitle: "two"))
        history.record(makeRecord(sessionTitle: "three"))
        #expect(history.records.map(\.sessionTitle) == ["one", "two", "three"])
    }

    @Test func staysUnderCapacityDoesNotEvict() {
        let history = BellDecisionHistory()
        for i in 0..<(BellDecisionHistory.capacity - 1) {
            history.record(makeRecord(sessionTitle: "record-\(i)"))
        }
        #expect(history.records.count == BellDecisionHistory.capacity - 1)
        #expect(history.records.first?.sessionTitle == "record-0")
    }

    @Test func capsAtExactlyCapacity() {
        // Note: this alone does not exercise eviction -- exactly `capacity`
        // inserts never crosses the `> capacity` threshold, so it passes
        // identically whether eviction exists or not. It's a boundary
        // sanity check ("nothing is dropped or added spuriously at the
        // edge"), not proof the cap holds; `evictsExactlyOneWhenOneOverCapacity`
        // and `evictsOldestFirstOnceOverCapacity` below are what actually
        // pin the eviction behavior (round-2 review: a single test carrying
        // the whole invariant is a single point of failure).
        let history = BellDecisionHistory()
        for i in 0..<BellDecisionHistory.capacity {
            history.record(makeRecord(sessionTitle: "record-\(i)"))
        }
        #expect(history.records.count == BellDecisionHistory.capacity)
        #expect(history.records.first?.sessionTitle == "record-0")
        #expect(history.records.last?.sessionTitle == "record-\(BellDecisionHistory.capacity - 1)")
    }

    @Test func evictsExactlyOneWhenOneOverCapacity() {
        let history = BellDecisionHistory()
        for i in 0...BellDecisionHistory.capacity {
            history.record(makeRecord(sessionTitle: "record-\(i)"))
        }
        #expect(history.records.count == BellDecisionHistory.capacity)
        #expect(history.records.first?.sessionTitle == "record-1", "the single oldest record must be evicted")
        #expect(history.records.last?.sessionTitle == "record-\(BellDecisionHistory.capacity)")
    }

    @Test func evictsOldestFirstOnceOverCapacity() {
        let history = BellDecisionHistory()
        // capacity + 5 inserts -> the 5 oldest ("record-0"..."record-4")
        // must be gone, and the newest 1000 ("record-5"..."record-1004")
        // must remain, in order.
        for i in 0..<(BellDecisionHistory.capacity + 5) {
            history.record(makeRecord(sessionTitle: "record-\(i)"))
        }
        #expect(history.records.count == BellDecisionHistory.capacity)
        #expect(history.records.first?.sessionTitle == "record-5", "the 5 oldest records must have been evicted")
        #expect(history.records.last?.sessionTitle == "record-1004", "the newest record must survive")
        #expect(!history.records.contains { $0.sessionTitle == "record-4" }, "an evicted record must not linger")
    }

    @Test func clearEmptiesTheBuffer() {
        let history = BellDecisionHistory()
        history.record(makeRecord(sessionTitle: "one"))
        history.record(makeRecord(sessionTitle: "two"))
        history.clear()
        #expect(history.records.isEmpty)
    }

    @Test func clearOnAnEmptyBufferIsANoOp() {
        let history = BellDecisionHistory()
        history.clear()
        #expect(history.records.isEmpty)
    }
}
