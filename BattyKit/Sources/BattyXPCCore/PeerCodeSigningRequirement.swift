// PeerCodeSigningRequirement.swift

/// Pure construction of the code-signing requirement string every XPC
/// listener (the broker's `NSXPCListener(machServiceName:)` and the app's
/// `NSXPCListener.anonymous()`) hands to
/// `setConnectionCodeSigningRequirement(_:)` to reject connections from a
/// foreign team identity. Kept separate from the Security-framework lookup
/// in `OwnCodeSigningIdentity` so the string-building/selection logic is
/// unit-testable without touching a real process's code signature.
public enum PeerCodeSigningRequirement {
    /// `anchor apple generic` requires the peer's certificate to chain to an
    /// Apple root at all (ad-hoc signatures have no certificate and fail
    /// this outright); `certificate leaf[subject.OU]` is where Apple stores
    /// the Team ID on both an "Apple Development" and a "Developer ID
    /// Application" leaf certificate, so this one requirement string
    /// accepts either signing identity as long as the team matches —
    /// exactly what's needed since local dev builds sign with Apple
    /// Development and `scripts/release.sh` signs with Developer ID.
    ///
    /// A `nil` or empty team identifier means the running binary is itself
    /// ad-hoc/unsigned (e.g. a `CODE_SIGNING_ALLOWED=NO` local iteration
    /// build) — there is no certificate to anchor a requirement to, and
    /// enforcing one anyway would make every local connection fail closed,
    /// breaking dev iteration entirely. Returning `nil` here is the signal
    /// to the caller: skip `setConnectionCodeSigningRequirement` altogether
    /// and accept any peer. This is the documented, deliberate development
    /// escape hatch, not an oversight.
    public static func requirement(forTeamIdentifier teamIdentifier: String?) -> String? {
        guard let teamIdentifier, !teamIdentifier.isEmpty else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}
