// ShellQuoteTests.swift

import Foundation
import Testing
@testable import BattyKit

struct ShellQuoteTests {

    @Test func plainPathIsSingleQuoted() {
        #expect(ShellQuote.posix("/tmp/foo.png") == "'/tmp/foo.png'")
    }

    @Test func pathWithSpacesIsSingleQuoted() {
        #expect(ShellQuote.posix("/tmp/Screenshot 2026.png") == "'/tmp/Screenshot 2026.png'")
    }

    @Test func internalSingleQuoteIsEscaped() {
        #expect(ShellQuote.posix("/tmp/it's-fine.txt") == "'/tmp/it'\\''s-fine.txt'")
    }

    @Test func narrowNoBreakSpaceIsPreservedLiterally() {
        let nbsp = "\u{202F}"
        let path = "/tmp/Screenshot 2026-05-08 at 12.34.56\(nbsp)PM.png"
        let quoted = ShellQuote.posix(path)
        #expect(quoted == "'\(path)'")
        #expect(quoted.contains(nbsp))
    }

    @Test func joinPathsAddsTrailingSpace() {
        let joined = ShellQuote.joinPaths(["/a", "/b c"])
        #expect(joined == "'/a' '/b c' ")
    }

    @Test func joinPathsEmptyReturnsEmpty() {
        #expect(ShellQuote.joinPaths([]) == "")
    }

    @Test func joinPathsSingleStillTrailingSpace() {
        #expect(ShellQuote.joinPaths(["/x"]) == "'/x' ")
    }
}
