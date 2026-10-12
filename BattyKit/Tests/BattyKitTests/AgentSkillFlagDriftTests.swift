// AgentSkillFlagDriftTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import batty

/// #0403 round-1 review N1: a drift check between the installable agent
/// skill (`.claude/skills/batty-cli/SKILL.md`) and `capabilities --json`'s
/// per-verb `inputSchema` (#0402) — the machine-checkable half of "the doc
/// wins on disagreement." This does not catch every possible drift (a flag
/// that exists but is used with the wrong *semantics*, like round-1's B2
/// `--tab`-given-a-Pane-id bug, is invisible to a pure existence check), but
/// it turns a flag rename or removal into a red `./build.sh unit` instead of
/// silent staleness — exactly the failure mode #0403 exists to close.
struct AgentSkillFlagDriftTests {

    private static func skillMarkdown() throws -> String {
        // #filePath: .../BattyKit/Tests/BattyKitTests/AgentSkillFlagDriftTests.swift
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // -> BattyKitTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> BattyKit/
            .deletingLastPathComponent() // -> repo root
            .appending(path: ".claude/skills/batty-cli/SKILL.md", directoryHint: .notDirectory)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every CLI spelling this verb actually accepts today: `names` plus
    /// every per-value spelling in `enumValueNames` (e.g. `direction`'s
    /// `-h`/`--horizontal`/`-v`/`--vertical`, which have no entry in `names`
    /// — see `CapabilitiesPropertyPayload.enumValueNames`'s doc comment).
    private static func knownFlagsByVerb() -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for verb in CapabilitiesCommand.verbs(flags: FeatureFlags(projects: true)) {
            var flags: Set<String> = []
            for property in verb.inputSchema.properties.values {
                flags.formUnion(property.names)
                if let enumValueNames = property.enumValueNames {
                    for spellings in enumValueNames.values {
                        flags.formUnion(spellings)
                    }
                }
            }
            result[verb.name] = flags
        }
        return result
    }

