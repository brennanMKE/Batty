// CapabilitiesCommand.swift

import ArgumentParser
import BattyXPCCore
import Foundation

/// Conformance point for a leaf `ParsableCommand` to describe its own
/// parameters as an MCP-shaped `inputSchema` (#0402). Every leaf command in
/// `BattyCLI`'s tree conforms — `CapabilitiesInputSchemaTests
/// .everyLeafCommandConformsToCapabilitiesDescribable` walks the same tree
/// `collectVerbs` below does and fails if a future leaf command omits this,
/// preserving #0384's "cannot silently go unreported" property for
/// parameters, not only for the verb roster itself.
///
/// **Hand-authored per command, not derived from ArgumentParser's own
/// argument metadata.** ArgumentParser's real reflection (the machinery
/// behind its hidden `--experimental-dump-help`, `DumpHelpGenerator`/
/// `ToolInfoV0(commandStack:)`) lives entirely inside the `ArgumentParser`
/// module and is not `public` — nothing outside that module, including this
/// file, can call it. This is candidate 3 from #0402's filing ("hand-authored
/// JSON Schema per verb, drift-gated by test"), not candidate 1: what keeps
/// each conformance honest is `CapabilitiesInputSchemaTests`' Mirror-based
/// drift oracle (built via each command's own `.parse(_:)`, using only
/// public `Mirror` reflection, no ArgumentParser internals), which fails if
/// a command's stored properties and its schema diverge — not a compiler
/// guarantee that the two can never diverge in content, only in count and
/// name. Round-1 review's B1 finding (a `direction` property whose declared
/// `cliKind`/`type`/`enum` combination described a `--direction` flag that
/// does not exist) is exactly the gap that leaves open: the drift oracle
/// catches a missing/extra *property*, not a wrong *shape* for one that
/// exists.
protocol CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload { get }
}

