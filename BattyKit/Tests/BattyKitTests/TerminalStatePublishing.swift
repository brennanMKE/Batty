// TerminalStatePublishing.swift

import Foundation
import Testing
@testable import BattyKit

/// Awaits `TerminalViewState`'s deferred publish after a delegate callback.
///
/// libghostty-spm's `publishSoon` (`TerminalViewState+Delegate.swift`) routes
/// every `@Published` write made from a delegate callback
/// (`terminalDidRingBell`, `terminalDidRequestDesktopNotification`,
/// `terminalDidChangeTitle`, `terminalDidFinishCommand`, …) through
/// `terminalRunOnMainNextTurn` — an unconditional `DispatchQueue.main.async`,
/// never inline even when already on the main thread. Production never
/// notices: `.onChange(of:)` in `PaneView.swift` only fires once the write
/// has landed, so the read is always causally downstream of the publish. A
/// test that calls a delegate method and reads the published property on
/// the next line races that deferral and sees the pre-call value.
///
/// Call this between the delegate call and the read, with a predicate over
/// the value the callback is expected to have changed. Each iteration
/// yields one real main-queue turn — since the queue is FIFO, a pending
/// `publishSoon` write scheduled before this call is guaranteed to run
/// before this function's own turn does, so the predicate reliably flips on
/// the very first hop today. Polling (rather than a single hard-coded hop)
/// means this stays correct without a fixture change if the wrapper ever
/// grows to defer over more than one turn; `maxTurns` is a generous ceiling,
/// not a tuned constant.
///
/// **The predicate must be false at call time.** It is checked *before* the
/// first hop, so if it's already true — e.g. a bare `!= nil` after a second
/// delegate call on an already-non-nil property — this returns immediately
/// having drained nothing, and the caller reads whatever stale value was
/// there before the call it meant to wait for. Prefer a predicate that is
/// false until the specific write lands: a monotonic comparison
/// (`bellCount >= expectedCount`) or an equality check against the new
/// value, not a bare non-nil/non-empty check on a property a prior call may
/// already have set.
///
/// If the predicate never becomes true within `maxTurns`, this records a
/// failing issue at the caller's location rather than letting the test read
/// stale state and pass (or fail) for the wrong reason.
@MainActor
func awaitTerminalStatePublish(
    maxTurns: Int = 20,
    sourceLocation: SourceLocation = #_sourceLocation,
    until predicate: () -> Bool
) async {
    for _ in 0..<maxTurns {
        if predicate() { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
    if !predicate() {
        Issue.record(
            "Timed out after \(maxTurns) main-queue turns waiting for TerminalViewState's deferred publish to land",
            sourceLocation: sourceLocation
        )
    }
}
