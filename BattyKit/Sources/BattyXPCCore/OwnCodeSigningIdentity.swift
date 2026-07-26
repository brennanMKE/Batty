// OwnCodeSigningIdentity.swift

import Foundation
import Security

/// Reads the running process's own Team Identifier straight from its code
/// signature, so the peer requirement (`PeerCodeSigningRequirement`)
/// self-derives from however *this* binary was actually signed rather than
/// a literal team-id string baked into source, which could silently drift
/// from `Configuration/Build.xcconfig`'s `DEVELOPMENT_TEAM` or
/// `scripts/release.sh`'s `TEAM_ID`.
///
/// `Security.framework` is a system framework resolved at an absolute path,
/// not `@rpath` — importing it here does not reintroduce the #0252 hazard
/// that keeps this target (and `BattyBroker`, `batty`) free of Sparkle/
/// libghostty/other SwiftPM product dependencies.
///
/// `nonisolated` at the type level (#0278, same reasoning as
/// `PeerCodeSigningRequirement`): needed so `batty`'s `nonisolated enum`
/// outgoing-connection call sites can call this synchronously.
public nonisolated enum OwnCodeSigningIdentity {
    /// `nil` covers every failure mode uniformly: `SecCodeCopySelf` failing,
    /// `SecCodeCopySigningInformation` failing, or the code being signed
    /// but carrying no Team Identifier (ad-hoc signatures have no
    /// certificate at all, so the key is simply absent from the returned
    /// dictionary per `SecCodeCopySigningInformation`'s documented
    /// behavior). Callers treat all of these the same way: don't enforce a
    /// peer requirement.
    public static func currentTeamIdentifier() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &codeRef) == errSecSuccess, let codeRef else {
            return nil
        }
        var staticCodeRef: SecStaticCode?
        guard SecCodeCopyStaticCode(codeRef, SecCSFlags(), &staticCodeRef) == errSecSuccess, let staticCodeRef else {
            return nil
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCodeRef, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any]
        else {
            return nil
        }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
