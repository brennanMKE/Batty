// TabTitleFormatterTests.swift

import Foundation
import Testing
@testable import BattyKit

struct TabTitleFormatterTests {

    // MARK: stripShellPromptPrefix

    @Test func stripsTypicalUserHostHomePrefix() {
        let result = TabTitleFormatter.stripShellPromptPrefix("brennan@macbook-air-m4-brennan-2:~")
        #expect(result == "~")
    }

    @Test func stripsUserHostPathPrefix() {
        let result = TabTitleFormatter.stripShellPromptPrefix("brennan@host:~/Developer/Batty")
        #expect(result == "~/Developer/Batty")
    }

    @Test func stripsUserHostAbsolutePathPrefix() {
        let result = TabTitleFormatter.stripShellPromptPrefix("brennan@host:/var/log")
        #expect(result == "/var/log")
    }

    @Test func preservesTitlesWithoutUserHostPrefix() {
        let result = TabTitleFormatter.stripShellPromptPrefix("vim - file.txt")
        #expect(result == "vim - file.txt")
    }

    @Test func preservesColonTitlesThatLackAt() {
        // "X: Y" looks superficially like a prefix but has no @ — leave it.
        let result = TabTitleFormatter.stripShellPromptPrefix("MyTUI: status")
        #expect(result == "MyTUI: status")
    }

    @Test func returnsNilForEmptyOrWhitespace() {
        #expect(TabTitleFormatter.stripShellPromptPrefix("") == nil)
        #expect(TabTitleFormatter.stripShellPromptPrefix("   ") == nil)
    }

    @Test func returnsNilWhenStrippedRemainderIsEmpty() {
        // "brennan@host:" with nothing after the colon — no useful content.
        #expect(TabTitleFormatter.stripShellPromptPrefix("brennan@host:") == nil)
    }

    // MARK: prettifyPath

    @Test func prettifyCollapsesLiteralHome() {
        #expect(TabTitleFormatter.prettifyPath("~") == "~")
    }

    @Test func prettifyCollapsesHomeAbsolute() {
        #expect(TabTitleFormatter.prettifyPath(NSHomeDirectory()) == "~")
    }

    @Test func prettifyPreservesRoot() {
        #expect(TabTitleFormatter.prettifyPath("/") == "/")
    }

    @Test func prettifyShowsBasenameForHomeRelative() {
        #expect(TabTitleFormatter.prettifyPath("~/Developer/Batty") == "Batty")
    }

    @Test func prettifyShowsBasenameForAbsoluteUnderHome() {
        let path = NSHomeDirectory() + "/Developer/Batty"
        #expect(TabTitleFormatter.prettifyPath(path) == "Batty")
    }

    @Test func prettifyShowsBasenameForAbsolutePath() {
        #expect(TabTitleFormatter.prettifyPath("/var/log") == "log")
    }

    @Test func prettifyPassesPlainStringsThrough() {
        // No directory separators — return as-is.
        #expect(TabTitleFormatter.prettifyPath("plainword") == "plainword")
    }

    // MARK: chipTitle integration

    @Test func chipPrefersUserOverride() {
        let tab = TabRuntime(titleOverride: "Frontend")
        #expect(TabTitleFormatter.chipTitle(for: tab) == "Frontend")
    }

    @Test func chipFallsBackToFallbackWhenNoSignals() {
        let tab = TabRuntime()
        // Without titleOverride, without a live title, without a cwd, the
        // result is the supplied fallback.
        #expect(TabTitleFormatter.chipTitle(for: tab) == "Tab")
        #expect(TabTitleFormatter.chipTitle(for: tab, fallback: "Tab 7") == "Tab 7")
    }
}
