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

    // MARK: - Agent skill install pointer (#0403)

    @Test func skillInstallLinesForAKnownVersionCloneTheMatchingTag() {
        let lines = CapabilitiesCommand.skillInstallLines(cliVersion: "1.1.0")
        #expect(lines == [
            "agent skill:",
            "  Claude Code skill teaching agents to drive this CLI: .claude/skills/batty-cli",
            "  Install/refresh it from this build's own tagged release (each failure",
            "  point below is checked separately and leaves the existing copy untouched):",
            "    tmp=$(mktemp -d)",
            "    if ! git clone --quiet --depth 1 --branch v1.1.0 https://github.com/brennanMKE/Batty.git \"$tmp\"; then",
            "      echo \"clone of v1.1.0 failed (network error, or the tag doesn't exist) — existing copy left untouched\" >&2",
            "    elif [ ! -d \"$tmp/.claude/skills/batty-cli\" ]; then",
            "      echo \"tag v1.1.0 has no .claude/skills/batty-cli (predates #0403) — not installing, existing copy left untouched\" >&2",
            "    else",
            "      mkdir -p ~/.claude/skills",
            "      rm -rf ~/.claude/skills/batty-cli.new",
            "      if cp -R \"$tmp/.claude/skills/batty-cli\" ~/.claude/skills/batty-cli.new && [ -f ~/.claude/skills/batty-cli.new/SKILL.md ]; then",
            "        rm -rf ~/.claude/skills/batty-cli",
            "        mv ~/.claude/skills/batty-cli.new ~/.claude/skills/batty-cli",
            "      else",
            "        echo \"stage incomplete — existing copy left untouched\" >&2",
            "        rm -rf ~/.claude/skills/batty-cli.new",
            "      fi",
            "    fi",
            "    rm -rf \"$tmp\"",
        ])
    }

    // #0403 round-1 review B1: the destination is never removed before the
    // staged copy is confirmed present under `.new`, and the swap always
    // happens via `mv` from that staged path — never a bare `cp` over an
    // existing install. A regression here (e.g. reordering `rm -rf` before
    // the `if` guard) would delete a user's skill with nothing to replace it
    // whenever a tag exists but predates the skill (`v1.1.0` does, today).
    @Test func skillInstallLinesNeverRemoveTheExistingInstallBeforeStagingTheReplacement() throws {
        let lines = CapabilitiesCommand.skillInstallLines(cliVersion: "1.1.0")
        let removeIndex = try #require(lines.firstIndex { $0.contains("rm -rf ~/.claude/skills/batty-cli") && !$0.contains(".new") })
        let stageIndex = try #require(lines.firstIndex { $0.contains("cp -R") && $0.contains("batty-cli.new") })
        let swapIndex = try #require(lines.firstIndex { $0.contains("mv ") && $0.contains("batty-cli.new") })
        #expect(stageIndex < removeIndex)
        #expect(removeIndex < swapIndex)
    }

    // #0403 round-2 review B2: verifying only the *source* tag had the
    // skill (the `[ -d "$tmp/..." ]` check) was not enough — a failed or
    // partial `cp -R` into the `.new` stage still let the destructive
    // `rm -rf` proceed. The swap must be gated on the *staged copy* itself
    // (`.new/SKILL.md` actually existing), joined to the `cp -R` by `&&` so
    // a failed copy short-circuits before anything destructive runs.
    @Test func skillInstallLinesGateTheSwapOnTheStagedCopyActuallyContainingSKILLMD() throws {
        let lines = CapabilitiesCommand.skillInstallLines(cliVersion: "1.1.0")
        let guardLine = try #require(lines.first { $0.contains("cp -R") && $0.contains("batty-cli.new") })
        #expect(guardLine.contains("&&"), "staging and verifying the stage must be one atomic condition")
        #expect(guardLine.contains("batty-cli.new/SKILL.md"), "checking the source directory alone (round-2 B2) is not enough — must check the staged copy")
    }

    // #0403 round-2 review B2: BSD `cp -R src dest` copies *into* an
    // existing `dest` directory rather than replacing it, so a `.new` left
    // behind by a prior run interrupted between `cp` and `mv` must be
    // cleared before staging into it again, or the result nests one level
    // too deep (`batty-cli.new/batty-cli/SKILL.md`) and the swap installs a
    // directory with no `SKILL.md` where Claude Code expects one.
    @Test func skillInstallLinesClearAnyStaleStageBeforeCopyingIntoIt() throws {
        let lines = CapabilitiesCommand.skillInstallLines(cliVersion: "1.1.0")
        let preClearIndex = try #require(lines.firstIndex { $0.contains("rm -rf") && $0.contains("batty-cli.new") })
        let stageIndex = try #require(lines.firstIndex { $0.contains("cp -R") && $0.contains("batty-cli.new") })
        #expect(preClearIndex < stageIndex)
    }

    // #0403 round-2 review B2/N6: a clone failure, a tag missing the skill,
    // and a failed/partial stage are three distinct causes and must report
    // distinct messages — a clone failure was previously misattributed to
    // "predates #0403", which would mislead anyone debugging a network
    // error or typo'd version as if the tag were simply old.
    @Test func skillInstallLinesReportEachFailureCauseWithADistinctMessage() {
        let text = CapabilitiesCommand.skillInstallLines(cliVersion: "1.1.0").joined(separator: "\n")
        #expect(text.contains("clone of v1.1.0 failed (network error, or the tag doesn't exist)"))
        #expect(text.contains("has no .claude/skills/batty-cli (predates #0403)"))
        #expect(text.contains("stage incomplete"))
    }

    @Test func skillInstallLinesForAnUnknownVersionNeverFabricateATag() {
        // "unknown" (a bare SwiftPM-built binary, SessionCommand.swift's
        // resolveAppVersion()) is not a real git tag — `--branch vunknown`
        // would just fail. This must fall back to pointing at the tag list,
        // never interpolate the literal string "unknown" into a `--branch`.
        let lines = CapabilitiesCommand.skillInstallLines(cliVersion: "unknown")
        #expect(lines == [
            "agent skill:",
            "  Claude Code skill teaching agents to drive this CLI: .claude/skills/batty-cli",
            "  Could not determine this build's version (\"unknown\") — this binary was",
            "  likely built standalone via `swift build`, outside an app bundle, so there",
            "  is no tag to install from automatically. Run `batty status --json` from an",
            "  installed, running Batty for its status.appVersion, then pick the matching tag:",
            "    https://github.com/brennanMKE/Batty.git (tags)",
        ])
        #expect(!lines.contains { $0.contains("--branch") })
        #expect(!lines.contains { $0.contains("vunknown") })
    }

    @Test func plainTextSummaryAppendsTheSkillBlockExactlyOnceAfterExitCodes() throws {
        let payload = CapabilitiesCommand.buildPayload()
        let text = CapabilitiesCommand.plainTextSummary(payload)
        let lines = text.components(separatedBy: "\n")
        #expect(lines.filter { $0 == "agent skill:" }.count == 1)
        let exitCodesIndex = try #require(lines.firstIndex(of: "exit codes:"))
        let skillIndex = try #require(lines.firstIndex(of: "agent skill:"))
        #expect(skillIndex > exitCodesIndex)
        #expect(lines.suffix(from: skillIndex).elementsEqual(CapabilitiesCommand.skillInstallLines(cliVersion: payload.cliVersion)))
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
