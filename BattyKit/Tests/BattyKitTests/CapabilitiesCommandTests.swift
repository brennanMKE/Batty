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
/// a live app or broker connection, unlike most other commands in this
/// target — `StatusCommand.run()` itself takes no injectable parameters, so
/// it still isn't unit-testable directly (see `AppConnectDanceTests` for the
/// wiring it delegates to, which #0365 made testable).
struct CapabilitiesCommandTests {

    // MARK: - Verb roster

    static let flagOff = FeatureFlags(sharedProjectImages: false, servers: false)
    static let flagOn = FeatureFlags.allOnForTests

    static let flagOffRoster: Set<String> = [
        "new", "ping", "status", "list",
        "session info", "session focus", "session close", "session remind",
        "pane split", "pane close", "pane focus", "pane hide", "pane show",
        "tab focus",
        "tab new",
        "project list", "project open", "project create", "project edit", "background list",
        "id", "notify", "mcp", "agent install", "agent context", "capabilities",
    ]

    @Test(arguments: [false, true])
    func verbRosterListsEveryShippedVerb(flagsOn: Bool) {
        let flags = flagsOn ? Self.flagOn : Self.flagOff
        let names = Set(CapabilitiesCommand.verbs(flags: flags).map(\.name))
        let expected = flagsOn ? Self.flagOffRoster.union([
            "server start", "server share", "server serve", "server list", "server stop", "server restart", "server unshare", "server tailnet",
        ]) : Self.flagOffRoster
        #expect(names == expected)
    }

    @Test func skillInstallLinesNameAgentInstallThenTheSiteZip() throws {
        let lines = CapabilitiesCommand.skillInstallLines()
        let text = lines.joined(separator: "\n")
        #expect(CapabilitiesCommand.skillDownloadURL == "https://batty.sstools.co/docs/skill/batty-cli-skill-latest.zip")
        let installIndex = try #require(lines.firstIndex { $0.contains("agent install [--dry-run] [--project DIR]") })
        let urlIndex = try #require(lines.firstIndex { $0.contains(CapabilitiesCommand.skillDownloadURL) })
        #expect(installIndex < urlIndex)
        #expect(!text.contains("git clone"))
    }

    @Test func prodPayloadListsMcpAndAgentVerbs() {
        let prod = FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.prod.appBundleIdentifier, environment: [:])
        for payload in [CapabilitiesCommand.buildPayload(flags: prod), CapabilitiesCommand.buildPayload()] {
            let names = Set(payload.verbs.map(\.name))
            #expect(names.isSuperset(of: ["mcp", "agent install", "agent context"]))
        }
    }

    @Test func flagOffPayloadHasNoServerVerbs() {
        let names = CapabilitiesCommand.buildPayload(flags: Self.flagOff).verbs.map(\.name)
        #expect(!names.contains { $0.hasPrefix("server") })
    }

    @Test func stopAndRestartAreDestructive() {
        #expect(CapabilitiesCommand.annotations(forVerbPath: "server stop").destructiveHint)
        #expect(CapabilitiesCommand.annotations(forVerbPath: "server restart").destructiveHint)
    }

    @Test func shareIsIdempotentAndUnshareIsNotDestructive() {
        let share = CapabilitiesCommand.annotations(forVerbPath: "server share")
        #expect(share.idempotentHint && !share.destructiveHint && !share.readOnlyHint)
        let unshare = CapabilitiesCommand.annotations(forVerbPath: "server unshare")
        #expect(!unshare.destructiveHint && !unshare.idempotentHint)
        #expect(CapabilitiesCommand.annotations(forVerbPath: "server list").readOnlyHint)
    }

    @Test func tailnetIsIdempotentNotDestructiveAndOpenWorld() {
        #expect(CapabilitiesCommand.annotations(forVerbPath: "server tailnet")
            == .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true))
    }

    @Test func capabilitiesListsSessionRemind() {
        #expect(CapabilitiesCommand.verbs().contains { $0.name == "session remind" })
        #expect(CapabilitiesCommand.annotations(forVerbPath: "session remind")
            == .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false))
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

    @Test func exitCodeTableHasExactlyTenEntries() {
        // 0, 1, 2, 3, 4, 5, 6, 7, 8, 64 — the full vocabulary (8 is the awaiting-confirmation code).
        // A future code added to XPCExitCode should grow this list, so this
        // count is meant to be revisited deliberately, not silently pass.
        #expect(CapabilitiesCommand.buildPayload().exitCodes.count == 10)
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

    // MARK: - Agent skill install pointer (#0403)

    @Test func plainTextSummaryAppendsTheSkillBlockExactlyOnceAfterExitCodes() throws {
        let payload = CapabilitiesCommand.buildPayload()
        let text = CapabilitiesCommand.plainTextSummary(payload)
        let lines = text.components(separatedBy: "\n")
        #expect(lines.filter { $0 == "agent skill:" }.count == 1)
        let exitCodesIndex = try #require(lines.firstIndex(of: "exit codes:"))
        let skillIndex = try #require(lines.firstIndex(of: "agent skill:"))
        #expect(skillIndex > exitCodesIndex)
        #expect(lines.suffix(from: skillIndex).elementsEqual(CapabilitiesCommand.skillInstallLines()))
    }

    @Test func plainTextSummaryNeverLeaksIntoTheJSONPayloadShape() throws {
        // Structural guarantee, not a substring check: `--json` encodes
        // `CapabilitiesPayload` directly (see `run()`), which has no field
        // this text could occupy — `payloadJSONTopLevelKeysAreStable` above
        // already pins the exact key set. This test pins the companion half:
        // the plain-text renderer is a pure function of the payload with no
        // side channel back into it.
        let payload = CapabilitiesCommand.buildPayload()
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("agent skill"))
        #expect(!json.contains("git clone"))
    }
}
