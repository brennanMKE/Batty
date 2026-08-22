// GitStatusPorcelainParserTests.swift

import Testing
@testable import BattyKit

/// Joins fixture "lines" with NUL (`\0`), matching real `-z` output — see
/// `GitStatusPorcelainParser`'s own doc comment for why `-z` (not plain
/// newline-terminated porcelain v2) is what this parser actually consumes.
/// A rename/copy record's `origPath` is its own separate array element,
/// mirroring the two separate NUL-terminated tokens git actually emits for
/// it (no embedded tab — that was the pre-review-round-1 shape).
private func nulJoined(_ tokens: String...) -> String {
    tokens.joined(separator: "\u{0}")
}

/// Fixtures below are not hand-guessed against the man page — they were
/// captured directly from real `git status --porcelain=v2 --branch
/// --show-stash -z` output (git 2.50.1, via `od -c`) while writing
/// `GitStatusPorcelainParser`, including a **real** (not literal-backslash)
/// non-ASCII filename, a path containing a space, and a path containing a
/// literal `"` — review round 1's B1 finding was that an earlier,
/// non-`-z` version of this parser took the *C-quoted, escaped* text of
/// such paths literally (`"caf\303\251.txt"`, escapes and all); these
/// fixtures exist specifically to guard against that regression, not just
/// to restate the field layout. See `docs/design/git-status-view.md` §4
/// and #0304's `## Verification`.
@MainActor
struct GitStatusPorcelainParserTests {

    @Test func cleanRepoWithNoUpstreamParsesBranchAndNothingElse() {
        let output = nulJoined(
            "# branch.oid 6d130667d3ab53021e0e180671b4abe6fedbffa5",
            "# branch.head main"
        )
        let result = GitStatusPorcelainParser.parse(output)
        #expect(result.branch == "main")
        #expect(result.isDetached == false)
        #expect(result.oid == "6d130667d3ab53021e0e180671b4abe6fedbffa5")
        #expect(result.ahead == 0)
        #expect(result.behind == 0)
        #expect(result.hasUpstream == false)
        #expect(result.stashCount == 0)
        #expect(result.staged.isEmpty)
        #expect(result.unstaged.isEmpty)
        #expect(result.untracked.isEmpty)
        #expect(result.conflicted.isEmpty)
    }

    @Test func detachedHeadReportsNoBranchName() {
        let output = nulJoined(
            "# branch.oid 022b020854b081e9a3380985ae7231628902b0d4",
            "# branch.head (detached)"
        )
        let result = GitStatusPorcelainParser.parse(output)
        #expect(result.branch == nil)
        #expect(result.isDetached)
        #expect(result.oid == "022b020854b081e9a3380985ae7231628902b0d4")
    }

    /// A repository with no commits yet reports `# branch.oid (initial)`,
    /// verified against a real `git init` + no-commit repo — a distinct
    /// case from detached HEAD, and not previously covered (review round
    /// 1, D4).
    @Test func noCommitsYetReportsInitialOid() {
        let output = nulJoined(
            "# branch.oid (initial)",
            "# branch.head main",
            "? f.txt"
        )
        let result = GitStatusPorcelainParser.parse(output)
        #expect(result.oid == "(initial)")
        #expect(result.branch == "main")
        #expect(result.isDetached == false)
        #expect(result.untracked == [GitStatusFileEntry(path: "f.txt", statusKind: .untracked)])
    }

    @Test func upstreamAheadBehindAndStashParseFromHeaderLines() {
        let output = nulJoined(
            "# branch.oid fb38fc8f7cf1d2ae97957456e88d901dc1c128ee",
            "# branch.head main2",
            "# branch.upstream origin/main2",
            "# branch.ab +2 -1",
            "# stash 1"
        )
        let result = GitStatusPorcelainParser.parse(output)
        #expect(result.hasUpstream)
        #expect(result.ahead == 2)
        #expect(result.behind == 1)
        #expect(result.stashCount == 1)
    }

    /// No `# stash` line at all (the common case — most scans have no
    /// stash) must not be confused with a stash count of zero being
    /// reported explicitly; both should read as zero, but this pins the
    /// absent-line path specifically (review round 1, D4).
    @Test func absentStashLineDefaultsToZero() {
        let output = nulJoined(
            "# branch.oid abc123",
            "# branch.head main"
        )
        let result = GitStatusPorcelainParser.parse(output)
        #expect(result.stashCount == 0)
    }