/// `batty capabilities` — a static, compiled-in description of this build's
/// verb roster and exit-code vocabulary (#0384), so an agent facing an
/// installed `batty` can discover what it supports instead of guessing or
/// tripping a verb to see if it errors.
///
/// **Pinned decision (#0384): no XPC round trip.** The CLI and the app ship
/// in the same bundle, so the CLI already knows its own surface at compile
/// time; asking the app would add a failure mode (broker unreachable) to a
/// command whose entire job is to work *before* anything else is known to.
/// This must succeed with exit `0` even when Batty is not running at all —
/// the opposite of `status`, whose job is reporting whether the app answers.
struct CapabilitiesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "Report the verbs and exit-code vocabulary this batty build supports."
    )

    @Flag(name: .long, help: "Emit JSON instead of a plain-text summary.")
    var json = false

    nonisolated func run() throws {
        let payload = Self.buildPayload()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) else {
                fputs("batty: failed to encode capabilities as JSON\n", stderr)
                throw ExitCode.failure
            }
            print(text)
        } else {
            Self.printPlainText(payload)
        }
    }

    /// The JSON Schema dialect every verb's `inputSchema` follows (#0402),
    /// matching MCP's own default.
    static let jsonSchemaDialect = "https://json-schema.org/draft/2020-12/schema"

    static func buildPayload() -> CapabilitiesPayload {
        CapabilitiesPayload(
            cliVersion: resolveAppVersion(),
            verbs: Self.verbs(),
            exitCodes: CapabilitiesPayload.standardExitCodes(
                success: ExitCode.success.rawValue,
                failure: ExitCode.failure.rawValue,
                validationFailure: ExitCode.validationFailure.rawValue
            ),
            jsonSchemaDialect: Self.jsonSchemaDialect
        )
    }

    /// Walks `BattyCLI`'s own subcommand tree rather than hand-listing verb
    /// names, so a verb wired into `BattyCLI.configuration.subcommands`
    /// later is reported automatically — the pinned decision in #0384: "a
    /// verb added later cannot silently go unreported." A noun with
    /// children (`session`, `pane`, `tab`) is never itself directly
    /// invocable, so only its leaves are reported (`session info`,
    /// `session focus`, `session close`, `pane split`, `pane close`, `pane
    /// focus`, `pane hide`, `pane show`, `tab focus`, `project list` and
    /// `project open`), joined with the noun
    /// as `"pane split"`. `XPCVerb.watch` is
    /// correctly absent from this list: it has no entry anywhere in
    /// `BattyCLI`'s tree because #0145 never gave it a CLI command.
    static func verbs() -> [CapabilitiesVerbPayload] {
        BattyCLI.configuration.subcommands.flatMap { collectVerbs(from: $0, prefix: []) }
    }

    private static func collectVerbs(from type: ParsableCommand.Type, prefix: [String]) -> [CapabilitiesVerbPayload] {
        let config = type.configuration
        let name = config.commandName ?? String(describing: type)
        let path = prefix + [name]
        guard !config.subcommands.isEmpty else {
            let verbPath = path.joined(separator: " ")
            return [CapabilitiesVerbPayload(
                name: verbPath,
                abstract: config.abstract,
                aliases: config.aliases,
                inputSchema: (type as? CapabilitiesDescribable.Type)?.capabilitiesInputSchema ?? .empty,
                annotations: Self.annotations(forVerbPath: verbPath)
            )]
        }
        return config.subcommands.flatMap { collectVerbs(from: $0, prefix: path) }
    }

    /// Batty's CLI grammar deliberately reuses a small, closed vocabulary of
    /// leaf verb *archetypes* across nouns (#0257's terminology amendment):
    /// every `focus` verb is activating and idempotent (`PaneFocusCommand`,
    /// `SessionFocusCommand`, `TabFocusCommand`'s own doc comments), every
    /// `hide`/`show` is idempotent (`PaneHideCommand`/`PaneShowCommand`'s
    /// "Idempotent" doc comments), every `close` fails rather than
    /// succeeding quietly on a stale/repeated id (`PaneCloseCommand`
    /// /`SessionCloseCommand`). `annotationsByArchetype` classifies that
    /// vocabulary once, keyed by archetype name, not by full verb path — but
    /// **membership in an archetype is an explicit per-verb-path opt-in**
    /// (`leafArchetypeByVerbPath` below), not an automatic match on a leaf's
    /// own `commandName`. Round-1 review demonstrated why the distinction
    /// matters: with a leaf-name-keyed table, adding a *new* `close` under a
    /// noun that never had one (e.g. a hypothetical `tab close`) would
    /// silently inherit `"close"`'s `destructiveHint: true` with every
    /// existing test green, because the old coverage test compared key
    /// *sets* — a new verb path with the same trailing word as an existing
    /// key was indistinguishable from an already-covered one. Keying the
    /// coverage table by full verb path instead means a new `tab close`
    /// is simply an unrecognized key until someone deliberately opts it in.
    ///
    /// **What is and isn't "derived" here, stated plainly:** coverage is —
    /// `CapabilitiesInputSchemaTests
    /// .leafArchetypeByVerbPathCoversExactlyTheShippedVerbPaths` walks
    /// `BattyCLI`'s own tree the same way `collectVerbs` does (joining each
    /// leaf's full path exactly as `collectVerbs` does) and fails if
    /// `leafArchetypeByVerbPath`'s keys and the shipped verb paths ever
    /// diverge in either direction, so a new verb (or a renamed one) cannot
    /// silently go unclassified, leave a stale entry behind, or get
    /// auto-classified by a same-named neighbor. A second test asserts every
    /// archetype `leafArchetypeByVerbPath` points at actually exists in
    /// `annotationsByArchetype`. The *values* — which hint is true for
    /// "close" versus "focus" — are asserted to match this codebase's own
    /// documented behavior, not mechanically derived from source: Swift has
    /// no static signal for a function's side-effect class, and the four
    /// imperative conflicts in `PaneCommand.swift` (#0402's Gap 2) are the
    /// standing proof that this codebase's semantics are not all reachable
    /// by reflection.
    ///
    /// Not `private`: `CapabilitiesInputSchemaTests`, in a different file of
    /// this same target, needs to read these directly to check coverage.
    static let annotationsByArchetype: [String: CapabilitiesAnnotationsPayload] = [
        "new": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false),
        "ping": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
        "status": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
        "list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
        "info": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
        "focus": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false),
        // Activating like `focus`, but worst-case non-idempotent: with
        // `--new` every call opens another Session.
        "open": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false),
        "close": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
        // Worst-case default: `pane split` is only idempotent with
        // `--unique` against a non-terminal `--view` (#0383) — the static
        // per-verb hint reflects its behavior without that flag, per MCP's
        // own "hints ... with worst-case defaults" guidance. See this
        // verb's `inputSchema.conflicts` for the `--unique` requirement
        // itself.
        "split": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false),
        "hide": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false),
        "show": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false),
        "id": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
        "notify": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false),
        "capabilities": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
    ]

    /// The explicit per-verb-path opt-in into `annotationsByArchetype` — see
    /// that property's doc comment for why this indirection exists rather
    /// than keying directly by leaf name.
    static let leafArchetypeByVerbPath: [String: String] = [
        "new": "new",
        "ping": "ping",
        "status": "status",
        "list": "list",
        "session info": "info",
        "session focus": "focus",
        "session close": "close",
        "pane split": "split",
        "pane close": "close",
        "pane focus": "focus",
        "pane hide": "hide",
        "pane show": "show",
        "tab focus": "focus",
        "project list": "list",
        "project open": "open",
        "id": "id",
        "notify": "notify",
        "capabilities": "capabilities",
    ]

    static func annotations(forVerbPath verbPath: String) -> CapabilitiesAnnotationsPayload {
        guard let archetype = leafArchetypeByVerbPath[verbPath] else { return .worstCaseDefault }
        return annotationsByArchetype[archetype] ?? .worstCaseDefault
    }

    private static func printPlainText(_ payload: CapabilitiesPayload) {
        print(Self.plainTextSummary(payload))
    }

    /// The human-readable `capabilities` body, including the agent-skill
    /// install pointer (#0403). Split out from `run()` so it's a pure
    /// function of a payload — testable without capturing real stdout —
    /// and kept entirely off the `--json` path: `run()`'s two branches
    /// (`JSONEncoder` here, this string there) never share output, so the
    /// skill pointer text structurally cannot leak into `--json`'s stdout
    /// (also asserted by `CapabilitiesCommandTests
    /// .payloadJSONTopLevelKeysAreStable`'s exact key-set check).
    static func plainTextSummary(_ payload: CapabilitiesPayload) -> String {
        var lines: [String] = []
        lines.append("batty \(payload.cliVersion) capabilities")
        lines.append("verbs:")
        for verb in payload.verbs {
            let aliasText = verb.aliases.isEmpty ? "" : " (alias: \(verb.aliases.joined(separator: ", ")))"
            lines.append("  \(verb.name)\(aliasText) — \(verb.abstract)")
        }
        lines.append("exit codes:")
        for exitCode in payload.exitCodes {
            lines.append("  \(exitCode.code) — \(exitCode.meaning)")
        }
        lines.append("")
        lines.append(contentsOf: Self.skillInstallLines(cliVersion: payload.cliVersion))
        return lines.joined(separator: "\n")
    }

    /// The GitHub repository the agent skill (`.claude/skills/batty-cli/`,
    /// #0403) is authored in and tagged from. Matches `issues/project.json`
    /// and `scripts/tag-release.sh`'s `v<MARKETING_VERSION>` tagging, so a
    /// tag named from this build's own `cliVersion` names the exact commit
    /// that shipped it — no registry, no "latest" ambiguity.
    static let skillRepositoryURL = "https://github.com/brennanMKE/Batty.git"
    static let skillRepositoryRelativePath = ".claude/skills/batty-cli"

    /// #0403/#0404: point a human/agent reading plain-text `capabilities` at
    /// the installable skill and how to fetch the copy tagged from this
    /// exact build — human-readable output only, never the `--json` path
    /// (#0384 pinned JSON-stdout purity for that path). `cliVersion ==
    /// "unknown"` (a bare SwiftPM-built binary, `SessionCommand.swift`'s
    /// `resolveAppVersion()`) is not a real release tag, so this
    /// deliberately does not fabricate a `--branch vunknown` clone that
    /// would fail — it points at the tag list instead.
    ///
    /// **#0404: this only clones and hands off, it does not install
    /// anything itself.** The skill folder ships its own multi-host
    /// installer (`install.sh`, next to `SKILL.md`) that detects Claude
    /// Code, Cursor, OpenCode, and Codex and applies the stage-to-`.new`/
    /// verify-`SKILL.md`/swap discipline (round-1 review B1, round-2 review
    /// B2 on this file, before that discipline moved into the script) once
    /// per destination — see `install.sh`'s own header comment for the full
    /// per-host rationale and non-destructive guarantee. Before #0404 this
    /// function embedded that whole recipe inline, hardcoded to
    /// `~/.claude/skills` alone; every other host got nothing (#0404's
    /// filing). Two failure points are still checked here, before handing
    /// off: the `git clone` itself can fail (network, or a tag that doesn't
    /// exist), and a tag can predate the installer entirely (any tag before
    /// #0404, checked by requiring `install.sh` to exist and be executable
    /// in the clone, not just the skill directory) — both leave the
    /// existing install(s) untouched, exactly as `install.sh` itself does
    /// for the destinations it manages.
    static func skillInstallLines(cliVersion: String) -> [String] {
        var lines = [
            "agent skill:",
            "  Portable skill teaching agents to drive this CLI — installs for Claude Code,",
            "  Cursor, OpenCode, and Codex: \(Self.skillRepositoryRelativePath)",
        ]
        if cliVersion == "unknown" {
            lines.append("  Could not determine this build's version (\"unknown\") — this binary was")
            lines.append("  likely built standalone via `swift build`, outside an app bundle, so there")
            lines.append("  is no tag to install from automatically. Run `batty status --json` from an")
            lines.append("  installed, running Batty for its status.appVersion, then pick the matching tag:")
            lines.append("    \(Self.skillRepositoryURL) (tags)")
            lines.append("  Each tagged skill folder carries its own multi-host installer")
            lines.append("  (\(Self.skillRepositoryRelativePath)/install.sh) — clone the tag and run it.")
        } else {
            lines.append("  Install/refresh for every detected agent host from this build's own tagged")
            lines.append("  release — the skill folder carries its own installer, so nothing extra to")
            lines.append("  download:")
            lines.append("    tmp=$(mktemp -d)")
            lines.append("    if ! git clone --quiet --depth 1 --branch v\(cliVersion) \(Self.skillRepositoryURL) \"$tmp\"; then")
            lines.append("      echo \"clone of v\(cliVersion) failed (network error, or the tag doesn't exist) — existing copy left untouched\" >&2")
            lines.append("    elif [ ! -x \"$tmp/\(Self.skillRepositoryRelativePath)/install.sh\" ]; then")
            lines.append("      echo \"tag v\(cliVersion) has no agent-skill installer (added in #0404) — existing copy left untouched\" >&2")
            lines.append("    else")
            lines.append("      \"$tmp/\(Self.skillRepositoryRelativePath)/install.sh\"   # add --project DIR / --dry-run as needed")
            lines.append("    fi")
            lines.append("    rm -rf \"$tmp\"")
        }
        return lines
    }
}

extension CapabilitiesCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON instead of a plain-text summary.", required: false, defaultValue: "false"),
        ])
    }
}
