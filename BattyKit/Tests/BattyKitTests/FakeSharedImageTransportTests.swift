// FakeSharedImageTransportTests.swift

import Foundation
import Testing
@testable import BattyKit

nonisolated struct FakeSharedImageTransportTests {

    @Test func waitForHeldReadSeesAReadThatArrivedFirst() async throws {
        let fake = FakeSharedImageTransport()
        fake.put(Data([1]), digest: "d")
        fake.holdReads()
        let reader = Task { try await fake.read(digest: "d") }
        let held = await fake.waitForHeldRead()
        #expect(held)
        fake.releaseReads()
        #expect(try await reader.value == Data([1]))
    }

    @Test func waitForHeldReadIsResumedByALaterRead() async throws {
        let fake = FakeSharedImageTransport()
        fake.put(Data([2]), digest: "d")
        fake.holdReads()
        let waiter = Task { await fake.waitForHeldRead() }
        let reader = Task { try await fake.read(digest: "d") }
        #expect(await waiter.value)
        fake.releaseReads()
        #expect(try await reader.value == Data([2]))
    }

    @Test func waitForHeldReadFailsWithNoProgress() async {
        let fake = FakeSharedImageTransport()
        fake.holdReads()
        #expect(await fake.waitForHeldRead(bound: 0.2) == false)
        #expect(fake.lastCall == nil)
    }
}
