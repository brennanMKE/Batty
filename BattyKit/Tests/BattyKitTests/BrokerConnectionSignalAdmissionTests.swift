// BrokerConnectionSignalAdmissionTests.swift

import Testing
@testable import BattyKit

/// Covers the connection-generation admission gate added in #0272 review to
/// fix a defect found across two rounds: `AppXPCCoordinator`'s broker
/// -connection handlers originally captured only `[weak self]`, not which
/// connection they were about, so a signal from a superseded connection
/// (one `prepareForTermination()` had already torn down, or one
/// `attemptRepairIfNeeded()`/a rebuild had already replaced) could still
/// mutate live state. Round 1's fix used `ObjectIdentifier(connection)`;
/// round 2 review correctly rejected that, because `ObjectIdentifier`
/// uniqueness holds only among objects alive at the same time, and the
/// coordinator repeatedly nils a connection and allocates its replacement
/// with no intervening retain — exactly the shape that can reuse an
/// address (this project's own round-1 unit test hit that exact collision
/// before being rewritten to keep both objects alive, which papered over
/// the design issue rather than fixing it). A monotonic `UInt64` generation
/// counter has no such hazard: two connections live at different times
/// always get numerically different generations, independent of allocator
/// behavior. No `NSXPCConnection` — not even an `AnyObject` stand-in — is
/// involved here.
struct BrokerConnectionSignalAdmissionTests {

    @Test func signalFromTheCurrentGenerationIsAdmitted() {
        #expect(BrokerConnectionSignalAdmission.isCurrent(signalGeneration: 1, currentGeneration: 1))
    }

    @Test func signalFromAnOlderGenerationIsRejected() {
        // Models the defect: an orphaned connection from a previous rebuild
        // (generation 1) signaling after the coordinator has already moved
        // on to a new one (generation 2).
        #expect(!BrokerConnectionSignalAdmission.isCurrent(signalGeneration: 1, currentGeneration: 2))
    }

    @Test func signalFromANewerGenerationThanCurrentIsAlsoRejected() {
        // Not expected in practice (generations only increase, and a signal
        // can't outrun the coordinator's own counter), but the gate is a
        // plain equality check, not an ordering one — asserting this
        // direction too pins that down rather than leaving it implicit.
        #expect(!BrokerConnectionSignalAdmission.isCurrent(signalGeneration: 2, currentGeneration: 1))
    }

    @Test func signalWhenNothingIsCurrentIsRejected() {
        // Models `prepareForTermination()` clearing the tracked generation
        // to `nil` before `invalidate()` can trigger a late signal on the
        // way out — that signal must find no current generation to match.
        #expect(!BrokerConnectionSignalAdmission.isCurrent(signalGeneration: 1, currentGeneration: nil))
    }

    @Test func aNewerGenerationNeverEqualsAnOlderOne() {
        // The property the production path actually relies on — unlike the
        // round-1 `ObjectIdentifier` version, this holds unconditionally,
        // with no dependence on allocator/address-reuse behavior. Checked
        // across a range, not just one pair, since the point is that it
        // holds for every generation, not by chance for a particular pair
        // of values.
        for generation in UInt64(1)...20 {
            #expect(!BrokerConnectionSignalAdmission.isCurrent(signalGeneration: generation, currentGeneration: generation + 1))
        }
    }
}
