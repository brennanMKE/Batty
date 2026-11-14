// BackgroundImagesEventRingTests.swift

import Foundation
import Testing
@testable import BattyKit

struct BackgroundImagesEventRingTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func recordsInOrderAndFormatsRelativeToNow() {
        var ring = BackgroundImagesEventRing()
        ring.record("window became key", at: start)
        ring.record("selection change", at: start.addingTimeInterval(0.75))
        #expect(ring.formatted(relativeTo: start.addingTimeInterval(1)) == "-1.000s window became key; -0.250s selection change")
    }

    @Test func aRunOfOneKindIsOneEntryWithACount() {
        var ring = BackgroundImagesEventRing()
        ring.record("thumbnail load", at: start)
        ring.record("thumbnail load", at: start.addingTimeInterval(0.5))
        ring.record("thumbnail load", at: start.addingTimeInterval(1))
        #expect(ring.entries.count == 1)
        #expect(ring.formatted(relativeTo: start.addingTimeInterval(1)) == "-0.000s thumbnail load x3")
    }

    @Test func keepsOnlyTheNewestCapacityEntries() {
        var ring = BackgroundImagesEventRing(capacity: 3)
        for index in 0..<5 {
            ring.record("event \(index)", at: start.addingTimeInterval(Double(index)))
        }
        #expect(ring.entries.map(\.kind) == ["event 2", "event 3", "event 4"])
    }

    @Test func emptyFormatsAsNone() {
        #expect(BackgroundImagesEventRing().formatted(relativeTo: start) == "none")
    }
}
