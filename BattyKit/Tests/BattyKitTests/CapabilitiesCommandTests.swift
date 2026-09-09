// CapabilitiesCommandTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import batty

/// Covers `batty capabilities` (#0384). Calls `CapabilitiesCommand.verbs()`
/// / `.buildPayload()` directly rather than `.run()`: both are pure, local,
/// no-XPC functions by design (the pinned decision this issue records — no
/// app round trip, must work even when Batty is not running), so calling
/// them here exercises the real production code path without ever touching
/// a live app or broker connection, unlike every other command in this
/// target (`AppConnectDance`, `StatusCommand`, ...), which is why those stay
/// unreachable from this test target per #0365.
struct CapabilitiesCommandTests {

    // MARK: - Verb roster

    @Test func verbRosterListsEveryShippedVerb() {
        let names = Set(CapabilitiesCommand.verbs().map(\.name))
        #expect(names == [
            "new", "ping", "status", "list",
            "session info", "session focus", "session close",
            "pane split", "pane close", "pane focus", "pane hide", "pane show",
            "tab focus",
            "id", "notify", "capabilities",
        ])
    }

    @Test func verbRosterDoesNotAdvertiseWatch() {
        // #0384 pinned decision: `XPCVerb.watch` exists app-side but has no
        // CLI command (#0145 owns finishing it) — capabilities must not
        // claim a verb the CLI cannot actually run.
        let names = CapabilitiesCommand.verbs().map(\.name)
        #expect(!names.contains("watch"))
    }

    @Test func nounSubcommandsAreReportedAsNounVerbNotBareNoun() {
        // `session` and `pane` are never directly invocable; only their
        // leaves should appear, joined with the noun.
        let names = Set(CapabilitiesCommand.verbs().map(\.name))
        #expect(!names.contains("session"))
        #expect(!names.contains("pane"))
        #expect(names.contains("session info"))
        #expect(names.contains("pane split"))
        #expect(names.contains("pane close"))
    }

    @Test func idVerbReportsItsWhoamiAlias() {
        let idVerb = CapabilitiesCommand.verbs().first { $0.name == "id" }
        #expect(idVerb?.aliases == ["whoami"])
    }

    @Test func everyVerbHasANonEmptyAbstract() {
        for verb in CapabilitiesCommand.verbs() {
            #expect(!verb.abstract.isEmpty, "\(verb.name) is missing an abstract")
        }
    }

    @Test func capabilitiesVerbReportsItself() {
        // The roster is derived from BattyCLI's own subcommand tree, which
        // capabilities is registered in — so it must see itself.
        let names = Set(CapabilitiesCommand.verbs().map(\.name))
        #expect(names.contains("capabilities"))
    }

    // MARK: - Exit-code vocabulary

    @Test func exitCodeTableMatchesXPCExitCodeConstants() {
        let codes = Dictionary(uniqueKeysWithValues: CapabilitiesCommand.buildPayload().exitCodes.map { ($0.code, $0.meaning) })
        #expect(codes[XPCExitCode.brokerUnreachable] != nil)
        #expect(codes[XPCExitCode.appUnavailable] != nil)
        #expect(codes[XPCExitCode.requestFailed] != nil)
        #expect(codes[XPCExitCode.sessionTerminated] != nil)
        #expect(codes[XPCExitCode.appRunningUnregistered] != nil)
        #expect(codes[XPCExitCode.appBundleUnresolved] != nil)
        #expect(codes[0] != nil, "success (0) must be documented")
        #expect(codes[1] != nil, "CLI-side failure (1) must be documented")
        #expect(codes[64] != nil, "ArgumentParser's invalid-syntax code (64) must be documented")
    }

    @Test func exitCodeTableIsSortedAscendingWithNoDuplicates() {
        let codes = CapabilitiesCommand.buildPayload().exitCodes.map(\.code)
        #expect(codes == codes.sorted())
        #expect(Set(codes).count == codes.count)
    }

    @Test func exitCodeTableHasExactlyNineEntries() {
        // 0, 1, 2, 3, 4, 5, 6, 7, 64 — the full vocabulary as of #0384.
        // A future code added to XPCExitCode should grow this list, so this
        // count is meant to be revisited deliberately, not silently pass.
        #expect(CapabilitiesCommand.buildPayload().exitCodes.count == 9)
    }

    // MARK: - JSON encoding

    @Test func payloadJSONTopLevelKeysAreStable() throws {
        let data = try JSONEncoder().encode(CapabilitiesCommand.buildPayload())
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // #0402: `jsonSchemaDialect` is additive; the original three keys
        // (#0384) are untouched.
        #expect(Set(raw.keys) == ["cliVersion", "verbs", "exitCodes", "jsonSchemaDialect"])
        let verbs = try #require(raw["verbs"] as? [[String: Any]])
        // #0402: `inputSchema`/`annotations` are additive; `{name, abstract,
        // aliases}` (#0384) is untouched.
        #expect(Set(verbs[0].keys) == ["name", "abstract", "aliases", "inputSchema", "annotations"])
        let exitCodes = try #require(raw["exitCodes"] as? [[String: Any]])
        #expect(Set(exitCodes[0].keys) == ["code", "meaning"])
    }

    @Test func payloadRoundTrips() throws {
        let payload = CapabilitiesCommand.buildPayload()
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(CapabilitiesPayload.self, from: data)
        #expect(decoded == payload)
    }
}