    @Test func ordinaryChangedEntrySplitsStagedAndUnstagedByColumn() {
        // "M." — staged modify only.
        let stagedOnly = nulJoined(
            "# branch.head main",
            "1 M. N... 100644 100644 100644 ce013625030ba8dba906f756967f9e9ca394464a dcae1e75f0092013d2b4773c5e07e79bf039cfae a.txt"
        )
        let stagedResult = GitStatusPorcelainParser.parse(stagedOnly)
        #expect(stagedResult.staged == [GitStatusFileEntry(path: "a.txt", statusKind: .modified)])
        #expect(stagedResult.unstaged.isEmpty)

        // ".M" — unstaged modify only.
        let unstagedOnly = nulJoined(
            "# branch.head main",
            "1 .M N... 100644 100644 100644 ce013625030ba8dba906f756967f9e9ca394464a dcae1e75f0092013d2b4773c5e07e79bf039cfae a.txt"
        )
        let unstagedResult = GitStatusPorcelainParser.parse(unstagedOnly)
        #expect(unstagedResult.unstaged == [GitStatusFileEntry(path: "a.txt", statusKind: .modified)])
        #expect(unstagedResult.staged.isEmpty)

        // "MM" — staged AND unstaged, same path, both modified.
        let both = nulJoined(
            "# branch.head main",
            "1 MM N... 100644 100644 100644 ce013625030ba8dba906f756967f9e9ca394464a dcae1e75f0092013d2b4773c5e07e79bf039cfae a.txt"
        )
        let bothResult = GitStatusPorcelainParser.parse(both)
        #expect(bothResult.staged == [GitStatusFileEntry(path: "a.txt", statusKind: .modified)])
        #expect(bothResult.unstaged == [GitStatusFileEntry(path: "a.txt", statusKind: .modified)])
    }

