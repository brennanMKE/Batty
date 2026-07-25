// BoundedPoll.swift

import Foundation

/// The bounded retry loop backing the CLI's connect dance
/// (`docs/xpc/xpc-cli-architecture.md` step 4: "poll the broker until the
/// app registers"). Pulled out of any XPC type — `fetch` is a plain
/// closure — so it is unit-testable with no listener, no connection, no
/// broker involved.
///
/// Load-bearing per #0271: without the bound, a broken app hangs the CLI
/// forever; without the retry, a `nil` result immediately after launching
/// the app reads as failure when it is the normal race between "app
/// process started" and "app registered its endpoint with the broker."
public nonisolated enum BoundedPoll {
    /// Calls `fetch` up to `maxAttempts` times, sleeping `interval` between
    /// attempts (never after the last one), and returns the first non-`nil`
    /// result. Returns `nil` if every attempt comes back empty — in bounded
    /// time, at most `(maxAttempts - 1) * interval`, never indefinitely.
    ///
    /// `sleep` is injectable so tests can exercise the bound/retry logic
    /// without actually waiting.
    public static func poll<T>(
        maxAttempts: Int,
        interval: TimeInterval,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        fetch: () -> T?
    ) -> T? {
        precondition(maxAttempts > 0, "maxAttempts must be positive")
        for attempt in 0..<maxAttempts {
            if let value = fetch() {
                return value
            }
            if attempt < maxAttempts - 1 {
                sleep(interval)
            }
        }
        return nil
    }
}
