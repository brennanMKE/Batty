// GitWorktreeListParserTests.swift

import Foundation
import Testing
@testable import BattyKit

private func nulJoined(_ tokens: String...) -> String {
    tokens.joined(separator: "\u{0}")
}

/// Fixtures mirror real `git worktree list --porcelain -z` output (git 2.54.0):
/// one NUL-terminated token per attribute and an extra NUL between records.
struct GitWorktreeListParserTests {
    private let sha = "6d130667d3ab53021e0e180671b4abe6fedbffa5"

    @Test func mainWorktreeOnABranch() {
        let output = nulJoined("worktree /repo", "HEAD \(sha)", "branch refs/heads/main", "", "")
        let entries = GitWorktreeListParser.parse(output)
        #expect(entries == [GitWorktreeEntry(path: "/repo", headSHA: sha, branch: "main")])
        #expect(entries[0].id == "/repo")
    }

    @Test func branchNameWithSlashesKeepsEverythingAfterRefsHeads() {
        let output = nulJoined("worktree /repo", "HEAD \(sha)", "branch refs/heads/issue/0488", "", "")
        #expect(GitWorktreeListParser.parse(output).first?.branch == "issue/0488")
    }

    @Test func detachedWorktree() {
        let output = nulJoined("worktree /wt", "HEAD \(sha)", "detached", "", "")
        let entry = GitWorktreeListParser.parse(output)[0]
        #expect(entry.isDetached)
        #expect(entry.branch == nil)
        #expect(entry.headSHA == sha)
    }

    @Test func lockedWithoutAReason() {
        let output = nulJoined("worktree /wt", "HEAD \(sha)", "detached", "locked", "", "")
        let entry = GitWorktreeListParser.parse(output)[0]
        #expect(entry.isLocked)
        #expect(entry.lockReason == nil)
    }

    @Test func lockedWithAReason() {
        let output = nulJoined("worktree /wt", "HEAD \(sha)", "branch refs/heads/x", "locked on a usb stick", "", "")
        let entry = GitWorktreeListParser.parse(output)[0]
        #expect(entry.isLocked)
        #expect(entry.lockReason == "on a usb stick")
    }

    @Test func prunableWithAReason() {
        let output = nulJoined(
            "worktree /gone", "HEAD \(sha)", "branch refs/heads/gone",
            "prunable gitdir file points to non-existent location", "", ""
        )
        let entry = GitWorktreeListParser.parse(output)[0]
        #expect(entry.isPrunable)
        #expect(entry.pruneReason == "gitdir file points to non-existent location")
    }

    @Test func bareEntryHasNoHeadOrBranch() {
        let output = nulJoined(
            "worktree /bare.git", "bare", "",
            "worktree /bare-wt", "HEAD \(sha)", "branch refs/heads/main", "", ""
        )
        let entries = GitWorktreeListParser.parse(output)
        #expect(entries.count == 2)
        #expect(entries[0].isBare)
        #expect(entries[0].headSHA == nil)
        #expect(entries[0].branch == nil)
        #expect(!entries[0].isDetached)
        #expect(entries[1].branch == "main")
    }

    @Test func pathContainingASpaceIsKeptRaw() {
        let output = nulJoined("worktree /tmp/my worktree/a b", "HEAD \(sha)", "branch refs/heads/main", "", "")
        #expect(GitWorktreeListParser.parse(output).first?.path == "/tmp/my worktree/a b")
    }

    @Test func pathContainingANewlineIsKeptIntact() {
        let output = nulJoined("worktree /tmp/a\nb", "HEAD \(sha)", "branch refs/heads/main", "", "")
        #expect(GitWorktreeListParser.parse(output).first?.path == "/tmp/a\nb")
    }

    @Test func unknownAttributeLinesAreSkipped() {
        let output = nulJoined("worktree /repo", "HEAD \(sha)", "futureattr something", "branch refs/heads/main", "", "")
        #expect(GitWorktreeListParser.parse(output) == [GitWorktreeEntry(path: "/repo", headSHA: sha, branch: "main")])
    }

    @Test func emptyOutputYieldsNoEntries() {
        #expect(GitWorktreeListParser.parse("").isEmpty)
    }

    @Test func missingTrailingTerminatorStillYieldsTheLastRecord() {
        let withoutTerminator = nulJoined(
            "worktree /a", "HEAD \(sha)", "branch refs/heads/a", "",
            "worktree /b", "HEAD \(sha)", "detached"
        )
        let entries = GitWorktreeListParser.parse(withoutTerminator)
        #expect(entries.map(\.path) == ["/a", "/b"])
        #expect(entries[1].isDetached)
    }

    @Test func multipleRecordsKeepGitsOrder() {
        let output = nulJoined(
            "worktree /main", "HEAD \(sha)", "branch refs/heads/main", "",
            "worktree /z", "HEAD \(sha)", "detached", "",
            "worktree /a", "HEAD \(sha)", "branch refs/heads/a", "", ""
        )
        #expect(GitWorktreeListParser.parse(output).map(\.path) == ["/main", "/z", "/a"])
    }

    @Test func orderedKeepsMainFirstSortsTheRestAndMarksCurrent() {
        let entries = ["/main", "/wt/b", "/wt/a", "/wt/c"].map { GitWorktreeEntry(path: $0) }
        let ordered = GitWorktreeListParser.ordered(entries, currentPath: "/wt/a")
        #expect(ordered.map(\.path) == ["/main", "/wt/a", "/wt/b", "/wt/c"])
        #expect(ordered.map(\.isCurrent) == [false, true, false, false])
    }

    @Test func orderedSortsNumericallyAwareLikeFinder() {
        let entries = ["/main", "/wt/10", "/wt/9"].map { GitWorktreeEntry(path: $0) }
        #expect(GitWorktreeListParser.ordered(entries, currentPath: "/main").map(\.path) == ["/main", "/wt/9", "/wt/10"])
    }

    @Test func orderedOfNothingIsNothing() {
        #expect(GitWorktreeListParser.ordered([], currentPath: "/x").isEmpty)
    }
}
