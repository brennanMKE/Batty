// CodexConfigBlockTests.swift

@testable import BattyCLICore
import Foundation
import Testing

nonisolated struct CodexConfigBlockTests {
    private func block(_ key: String = "batty", command: String = "/Applications/Batty.app/Contents/Resources/bin/batty") -> String {
        CodexConfigBlock.lines(key: key, cliCommandName: key, command: command).map { $0 + "\n" }.joined()
    }

    private func written(_ result: CodexConfigBlock.Result) -> String? {
        if case let .write(text) = result { text } else { nil }
    }

    /// Byte comparison: `String ==` compares canonical equivalence and treats `"\r\n"` as one `Character`.
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func crlf(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: "\r\n") }

    /// Asserts `result` is `before`, then a block for `key` ending in `ending`, then `after`, compared as bytes.
    private func expectOutsideUnchanged(_ result: String, before: String, after: String, key: String = "batty", ending: String) {
        let result = bytes(result)
        #expect(result.starts(with: bytes(before)))
        #expect(result.reversed().starts(with: bytes(after).reversed()))
        let middle = String(decoding: result.dropFirst(bytes(before).count).dropLast(bytes(after).count), as: UTF8.self)
        #expect(bytes(middle) == bytes(block(key).replacingOccurrences(of: "\n", with: ending)))
    }

    @Test func blockForwardsPaneIDsWithEnvVars() {
        let text = block()
        #expect(text.hasPrefix("# batty:begin"))
        #expect(text.contains("\n[mcp_servers.batty]\n"))
        #expect(text.contains("\nargs = [\"mcp\"]\n"))
        #expect(text.contains("\nenv_vars = [\"BATTY_SESSION_ID\", \"BATTY_TAB_ID\", \"BATTY_PANE_ID\"]\n"))
        #expect(text.hasSuffix("# batty:end\n"))
    }

    @Test func commandPathIsTOMLEscaped() {
        #expect(block(command: #"/a "b"\c"#).contains(#"command = "/a \"b\"\\c""#))
    }

    @Test(arguments: [
        ("model = \"o3\"\n[profiles.x]\nk = 1\n", "\n", "\n"),
        ("model = \"o3\"\n[profiles.x]\nk = 1", "\n\n", "\n"),
        ("model = \"o3\"\r\n[profiles.x]\r\n", "\r\n", "\r\n"),
        ("model = \"o3\"\r\n[profiles.x]\r\nk = 1", "\r\n\r\n", "\r\n"),
    ])
    func appendKeepsExistingTextByteForByte(original: String, separator: String, ending: String) throws {
        let result = try #require(written(CodexConfigBlock.merge(existing: original, block: block(), key: "batty")))
        expectOutsideUnchanged(result, before: original + separator, after: "", ending: ending)
    }

    @Test func emptyFileGetsJustTheBlockWithLF() throws {
        #expect(try bytes(#require(written(CodexConfigBlock.merge(existing: "", block: block(), key: "batty")))) == bytes(block()))
        #expect(try bytes(#require(written(CodexConfigBlock.merge(existing: nil, block: block(), key: "batty")))) == bytes(block()))
    }

    @Test func crlfAppendAddsExactlyOneBlankLine() throws {
        let original = crlf("a = 1\n[profiles.x]\nk = 1\n")
        let result = try #require(written(CodexConfigBlock.merge(existing: original, block: block(), key: "batty")))
        #expect(!bytes(result).starts(with: bytes(original + "\r\n\r\n")))
        expectOutsideUnchanged(result, before: original + "\r\n", after: "", ending: "\r\n")
    }

    @Test func replacesOnlyItsOwnMarkedBlock() throws {
        let before = "a = 1\n\n"
        let after = "[mcp_servers.other]\ncommand = \"x\"\n"
        let stale = block(command: "/old/batty")
        let result = try #require(written(CodexConfigBlock.merge(existing: before + stale + after, block: block(), key: "batty")))
        expectOutsideUnchanged(result, before: before, after: after, ending: "\n")
    }

    @Test func crlfRerunWithStaleBlockReplacesOnlyTheBlock() throws {
        let before = crlf("a = 1\n\n")
        let after = crlf("[mcp_servers.other]\ncommand = \"x\"\n")
        let stale = crlf(block(command: "/old/batty"))
        let result = try #require(written(CodexConfigBlock.merge(existing: before + stale + after, block: block(), key: "batty")))
        expectOutsideUnchanged(result, before: before, after: after, ending: "\r\n")
        #expect(result.components(separatedBy: "[mcp_servers.batty]").count == 2)
    }

    @Test func crlfRerunWithCurrentBlockIsUnchanged() throws {
        let original = crlf("a = 1\n")
        let first = try #require(written(CodexConfigBlock.merge(existing: original, block: block(), key: "batty")))
        #expect(CodexConfigBlock.merge(existing: first, block: block(), key: "batty") == .unchanged)
    }

    @Test func crlfUnmarkedTableOfSameNameConflicts() {
        let result = CodexConfigBlock.merge(existing: crlf("a = 1\n[mcp_servers.batty]\ncommand = \"mine\"\n"), block: block(), key: "batty")
        guard case .conflict = result else { Issue.record("expected conflict, got \(result)"); return }
    }

    @Test func mixedEndingsKeepEachLineAndAppendWithTheDominantOne() throws {
        let original = "a = 1\r\nb = 2\nc = 3\nd = 4\r\n"
        let lfResult = try #require(written(CodexConfigBlock.merge(existing: original + "e = 5\n", block: block(), key: "batty")))
        expectOutsideUnchanged(lfResult, before: original + "e = 5\n\n", after: "", ending: "\n")
        let crlfResult = try #require(written(CodexConfigBlock.merge(existing: original + "e = 5\r\n", block: block(), key: "batty")))
        expectOutsideUnchanged(crlfResult, before: original + "e = 5\r\n\r\n", after: "", ending: "\r\n")
    }

    @Test func mixedEndingsReplaceOnlyTheBlock() throws {
        let before = "a = 1\r\nb = 2\n\n"
        let after = "[x]\r\nk = 1\n"
        let stale = block(command: "/old/batty")
        let result = try #require(written(CodexConfigBlock.merge(existing: before + stale + after, block: block(), key: "batty")))
        let resultBytes = bytes(result)
        #expect(resultBytes.starts(with: bytes(before)))
        #expect(resultBytes.reversed().starts(with: bytes(after).reversed()))
        #expect(result.contains("command = \"/Applications/Batty.app/Contents/Resources/bin/batty\""))
        #expect(!result.contains("/old/batty"))
    }

    @Test func blockAtEndOfFileWithoutTrailingNewlineKeepsThatEnding() throws {
        let before = "a = 1\n\n"
        var stale = block(command: "/old/batty")
        stale.removeLast()
        let result = try #require(written(CodexConfigBlock.merge(existing: before + stale, block: block(), key: "batty")))
        var expected = block()
        expected.removeLast()
        #expect(bytes(result) == bytes(before + expected))
    }

    @Test func identicalBlockIsUnchanged() {
        #expect(CodexConfigBlock.merge(existing: "a = 1\n\n" + block(), block: block(), key: "batty") == .unchanged)
    }

    @Test(arguments: ["[mcp_servers.batty]", "[mcp_servers.\"batty\"]", "[ mcp_servers.batty ]  # mine", "[mcp_servers.batty.tools.id]", "mcp_servers.batty.command = \"x\""])
    func unmarkedTableOfSameNameConflicts(line: String) {
        let result = CodexConfigBlock.merge(existing: "a = 1\n\(line)\n", block: block(), key: "batty")
        guard case .conflict = result else { Issue.record("expected conflict, got \(result)"); return }
    }

    @Test(arguments: [("[mcp_servers.batty-beta]", "batty"), ("[mcp_servers.battyx]", "batty"), ("[mcp_servers.batty]", "batty-beta")])
    func similarlyNamedTablesDoNotConflict(line: String, key: String) throws {
        let original = "\(line)\ncommand = \"x\"\n"
        let result = try #require(written(CodexConfigBlock.merge(existing: original, block: block(key), key: key)))
        expectOutsideUnchanged(result, before: original + "\n", after: "", key: key, ending: "\n")
    }

    @Test func prodMarkersDoNotMatchBetaMarkers() throws {
        let beta = block("batty-beta")
        let result = try #require(written(CodexConfigBlock.merge(existing: beta, block: block(), key: "batty")))
        expectOutsideUnchanged(result, before: beta + "\n", after: "", ending: "\n")
    }

    @Test(arguments: ["# batty:begin\n", "# batty:end\n# batty:begin\n", "# batty:begin\n# batty:begin\n# batty:end\n"])
    func unbalancedMarkersConflict(text: String) {
        let result = CodexConfigBlock.merge(existing: text, block: block(), key: "batty")
        guard case .conflict = result else { Issue.record("expected conflict, got \(result)"); return }
    }

    @Test func removingDeletesOnlyBattyBlock() {
        let user = "[profile]\nmodel = \"x\"\n"
        guard case let .write(merged) = CodexConfigBlock.merge(existing: user, block: block(), key: "batty") else {
            Issue.record("expected a write")
            return
        }
        #expect(CodexConfigBlock.removing(key: "batty", from: merged) == .write(user))
        #expect(CodexConfigBlock.removing(key: "batty", from: user) == .unchanged)
    }

    @Test func removingWithUnbalancedMarkersFails() {
        let text = "# batty:begin\n[mcp_servers.batty]\n"
        guard case .conflict = CodexConfigBlock.removing(key: "batty", from: text) else {
            Issue.record("expected a conflict")
            return
        }
    }
}
