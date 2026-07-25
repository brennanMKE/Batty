// BrokerConnectionSignalAdmission.swift

/// Decides whether a signal reporting on a broker `NSXPCConnection` — an
/// `interruptionHandler`/`invalidationHandler` firing, or a
/// `remoteObjectProxyWithErrorHandler`/`brokerPing` reply arriving — should
/// still be acted on, given the connection's *generation* and the
/// generation `AppXPCCoordinator` currently considers live.
///
/// This exists because of a defect round-1 review of #0272 found: the
/// original handler closures captured only `[weak self]`, not which
/// connection they belonged to, so `AppXPCCoordinator` could not tell a
/// signal from its *current* connection apart from one from a connection it
/// had already discarded (superseded by `prepareForTermination()` quitting,
/// or by `attemptRepairIfNeeded()`/an invalidation-driven rebuild replacing
/// it). Two concrete failures followed: `prepareForTermination()`
/// invalidating the dying app's connection triggered a same-signal
/// re-registration on the way out, and the repair path's rebuilt connection
/// could have its `isRegisteredWithBroker`/budget state clobbered by a
/// stale signal from the orphaned connection it replaced.
///
/// The round-2 fix used `ObjectIdentifier(connection)` for this. Round-2
/// *review* correctly rejected that: `ObjectIdentifier` is only guaranteed
/// unique among objects alive *at the same time*
/// (<https://developer.apple.com/documentation/swift/objectidentifier>), and
/// every use here compares an id captured from a connection the coordinator
/// may have already released (`brokerConnection = nil`, with no other
/// strong reference) against an id from a connection allocated
/// *afterwards* — `handleBrokerSignal`'s `.rebuildConnection` case and
/// `attemptRepairIfNeeded()` both nil the old connection and allocate a
/// replacement with no intervening retain, which is exactly the shape ARC
/// address reuse needs. This project's own unit test for the previous
/// version hit that exact collision.
///
/// The fix is a monotonically increasing generation counter instead — a
/// plain `UInt64` `AppXPCCoordinator` increments once per `connectToBroker`
/// call and captures by value into every handler, with no aliasing hazard
/// at all: two live-at-different-times connections get numerically
/// different generations, full stop, independent of allocator behavior.
/// Kept as a pure comparison with no `NSXPCConnection` (or even `AnyObject`)
/// involved, so the exact defect class above is unit-testable with plain
/// integers.
public nonisolated enum BrokerConnectionSignalAdmission {
    /// `true` when `signalGeneration` matches `currentGeneration` — the
    /// signal is about the connection the coordinator still considers
    /// current, and should be acted on. `false` means the signal is stale
    /// (a superseded or already-discarded connection, including the case
    /// where `currentGeneration` is `nil` because nothing is current) and
    /// must be ignored rather than mutating coordinator state.
    public static func isCurrent(signalGeneration: UInt64, currentGeneration: UInt64?) -> Bool {
        signalGeneration == currentGeneration
    }
}
