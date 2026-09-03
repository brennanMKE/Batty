// StatusJSONPayload.swift

import Foundation

/// The `batty status --json` wire shape (#0384). Wraps `StatusPayload`
/// rather than duplicating its fields onto a new type, because `status
/// --json` must also represent every failure `status` can hit *before* it
/// ever reaches the app — broker unreachable, app unavailable, the app
/// running but unregistered, an unresolved app bundle, a declined request,
/// or the app terminating mid-request. That is the entire point of asking
/// for `--json` on a diagnostic command: a script gets valid JSON on stdout
/// in every one of those cases, never prose on stderr and empty stdout.
///
/// `state` uses the same symbolic names as `BattyXPCCore.XPCExitCode`'s
/// constants (`"ok"` for success), and `exitCode` is always the exact code
/// the process exits with, so the JSON can never say something different
/// from the exit code a caller already checked.
public nonisolated struct StatusJSONPayload: Codable, Sendable, Equatable {
    public let state: String
    public let exitCode: Int32
    public let message: String?
    public let status: StatusPayload?

    public init(state: String, exitCode: Int32, message: String?, status: StatusPayload?) {
        self.state = state
        self.exitCode = exitCode
        self.message = message
        self.status = status
    }

    public static func ok(_ status: StatusPayload) -> StatusJSONPayload {
        StatusJSONPayload(state: "ok", exitCode: 0, message: nil, status: status)
    }

    public static func failure(state: String, exitCode: Int32, message: String) -> StatusJSONPayload {
        StatusJSONPayload(state: state, exitCode: exitCode, message: message, status: nil)
    }
}