    @Test func addedAndDeletedCodesMapToTheirKinds() {
        let output = nulJoined(
            "# branch.head main",
            "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 dcae1e75f0092013d2b4773c5e07e79bf039cfae new.txt",
            "1 D. N... 100644 000000 000000 ce013625030ba8dba906f756967f9e9ca394464a 0000000000000000000000000000000000000000 gone.txt"
        )
        let result = GitStatusPorcelainParser.parse(output)
        #expect(result.staged == [
            GitStatusFileEntry(path: "new.txt", statusKind: .added),
            GitStatusFileEntry(path: "gone.txt", statusKind: .deleted),
        ])
    }

    /// A path with an embedded space is a literal, unescaped byte under
    /// `-z` — this is the exact case `splitFields`'s "last field is
    /// everything remaining" design exists for (review round 1, D4).
    @Test func ordinaryEntryPathContainingASpaceIsNotSplitFurther() {
        let output = nulJoined(
            "# branch.head main",
            "1 .M N... 100644 100644 100644 aaaa bbbb renamed with space.txt"
        )
        let result = GitStatusPorcelainParser.parse(output)
        #expect(result.unstaged == [GitStatusFileEntry(path: "renamed with space.txt", statusKind: .modified)])
    }

    /// A real (not literal-backslash) non-ASCII filename appears as raw
    /// UTF-8 bytes under `-z` — captured from an actual `café.txt` file
    /// (`printf` with real `\xc3\xa9` bytes, verified with `od -c`), not a
    /// filename that merely contains the text "\xc3\xa9" (review round 1,
    /// B1 — this is the exact regression a non-`-z`, C-quoting-unaware
    /// parser had: it rendered this path as the literal escaped text
    /// instead of the real, displayable filename).
    @Test func nonASCIIPathAppearsAsRawUTF8BytesUnderZ() {
        let output = nulJoined(
            "# branch.head main",
            "1 .M N... 100644 100644 100644 aaaa bbbb café.txt"
        )
        let result = GitStatusPorcelainParser.parse(output)
        #expect(result.unstaged == [GitStatusFileEntry(path: "café.txt", statusKind: .modified)])
        #expect(result.unstaged.first?.path.contains("\\") == false)
    }

    /// A path containing a literal double quote is likewise raw, unescaped
    /// text under `-z` — no C-quoting to strip, no escaped-quote sequence
    /// to unescape (review round 1, D4).
    @Test func pathContainingALiteralQuoteCharacterIsNotUnescaped() {
        let output = nulJoined(
            "# branch.head main",
            "1 .M N... 100644 100644 100644 aaaa bbbb quote\"file.txt"
        )
        let result = GitStatusPorcelainParser.parse(output)
        #expect(result.unstaged == [GitStatusFileEntry(path: "quote\"file.txt", statusKind: .modified)])
    }

    /// Rename/copy records are **two separate NUL-terminated tokens** under
    /// `-z` (`path`, then `origPath` alone) — not one token with an
    /// embedded tab, which was the pre-review-round-1 (non-`-z`) shape.
    @Test func renameEntrySplitsPathAndOrigPathAcrossTwoTokens() {
        let output = nulJoined(
            "# branch.head feature",
            "2 R. N... 100644 100644 100644 cc628ccd10742baea8241c5924df992b5c019f71 cc628ccd10742baea8241c5924df992b5c019f71 R100 c.txt",
            "b.txt"
        )
        let result = GitStatusPorcelainParser.parse(output)
        #expect(result.staged == [GitStatusFileEntry(path: "c.txt", origPath: "b.txt", statusKind: .renamed)])
        #expect(result.unstaged.isEmpty)
    }

    /// A rename whose new path itself contains a space — the origPath
    /// token boundary (NUL) is unambiguous regardless of what's inside
    /// either path (review round 1, D4).
    @Test func renameEntryWherePathContainsASpace() {
        let output = nulJoined(
            "# branch.head feature",
            "2 R. N... 100644 100644 100644 aaaa bbbb R100 renamed with space.txt",
            "quote_orig.txt"
        )
        let result = GitStatusPorcelainParser.parse(output)
        #expect(result.staged == [GitStatusFileEntry(path: "renamed with space.txt", origPath: "quote_orig.txt", statusKind: .renamed)])
    }

    @Test func untrackedEntryParsesBareStatusLine() {
        let output = nulJoined(
            "# branch.head feature",
            "? d.txt"
        )
        let result = GitStatusPorcelainParser.parse(output)
        #expect(result.untracked == [GitStatusFileEntry(path: "d.txt", statusKind: .untracked)])
    }

    @Test func unmergedEntryDuringAConflictParsesAsConflicted() {
        let output = nulJoined(
            "# branch.oid 022b020854b081e9a3380985ae7231628902b0d4",
            "# branch.head main2",
            "u UU N... 100644 100644 100644 100644 9e35a1c81996422d0d7950fd2a1f8af69b3e349a 223b7836fb19fdf64ba2d3cd6173c6a283141f78 f70f10e4db19068f79bc43844b49f3eece45c4e8 conflict.txt",
            "? d.txt"
        )
        let result = GitStatusPorcelainParser.parse(output)
        #expect(result.conflicted == [GitStatusFileEntry(path: "conflict.txt", statusKind: .unmerged)])
        #expect(result.untracked == [GitStatusFileEntry(path: "d.txt", statusKind: .untracked)])
        #expect(result.staged.isEmpty)
        #expect(result.unstaged.isEmpty)
    }

    @Test func realisticMixedOutputParsesEveryGroup() {
        // Captured verbatim (field-for-field) from a real repo while
        // writing this parser, re-expressed as NUL-joined tokens.
        let output = nulJoined(
            "# branch.oid 6d130667d3ab53021e0e180671b4abe6fedbffa5",
            "# branch.head feature",
            "# stash 1",
            "1 M. N... 100644 100644 100644 ce013625030ba8dba906f756967f9e9ca394464a dcae1e75f0092013d2b4773c5e07e79bf039cfae a.txt",
            "2 R. N... 100644 100644 100644 cc628ccd10742baea8241c5924df992b5c019f71 cc628ccd10742baea8241c5924df992b5c019f71 R100 c.txt",
            "b.txt",
            "? d.txt"
        )
        let result = GitStatusPorcelainParser.parse(output)
        #expect(result.branch == "feature")
        #expect(result.stashCount == 1)
        #expect(result.staged.count == 2)
        #expect(result.staged.contains(GitStatusFileEntry(path: "a.txt", statusKind: .modified)))
        #expect(result.staged.contains(GitStatusFileEntry(path: "c.txt", origPath: "b.txt", statusKind: .renamed)))
        #expect(result.untracked == [GitStatusFileEntry(path: "d.txt", statusKind: .untracked)])
    }

    @Test func emptyOutputParsesToAllEmptyDefaults() {
        let result = GitStatusPorcelainParser.parse("")
        #expect(result.branch == nil)
        #expect(result.isDetached == false)
        #expect(result.staged.isEmpty && result.unstaged.isEmpty && result.untracked.isEmpty && result.conflicted.isEmpty)
    }

    @Test func fileEntryBadgesMatchTheDesignedTwoLetterConvention() {
        #expect(GitFileStatusKind.added.badge == "A")
        #expect(GitFileStatusKind.modified.badge == "M")
        #expect(GitFileStatusKind.deleted.badge == "D")
        #expect(GitFileStatusKind.renamed.badge == "R")
        #expect(GitFileStatusKind.copied.badge == "C")
        #expect(GitFileStatusKind.unmerged.badge == "U")
        #expect(GitFileStatusKind.untracked.badge == "??")
    }
}
