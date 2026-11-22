// PreconfirmedQuitTests.swift

import Testing
@testable import BattyKit

@MainActor
struct PreconfirmedQuitTests {
    @Test func markThenConsumeReturnsTheReasonOnce() {
        let quit = PreconfirmedQuit()
        quit.mark(.sparkleInstall)
        #expect(quit.consume() == .sparkleInstall)
        #expect(quit.consume() == nil)
    }

    @Test func clearDropsAPendingMark() {
        let quit = PreconfirmedQuit()
        quit.mark(.sparkleInstall)
        quit.clear()
        #expect(quit.pending == nil)
    }

    @Test func consumeWithNothingPendingIsNil() {
        #expect(PreconfirmedQuit().consume() == nil)
    }
}
