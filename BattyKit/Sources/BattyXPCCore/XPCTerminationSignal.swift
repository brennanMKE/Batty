// XPCTerminationSignal.swift

/// Sentinel `XPCResponse.error` string the app sends to any in-flight
/// `AppServiceProtocol.perform` call when it is quitting (#0272 item 4),
/// so a connected CLI can tell "the app told me it is terminating" apart
/// from every other request failure and report `XPCExitCode
/// .sessionTerminated` (5) instead of the generic `XPCExitCode
/// .requestFailed` (4) an ordinary `ok: false` reply would produce.
///
/// A plain string rather than a new `XPCResponse` field: it travels inside
/// the existing `error` field, so no wire-format change is needed and older
/// and newer builds of either side degrade gracefully — a CLI that doesn't
/// recognize the sentinel still sees `ok: false` and reports exit `4`,
/// which is a defensible fallback rather than a crash or hang.
public nonisolated enum XPCTerminationSignal {
    public static let appTerminating = "app terminating"
}