    /// Strips markdown decoration (brackets, surrounding punctuation, a
    /// trailing possessive `'s` left over from `` `--json`'s `` once
    /// backticks are stripped) a token can pick up from prose or a table
    /// cell — `` `--tab <tab-id>` `` and `[--tab <tab-id>]` should both read
    /// as `--tab`, not as un-matched noise this test silently ignores.
    private static func cleanToken<S: StringProtocol>(_ token: S) -> String {
        var cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "`'\"[](){}.,;:"))
        if cleaned.hasSuffix("'s") {
            cleaned = String(cleaned.dropLast(2))
        }
        return cleaned
    }

    /// Every `batty <verb> --flag` invocation the skill actually shows,
    /// paired with the flags used on it — split on each literal `batty `
    /// occurrence (after stripping backticks). A piece whose leading word(s)
    /// don't match any verb `capabilities` actually ships (a collapsed
    /// placeholder like `batty {session,pane,tab} focus`, the bare
    /// `batty <path>` shorthand, or a trailing word merged onto the *next*
    /// invocation — see below) is skipped — this test only checks what it
    /// can identify, not every line in the file. Tokens inside a
    /// double-quoted argument value (`--command "npm test -- --watch"`) are
    /// skipped entirely — quote-tracking runs on the raw, un-cleaned tokens
    /// so the quote marks survive long enough to be seen, since a real
    /// invocation like that one is deliberately demonstrating a `--` inside
    /// a *value*, not asserting `pane split` itself has a `--watch` flag.
    ///
    /// **Two known limitations (round-2 review N1, N3), neither triggered by
    /// SKILL.md as it stands today:**
    /// - Two `batty `-prefixed invocations packed onto one line with no
    ///   space between them (e.g. `` `batty ping`/`batty status` ``, once
    ///   backticks are stripped: `batty ping/batty status`) each end at the
    ///   *start* of the next match, so the first reads as `ping/` rather
    ///   than `ping` — harmless when neither invocation has a `--flag` to
    ///   check (as today), but a flag glued onto that boundary (e.g.
    ///   `` `batty pane split --unique`/`batty new --json` ``) would fail
    ///   this test with a misleading "unknown flag" rather than being
    ///   silently ignored, since the trailing slash defeats exact-string
    ///   matching. A drift check failing loudly on an edge case it can't
    ///   parse cleanly is the safe direction for this to fail in, but the
    ///   message would be confusing without this note.
    /// - Only `--`-prefixed (long) flags are recognized; a single-dash flag
    ///   (e.g. a hypothetical `pane split -x`) is invisible to this
    ///   extractor even though `knownFlagsByVerb` above is short-flag-aware
    ///   via `enumValueNames`. Latent, not live: SKILL.md uses no
    ///   single-dash flags as of this writing.
    private static func verbFlagPairs(in markdown: String) -> [(verb: String, flag: String)] {
        let knownVerbs = Set(CapabilitiesCommand.verbs(flags: FeatureFlags(projects: true)).map(\.name))
        // Round-1 review N4: recipes invoke `"$BATTY"` (resolved once in the
        // bootstrap to whichever of `batty`/`batty-beta` is installed), not
        // a hardcoded `batty` — normalize that back to the literal word so
        // the rest of this scan doesn't need a second marker.
        let text = markdown
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\"$BATTY\"", with: "batty")
        var pairs: [(verb: String, flag: String)] = []

        for line in text.components(separatedBy: "\n") {
            var searchRange = line.startIndex..<line.endIndex
            var matches: [Range<String.Index>] = []
            while let found = line.range(of: "batty ", range: searchRange) {
                matches.append(found)
                searchRange = found.upperBound..<line.endIndex
            }
            for (i, match) in matches.enumerated() {
                let start = match.upperBound
                // Round-2 review N3: end each piece at the *start* of the
                // next "batty " match, not one character before its own
                // *end* — the latter (the round-1 shape) folded the next
                // invocation's literal "batty" word into this piece.
                let end = i + 1 < matches.count ? matches[i + 1].lowerBound : line.endIndex
                let rawWords = line[start..<end].split(separator: " ")
                guard !rawWords.isEmpty else { continue }
                let cleanedWords = rawWords.map(cleanToken)
                let verb: String
                let argsStart: Int
                if cleanedWords.count >= 2, knownVerbs.contains(cleanedWords[0] + " " + cleanedWords[1]) {
                    verb = cleanedWords[0] + " " + cleanedWords[1]
                    argsStart = 2
                } else if knownVerbs.contains(cleanedWords[0]) {
                    verb = cleanedWords[0]
                    argsStart = 1
                } else {
                    continue
                }

                var inQuotes = false
                for rawWord in rawWords[argsStart...] {
                    if inQuotes {
                        if rawWord.hasSuffix("\"") { inQuotes = false }
                        continue
                    }
                    if rawWord.hasPrefix("\""), !rawWord.hasSuffix("\"") {
                        inQuotes = true
                        continue
                    }
                    if rawWord.hasPrefix("\"") {
                        continue // whole single-word quoted value, e.g. "dev" — not a flag
                    }
                    let flag = cleanToken(rawWord)
                    if flag.hasPrefix("--") {
                        pairs.append((verb: verb, flag: flag))
                    }
                }
            }
        }
        return pairs
    }

    // #0404: SKILL.md's refresh snippet no longer inlines the stage/verify/
    // swap discipline itself — round-1/round-2 review's B1/B2 findings on
    // that inline recipe are now enforced once, in `install.sh`, which every
    // destination shares (see AgentSkillInstallScriptTests). What SKILL.md's
    // own snippet still owns, and what drifting apart from
    // `CapabilitiesCommand.skillInstallLines`'s hand-off text would break,
    // is the *hand-off* itself: a clone failure is reported before a tag
    // that predates the installer is checked, which is reported before
    // `install.sh` is ever invoked, and the "unknown" version guard never
    // fabricates a `--branch vunknown` clone.
    @Test func refreshSnippetInSkillMarkdownHandsOffToInstallShWithoutFabricatingATag() throws {
        let markdown = try Self.skillMarkdown()
        let lines = markdown.components(separatedBy: "\n")

        let cloneFailureIndex = try #require(lines.firstIndex { $0.contains("clone of") && $0.contains("failed") })
        let predatesInstallerIndex = try #require(lines.firstIndex { $0.contains("has no agent-skill installer") })
        let invokeIndex = try #require(lines.firstIndex { $0.contains("install.sh") && $0.contains("$tmp/.claude/skills/batty-cli") && !$0.contains("[ !") })

        #expect(cloneFailureIndex < predatesInstallerIndex, "SKILL.md: a clone failure must be checked before a tag is judged to predate the installer")
        #expect(predatesInstallerIndex < invokeIndex, "SKILL.md: install.sh must not be invoked before confirming the clone actually has it")
        // Round-3 review N1: the previous version of this assertion
        // (`executableGuardLine.contains("-x")`) was tautological — the
        // `#require` that produced `executableGuardLine` already filtered
        // on `"[ ! -x"`, so this could never fail. Pinned to the exact
        // guard line instead, which actually exercises the specific
        // executable-bit check rather than restating how it was found.
        #expect(lines.contains(#"elif [ ! -x "$tmp/.claude/skills/batty-cli/install.sh" ]; then"#), "SKILL.md: the installer must be checked for its executable bit specifically, not merely that the path exists")
        #expect(!markdown.contains("--branch vunknown"), "SKILL.md: \"unknown\" must never be fabricated into a --branch argument")
    }

    @Test func everyFlagTheSkillShowsExistsOnItsVerbInCapabilities() throws {
        let markdown = try Self.skillMarkdown()
        let pairs = Self.verbFlagPairs(in: markdown)
        let knownFlags = Self.knownFlagsByVerb()

        // Guards against the extraction itself silently finding nothing —
        // a reformat of SKILL.md's code fences could make every real
        // assertion below pass vacuously with zero pairs checked.
        #expect(pairs.count >= 10, "expected to find at least 10 `batty <verb> --flag` invocations in SKILL.md, found \(pairs.count) — the extraction logic likely needs updating for a reformatted file")

        for pair in pairs {
            let flags = knownFlags[pair.verb] ?? []
            #expect(
                flags.contains(pair.flag),
                "SKILL.md invokes `\(pair.flag)` on `\(pair.verb)`, which capabilities --json's inputSchema does not list for that verb (known: \(flags.sorted()))"
            )
        }
    }

    /// Round-2 review N2: the raw `>= 10` count above has a thin margin —
    /// dropping the quotes around `"$BATTY"` (i.e. writing `$BATTY` instead)
    /// defeats the round-1 N4 normalization on its own and silently loses
    /// every pair sourced from the fenced recipes, leaving only a couple of
    /// inline-prose pairs to spare. A required subset — specific
    /// (verb, flag) pairs this skill's own recipes are built around —
    /// catches that regression by name instead of hoping the count still
    /// clears a shrinking margin.
    @Test func specificRecipeFlagsAreExtractedAtAll() throws {
        let markdown = try Self.skillMarkdown()
        let pairs = Set(Self.verbFlagPairs(in: markdown).map { "\($0.verb) \($0.flag)" })
        let required = [
            "pane split --unique",
            "pane split --command",
            "pane split --pane",
            "notify --title",
            "capabilities --json",
        ]
        for pair in required {
            #expect(pairs.contains(pair), "expected to find `\(pair)` among SKILL.md's extracted invocations — its absence likely means the \"$BATTY\" normalization (or the extraction itself) silently broke")
        }
    }
}
