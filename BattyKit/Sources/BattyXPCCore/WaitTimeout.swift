// WaitTimeout.swift

import Foundation

/// The one check for a `--wait` timeout in seconds, shared by the CLI and the
/// app. The app re-checks every wire value before converting it to a
/// `Duration`: any XPC or MCP client can send infinity, NaN or `1e300`, and
/// `Int(_:)` on those traps and takes down every Terminal Session.
public nonisolated enum WaitTimeout {
    /// One day. Longer than any command an agent should block a tool call on,
    /// and far inside the range a `Duration` holds.
    public static let maximumSeconds: Double = 86_400

    /// nil when `seconds` is finite, greater than 0, and at most `maximumSeconds`.
    public static func validationError(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return "must be a positive number of seconds" }
        guard seconds <= maximumSeconds else { return "must be at most \(Int(maximumSeconds)) seconds" }
        return nil
    }

    /// The timeout as a `Duration`, or nil for a value `validationError` rejects.
    public static func duration(_ seconds: Double) -> Duration? {
        guard validationError(seconds) == nil else { return nil }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }
}
