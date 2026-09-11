// AgentSkillInstallScriptTests.swift

import Foundation
import Testing

/// #0404: `.claude/skills/batty-cli/install.sh` is the one place the
/// stage-to-`.new`/verify-`SKILL.md`/swap discipline now lives — before
/// #0404 that discipline was inlined per-destination in
/// `CapabilitiesCommand.skillInstallLines` and, separately, in SKILL.md's
/// own refresh snippet (round-1 review B1, round-2 review B2 on that
/// earlier shape). Moving it into a shared script means these invariants
/// are asserted once, against the actual script, rather than against two
/// independently hand-written copies of the same shell.
/// A minimal lock-protected byte buffer so a `Pipe`'s `readabilityHandler`
/// (invoked on a background queue by the OS) can safely accumulate output
/// without Swift's strict concurrency checking flagging a captured `var` as
/// unsafe — the `NSLock` actually does make this safe, but the compiler has
/// no way to verify that discipline from a bare closure capture alone.
nonisolated private final class LockedOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

struct AgentSkillInstallScriptTests {

    private static func installScript() throws -> String {
        // #filePath: .../BattyKit/Tests/BattyKitTests/AgentSkillInstallScriptTests.swift
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // -> BattyKitTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> BattyKit/
            .deletingLastPathComponent() // -> repo root
            .appending(path: ".claude/skills/batty-cli/install.sh", directoryHint: .notDirectory)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func installScriptPath() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: ".claude/skills/batty-cli/install.sh", directoryHint: .notDirectory)
            .path
    }

    @Test func installScriptIsExecutable() {
        #expect(FileManager.default.isExecutableFile(atPath: Self.installScriptPath()))
    }

    // The core non-destructive invariant (round-1 B1/round-2 B2 on the
    // pre-#0404 inline recipe, round-3 review B1/B3 on install.sh's first
    // shape): a stale `.new` from an interrupted prior run is cleared before
    // staging into it again; the stage/verify guard is pinned as an *exact*
    // line, not a substring match, because a substring check (`&&` +
    // "SKILL.md" both present) is defeated by a vacuous rewrite like
    // `[ -f ... ] || true` that still contains both substrings (round-3
    // review B3 mutation B); and the backup-or-remove step and the swap must
    // both come strictly *after* that guard, not before it — the guard line
    // itself is the dividing line, so this is a position check against the
    // guard's own index rather than a same-branch heuristic (round-3 review
    // B3 mutation A: hoisting the whole backup block above the guard).
    //
    // Round-4 review mutation F: a plausible refactor — inserting a
    // gratuitous "clean the destination first" `rm -rf "$dest"` before the
    // stage/verify guard — keeps all four pinned lines above in their
    // pinned relative order (nothing about the guard, the backup move, or
    // the swap moves), so the position checks alone don't catch it, even
    // though it reproduces the exact #0403 B1 harm this whole discipline
    // exists to prevent. Killed with a direct negative pin: the script must
    // never `rm -rf` the destination itself, only ever `$dest.new`.
    @Test func installFunctionStagesVerifiesThenSwapsWithoutEverLeavingNeitherCopy() throws {
        let script = try Self.installScript()
        let lines = script.components(separatedBy: "\n")

        let preClearIndex = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "rm -rf \"$dest.new\"" })
        let guardIndex = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "if cp -R \"$SCRIPT_DIR\" \"$dest.new\" && [ -f \"$dest.new/SKILL.md\" ]; then" })
        let backupMoveIndex = try #require(lines.firstIndex { $0.contains("mv -- \"$dest\" \"$backup\"") })
        let swapIndex = try #require(lines.firstIndex { $0.contains("mv \"$dest.new\" \"$dest\"") })

        #expect(preClearIndex < guardIndex, "install.sh: a stale .new from an interrupted prior run must be cleared before staging into it again")
        #expect(guardIndex < backupMoveIndex, "install.sh: the existing install must not be backed up/removed before a replacement is staged and verified")
        #expect(backupMoveIndex < swapIndex, "install.sh: the swap must follow the backup, not precede it")
        #expect(!script.contains("rm -rf \"$dest\"\n"), "install.sh: the script must never rm -rf the destination itself, only ever $dest.new — a gratuitous clean-first reproduces the #0403 B1 harm")
    }

    // A pre-existing install — symlink or not — must be preserved (backed
    // up outside the scanned skills root), not silently discarded. Round-3
    // review B1: a backup that lands as a *sibling inside* the skills root
    // (e.g. `$dest.backup.<ts>`) is itself a second `SKILL.md` the host can
    // discover and compete with the fresh install — every refresh across N
    // destinations would leave up to N stale duplicates behind. Round-3
    // review B2: replacing a symlink must be reported (with its target),
    // not silent, and both destructive `mv`s must be checked rather than
    // followed by an unconditional "installed" echo.
    @Test func existingInstallIsBackedUpOutsideTheScannedSkillsRootNotDiscarded() throws {
        let script = try Self.installScript()
        #expect(script.contains("mv -- \"$dest\" \"$backup\""), "install.sh: an existing install must be moved to a backup path, not removed outright")

        // The backup root must be computed from `parent`'s own parent (one
        // level above the "skills" directory itself), not as a `$dest`-
        // adjacent sibling — that positioning is what keeps it out of any
        // `<skills-root>/*/SKILL.md` scan.
        #expect(script.contains(#"backup_root="$(dirname "$parent")/batty-cli-skill-backups""#), "install.sh: the backup root must live outside the skills root ($parent), not inside it")
        #expect(!script.contains(#"backup="$dest.backup."#), "install.sh: a backup path must not be a same-directory sibling of $dest (the pre-round-3 defect)")

        // Both destructive moves are gated, and failure is reported rather
        // than silently swallowed into an unconditional success message.
        #expect(script.contains("if ! mv -- \"$dest\" \"$backup\"; then"), "install.sh: the backup move must be checked for failure — and its stderr must reach the user (round-4 review item 3), so no 2>/dev/null here")
        #expect(script.contains("if ! mv \"$dest.new\" \"$dest\"; then"), "install.sh: the swap must be checked for failure — and its stderr must reach the user, so no 2>/dev/null here either")

        // Replacing a symlink must be reported by name and target, not done
        // silently — the link is the user's configuration, not just bytes.
        #expect(script.contains(#"echo "  replacing existing symlink $dest -> $(readlink "$dest")""#), "install.sh: replacing a symlink must print its target")
    }

    // Round-3 review N3: the CLI's shorter printed recipe dropped "stage
    // incomplete" (it no longer stages anything itself — install.sh does),
    // but install.sh itself still has three distinct failure causes and
    // must keep reporting this one by name, not just the two the CLI text
    // still covers (clone failure, tag predates the installer).
    @Test func stageIncompleteIsReportedAsItsOwnDistinctFailure() throws {
        let script = try Self.installScript()
        #expect(script.contains("stage incomplete for $dest — existing copy left untouched"))
    }

    @Test func supportsProjectAndDryRunFlags() throws {
        let script = try Self.installScript()
        // Pinned to the actual `case` arms, not just prose mentioning the
        // flag names — a regression that drops the arm but leaves usage/
        // header comments untouched (stale docs, not stale behavior) must
        // still go red here.
        #expect(script.contains("--project)"), "no case arm recognizes --project")
        #expect(script.contains("--dry-run) DRY_RUN=1"), "no case arm sets DRY_RUN when --dry-run is passed")
        #expect(script.contains("if [ \"$DRY_RUN\" = \"1\" ]"), "DRY_RUN is set but nothing reads it back")
    }

    // #0404's whole point: every detected host gets a destination, not just
    // Claude Code's. This does not assert the *paths* are correct in the
    // sense of "Claude Code will actually read this" (untestable without a
    // live host, see the issue's Gotchas) — only that the script's own
    // design covers the hosts the issue names, so a future edit that
    // silently drops one of them (e.g. refactoring the OpenCode block away)
    // fails a test instead of shipping unnoticed.
    //
    // Round-3 review B4: matching against the *whole file* is vacuous — the
    // header comment names every host too, so deleting the actual
    // `install_into` call for a host (even all of them) while leaving the
    // prose describing it untouched left this green. Matched here against
    // the exact `try_install "..."` call-site text instead (the wrapper
    // every destination is invoked through, added in round 4 for N9 — see
    // partialDestinationFailureExitsNonZero below), which only
    // exists in code, never in a `#`-prefixed comment line.
    @Test func targetsEveryNamedHostDirectory() throws {
        let script = try Self.installScript()
        #expect(script.contains(#"try_install "$HOME/.claude/skills/batty-cli""#), "Claude Code")
        #expect(script.contains(#"try_install "$OPENCODE_DIR/skills/batty-cli""#), "OpenCode")
        #expect(script.contains(#"try_install "$HOME/.cursor/skills/batty-cli""#), "Cursor")
        #expect(script.contains(#"try_install "$CODEX_HOME_DIR/skills/batty-cli""#), "Codex's own directory")
        #expect(script.contains(#"try_install "$HOME/.agents/skills/batty-cli""#), "the cross-tool .agents/skills convention Codex documents natively and Cursor/OpenCode read as a fallback")
        #expect(script.contains(#"try_install "$PROJECT_DIR/.claude/skills/batty-cli""#), "project-scoped Claude Code")
        #expect(script.contains(#"try_install "$PROJECT_DIR/.cursor/skills/batty-cli""#), "project-scoped Cursor")
        #expect(script.contains(#"try_install "$PROJECT_DIR/.agents/skills/batty-cli""#), "project-scoped .agents/skills")
    }

    // Installing a project-scoped copy into the very directory that already
    // holds the canonical skill (e.g. running install.sh --project . from
    // inside this repo) must not remove-then-recreate the file the running
    // script itself was read from.
    //
    // Round-3 review N2: pinning only the message string leaves the actual
    // comparison unpinned — rewriting it to naive string equality (`"$dest"
    // = "$SCRIPT_DIR"`, which breaks the moment `$dest` isn't already an
    // absolute, symlink-free path spelled identically to `$SCRIPT_DIR`)
    // would keep this test green while making the check far weaker. Pinned
    // against the actual `real_path`-based comparison instead.
    @Test func skipsInstallingOverItsOwnCanonicalLocation() throws {
        let script = try Self.installScript()
        #expect(script.contains("already the canonical copy"))
        #expect(script.contains(#"[ "$(real_path "$dest")" = "$(real_path "$SCRIPT_DIR")" ]"#), "install.sh: the canonical-copy check must resolve both sides through real_path, not compare raw strings")
    }

    // Round-4 review N9: a partial failure across install.sh's destinations
    // used to still exit 0 ("Done.") as long as *something* succeeded — an
    // agent following SKILL.md's or capabilities' printed instructions
    // checks $? once, not each destination's own output line, so this was
    // the #0383 skew arriving through the exit code instead of a stale
    // flag. Unlike every other test in this file, this one actually
    // *executes* install.sh (not just inspects its text) against a scratch
    // temporary directory used as $HOME — never a real one, per the hard
    // constraint on this issue — with one destination's skills directory
    // made read-only so staging fails there while the unconditional
    // cross-tool `~/.agents/skills` destination still succeeds, confirming
    // both the non-zero exit and the "N of M destinations failed" summary.
    //
    // Round-5 review item 1: the Claude Code destination used to be
    // reached only via `have claude` on $PATH (the test never created
    // `fakeHome/.claude` itself), so on a machine/CI runner with no Claude
    // Code installed the baseline run would create only the unconditional
    // `~/.agents/skills` destination, `claudeSkillMD` would never exist,
    // and `String(contentsOf:)` would throw — a purely environmental
    // failure indistinguishable from a real regression. `fakeHome/.claude`
    // is now created explicitly before the baseline run so detection does
    // not depend on $PATH at all, and an explicit `fileExists` check gives
    // mutations H/I (an early `return 0`, or every global block wrapped in
    // `if false`) an attributable failure message instead of a raw
    // NSCocoaErrorDomain error that reads identically to the environmental
    // failure this fixes.
    @Test func partialDestinationFailureExitsNonZero() throws {
        let fileManager = FileManager.default
        let fakeHome = fileManager.temporaryDirectory
            .appendingPathComponent("AgentSkillInstallScriptTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fakeHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let claudeSkillsDir = fakeHome.appendingPathComponent(".claude/skills")
        defer {
            // Restore write permission before removal — a read-only
            // directory left behind by the forced-failure step would
            // otherwise survive cleanup and leak between test runs.
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeSkillsDir.path)
            try? fileManager.removeItem(at: fakeHome)
        }

        // Round-5 review item 2: `try? process.run()` let an unlaunched
        // `Process` reach `terminationStatus` (undefined behavior) on any
        // launch failure — now `throws` and propagates. And reading one
        // shared pipe only after `waitUntilExit()` is the standard deadlock
        // shape: if the child ever writes enough to fill the pipe's OS
        // buffer before exiting, it blocks on write() while nothing drains
        // the read end, so `waitUntilExit()` never returns. Harmless at
        // this script's ~1 KB of output today, but fixed properly: a
        // `readabilityHandler` installed before the process starts drains
        // the pipe continuously as data arrives, regardless of volume.
        func runInstaller() throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["bash", Self.installScriptPath()]
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = fakeHome.path
            environment.removeValue(forKey: "XDG_CONFIG_HOME")
            environment.removeValue(forKey: "CODEX_HOME")
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let buffer = LockedOutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                buffer.append(chunk)
            }

            try process.run()
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            // Anything delivered between the handler's last callback and exit.
            buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())

            return (process.terminationStatus, String(data: buffer.snapshot(), encoding: .utf8) ?? "")
        }

        // Baseline install (must succeed cleanly), then make the Claude
        // Code copy stale — so the diff -rq no-op short-circuit doesn't
        // skip it before staging is even attempted — and lock its skills
        // directory read-only so `cp -R ... .new` fails there specifically.
        let baseline = try runInstaller()
        #expect(baseline.status == 0, "baseline install into an empty scratch HOME must succeed")

        let claudeSkillMD = fakeHome.appendingPathComponent(".claude/skills/batty-cli/SKILL.md")
        #expect(fileManager.fileExists(atPath: claudeSkillMD.path), "baseline install must have created the Claude Code copy")
        let existing = try String(contentsOf: claudeSkillMD, encoding: .utf8)
        try (existing + "\nstale\n").write(to: claudeSkillMD, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: claudeSkillsDir.path)

        let (status, output) = try runInstaller()
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeSkillsDir.path)

        #expect(status != 0, "install.sh: a partial destination failure must exit non-zero, not report overall success")
        #expect(output.contains("destinations failed"), "install.sh: a partial failure must print a summary naming how many destinations failed")
    }
}
