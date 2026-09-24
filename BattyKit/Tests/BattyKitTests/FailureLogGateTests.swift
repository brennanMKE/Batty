// FailureLogGateTests.swift

import Testing
@testable import BattyKit

/// `FailureLogGate<Code>` is the pure rate-limiting decision behind every
/// system-metrics reader's failure logging (#0353): a reader logs a fresh
/// failure loudly, repeats of the same cause quietly, a changed cause
/// loudly again, and recovery once. These tests exercise the disposition
/// logic directly with no logger involved, since `Logger`/`os_log` output
/// can't be captured in a unit test.
struct FailureLogGateTests {

    @Test func consecutiveSuccessesStayQuiet() {
        var gate = FailureLogGate<Int32>()
        #expect(gate.record(failureCode: nil) == .stillOK)
        #expect(gate.record(failureCode: nil) == .stillOK)
    }

    @Test func firstFailureAfterSuccessIsReportedOnce() {
        var gate = FailureLogGate<Int32>()
        _ = gate.record(failureCode: nil)
        #expect(gate.record(failureCode: 5) == .firstFailure)
    }

    @Test func repeatedIdenticalFailuresAreQuietAfterTheFirst() {
        var gate = FailureLogGate<Int32>()
        #expect(gate.record(failureCode: 5) == .firstFailure)
        #expect(gate.record(failureCode: 5) == .repeatedFailure)
        #expect(gate.record(failureCode: 5) == .repeatedFailure)
    }

    @Test func aChangedFailureCodeIsReportedAgain() {
        var gate = FailureLogGate<Int32>()
        _ = gate.record(failureCode: 5)
        #expect(gate.record(failureCode: 6) == .changedFailure)
        // Back to quiet once the new code repeats.
        #expect(gate.record(failureCode: 6) == .repeatedFailure)
    }

    @Test func recoveryAfterAFailureIsReportedOnce() {
        var gate = FailureLogGate<Int32>()
        _ = gate.record(failureCode: 5)
        #expect(gate.record(failureCode: nil) == .recovered)
        // Steady-state success afterward is quiet again.
        #expect(gate.record(failureCode: nil) == .stillOK)
    }

    @Test func aFreshFailureAfterRecoveryIsReportedAsFirstFailureAgain() {
        var gate = FailureLogGate<Int32>()
        _ = gate.record(failureCode: 5)
        _ = gate.record(failureCode: nil)
        #expect(gate.record(failureCode: 5) == .firstFailure)
    }

    /// Non-numeric `Code` types work the same way — the gate only requires
    /// `Equatable & Sendable`, which every reader's own failure-cause enum
    /// satisfies.
    @Test func worksWithAnEnumCode() {
        nonisolated enum Cause: Equatable, Sendable { case a, b }
        var gate = FailureLogGate<Cause>()
        #expect(gate.record(failureCode: .a) == .firstFailure)
        #expect(gate.record(failureCode: .a) == .repeatedFailure)
        #expect(gate.record(failureCode: .b) == .changedFailure)
        #expect(gate.record(failureCode: nil) == .recovered)
    }
}
