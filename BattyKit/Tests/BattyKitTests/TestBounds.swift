// TestBounds.swift

import Foundation

/// The single hang-guard bound every completion-signal wait in this test
/// target defaults to (`docs/async-test-seams.md` §4). `AGENTS.md`
/// "Asynchronous tests" makes the bound a failure guard only, never the
/// mechanism a passing test relies on — so one generous shared value costs
/// a passing run nothing, and raising it only changes how long a genuine
/// regression takes to fail (#0443). Per-helper literals (5s/10s/15s/30s)
/// masked how close real MainActor-queueing delays under load sat to the
/// tightest of them — a deliberate-CPU-load diagnostic (`issues/0443.md`
/// "Work notes") measured real events still arriving up to ~14s after a
/// deliberately short 5s bound expired (~19s total wait), comfortably
/// inside this 60s default.
///
/// Deliberately excluded — these are not hang guards and must not route
/// through this constant:
/// - The `0.2s` bounds in `ChildProcessReadinessTests` and
///   `TestTeardownReapGateTests`: negative tests that expect the wait to
///   expire and assert `false` — routing them through this constant would
///   make each of those tests take the full 60s to *pass*, not fail.
/// - `PendingTeardownReapRegistry.register(process:label:bound:)`'s
///   production reap bound: real production behavior, not a test wait.
nonisolated enum TestBounds {
    static let hangGuard: TimeInterval = 60
}
