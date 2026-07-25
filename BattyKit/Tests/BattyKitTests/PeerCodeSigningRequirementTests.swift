// PeerCodeSigningRequirementTests.swift

import Testing
@testable import BattyKit

/// Covers the pure requirement-string construction (#0273) that both the
/// broker's `NSXPCListener(machServiceName:)` and the app's
/// `NSXPCListener.anonymous()` hand to
/// `setConnectionCodeSigningRequirement(_:)`. `OwnCodeSigningIdentity`'s
/// real Security-framework lookup is deliberately not exercised here — it
/// has no branching logic of its own to test, and faking a process's code
/// signature isn't practical in a unit test. This is the
/// configuration-aware selection logic the lookup feeds into.
struct PeerCodeSigningRequirementTests {

    @Test func nilTeamIdentifierProducesNoRequirement() {
        // The ad-hoc/unsigned dev-build case (CODE_SIGNING_ALLOWED=NO): no
        // certificate exists to anchor a requirement to, so the caller must
        // skip enforcement entirely rather than lock every local
        // connection out.
        #expect(PeerCodeSigningRequirement.requirement(forTeamIdentifier: nil) == nil)
    }

    @Test func emptyTeamIdentifierProducesNoRequirement() {
        #expect(PeerCodeSigningRequirement.requirement(forTeamIdentifier: "") == nil)
    }

    @Test func realTeamIdentifierProducesAnchoredRequirement() {
        let requirement = PeerCodeSigningRequirement.requirement(forTeamIdentifier: "XV8BAAVZ6V")
        #expect(requirement == "anchor apple generic and certificate leaf[subject.OU] = \"XV8BAAVZ6V\"")
    }

    @Test func requirementAnchorsToAppleAndChecksTheOrganizationalUnit() {
        // Regression guard on the requirement's shape: "anchor apple
        // generic" is what rejects an ad-hoc peer outright (no
        // certificate), and "certificate leaf[subject.OU]" is where Apple
        // stores the Team ID on both an Apple Development and a Developer
        // ID Application leaf certificate — the same string must accept
        // either signing identity as long as the team matches.
        let requirement = PeerCodeSigningRequirement.requirement(forTeamIdentifier: "ABCDE12345")!
        #expect(requirement.contains("anchor apple generic"))
        #expect(requirement.contains("certificate leaf[subject.OU]"))
        #expect(requirement.contains("ABCDE12345"))
    }

    @Test func differentTeamIdentifiersProduceDifferentRequirements() {
        let a = PeerCodeSigningRequirement.requirement(forTeamIdentifier: "TEAMA00000")
        let b = PeerCodeSigningRequirement.requirement(forTeamIdentifier: "TEAMB11111")
        #expect(a != b)
    }
}
