// BattyIdentityContextTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `batty id`'s pure resolution logic (#0281) — env injected for
/// hermeticity rather than reading the real process environment.
struct BattyIdentityContextTests {

    private static func env(session: UUID, pane: UUID, tab: UUID) -> [String: String] {
        [
            "BATTY_SESSION_ID": session.uuidString,
            "BATTY_PANE_ID": pane.uuidString,
            "BATTY_TAB_ID": tab.uuidString,
        ]
    }

    @Test func resolveSucceedsWithAllThreeVarsPresent() {
        let session = UUID(), pane = UUID(), tab = UUID()
        let result = BattyIdentityContext.resolve(from: Self.env(session: session, pane: pane, tab: tab))
        guard case let .success(context) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(context == BattyIdentityContext(sessionID: session, paneID: pane, tabID: tab))
    }

    @Test func resolveFailsWithEmptyEnvironment() {
        let result = BattyIdentityContext.resolve(from: [:])
        guard case let .failure(.missing(keys)) = result else {
            Issue.record("expected .failure(.missing), got \(result)")
            return
        }
        #expect(Set(keys) == Set(BattyContextEnvironmentKey.allCases))
    }

    @Test func resolveReportsEachMissingKeyWhenOnlySomeArePresent() {
        var env = Self.env(session: UUID(), pane: UUID(), tab: UUID())
        env.removeValue(forKey: "BATTY_TAB_ID")
        let result = BattyIdentityContext.resolve(from: env)
        guard case let .failure(.missing(keys)) = result else {
            Issue.record("expected .failure(.missing), got \(result)")
            return
        }
        #expect(keys == [.tabID])
    }

    @Test func resolveFailsOnMalformedValue() {
        var env = Self.env(session: UUID(), pane: UUID(), tab: UUID())
        env["BATTY_PANE_ID"] = "not-a-uuid"
        let result = BattyIdentityContext.resolve(from: env)
        guard case let .failure(.malformed(keys)) = result else {
            Issue.record("expected .failure(.malformed), got \(result)")
            return
        }
        #expect(keys == [.paneID: "not-a-uuid"])
    }

    @Test func resolvePrefersMalformedOverMissingWhenBothPresent() {
        // BATTY_TAB_ID absent, BATTY_PANE_ID malformed, BATTY_SESSION_ID fine —
        // the malformed report should win so the user sees the more
        // actionable diagnosis first.
        let env = ["BATTY_SESSION_ID": UUID().uuidString, "BATTY_PANE_ID": "nope"]
        let result = BattyIdentityContext.resolve(from: env)
        guard case .failure(.malformed) = result else {
            Issue.record("expected .failure(.malformed), got \(result)")
            return
        }
    }

    /// The `--json` output shape (issue's Verification expectations): the
    /// top-level keys `batty id --json` emits are an agent-facing contract
    /// #0282/#0283 will follow — mirrors `TopologyPayloadTests
    /// .sessionInfoJSONTopLevelKeysAreStable`'s pattern of asserting the
    /// raw decoded key set rather than trusting a round-trip test (which
    /// can't catch a wire-shape regression: encoder and decoder change
    /// together).
    @Test func jsonTopLevelKeysAreStable() throws {
        let context = BattyIdentityContext(sessionID: UUID(), paneID: UUID(), tabID: UUID())
        let data = try JSONEncoder().encode(context)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["sessionID", "paneID", "tabID"])
    }

    @Test func missingErrorDescriptionListsKeyNames() {
        let error = BattyIdentityContext.ResolutionError.missing([.sessionID])
        #expect(error.description.contains("BATTY_SESSION_ID"))
    }

    @Test func malformedErrorDescriptionListsKeyAndValue() {
        let error = BattyIdentityContext.ResolutionError.malformed([.paneID: "xyz"])
        #expect(error.description.contains("BATTY_PANE_ID=xyz"))
    }
}
