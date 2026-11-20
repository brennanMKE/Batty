// CodexConfigBlock.swift

import Foundation

/// Batty's `[mcp_servers.<key>]` table in Codex's `config.toml`, kept between comment markers.
/// The rest of the file is never parsed or re-serialized: only the marked lines are written.
public nonisolated enum CodexConfigBlock {
    public enum Result: Sendable, Equatable {
        case write(String)
        case unchanged
        case conflict(String)
    }

    /// Codex starts stdio MCP servers with a filtered environment; `env_vars` lets the
    /// calling Pane's ids through so tools default to that Pane, not the focused one.
    public static let forwardedVariables = ["BATTY_SESSION_ID", "BATTY_TAB_ID", "BATTY_PANE_ID"]

    public static func block(identity: AgentGuidanceIdentity, lineEnding: String = "\n") -> String {
        AgentMCPConfigSnippets.codexBlock(key: identity.pluginName, cliCommandName: identity.cliCommandName, command: identity.cliExecutablePath, lineEnding: lineEnding)
    }

    static func lines(key: String, cliCommandName: String, command: String) -> [String] {
        [
            "# \(key):begin — managed by `\(cliCommandName) agent install`; edits inside this block are replaced",
            "[mcp_servers.\(key)]",
            "command = \(tomlBasicString(command))",
            "args = [\"mcp\"]",
            "env_vars = [" + forwardedVariables.map { "\"\($0)\"" }.joined(separator: ", ") + "]",
            "# \(key):end",
        ]
    }

    public static func tomlBasicString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// `block` is the text from `block(identity:)`; its line ending is replaced by the file's.
    /// Lines are split on the `\n` byte, not on `Character`s: Swift treats `\r\n` as one
    /// `Character`, so a Character-based split would see a CRLF file as a single line.
    public static func merge(existing: String?, block: String, key: String) -> Result {
        let blockLines = splitLines(block).map(\.content).filter { !$0.isEmpty }
        let text = existing ?? ""
        var lines = text.isEmpty ? [] : splitLines(text)
        let lineEnding = dominantLineEnding(lines)
        func bare(_ line: String) -> String {
            line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let begins = lines.indices.filter { bare(lines[$0].content).hasPrefix("# \(key):begin") }
        let ends = lines.indices.filter { bare(lines[$0].content) == "# \(key):end" }

        var region: ClosedRange<Int>?
        switch (begins.count, ends.count) {
        case (0, 0): region = nil
        case (1, 1) where begins[0] < ends[0]: region = begins[0]...ends[0]
        default: return .conflict("unbalanced Batty markers (# \(key):begin / # \(key):end)")
        }

        for index in lines.indices where !(region?.contains(index) ?? false) {
            if conflicts(lines[index].content, key: key) {
                return .conflict("an unmarked [mcp_servers.\(key)] table already exists")
            }
        }

        if let region {
            if lines[region].map(\.content) == blockLines { return .unchanged }
            let lastEnding = lines[region.upperBound].ending
            let replacement = blockLines.enumerated().map { offset, content in
                Line(content: content, ending: offset == blockLines.count - 1 ? lastEnding : lineEnding)
            }
            lines.replaceSubrange(region, with: replacement)
            return .write(lines.map { $0.content + $0.ending }.joined())
        }

        var result = text
        if let last = lines.last {
            if last.ending.isEmpty { result += lineEnding }
            result += lineEnding
        }
        result += blockLines.map { $0 + lineEnding }.joined()
        return .write(result)
    }

    /// Removes the marked block and the blank line `merge` put before it.
    /// Unbalanced markers are a conflict; no markers is `.unchanged`.
    public static func removing(key: String, from text: String) -> Result {
        var lines = splitLines(text)
        let begins = lines.indices.filter { lines[$0].content.trimmingCharacters(in: .whitespaces).hasPrefix("# \(key):begin") }
        let ends = lines.indices.filter { lines[$0].content.trimmingCharacters(in: .whitespaces) == "# \(key):end" }
        switch (begins.count, ends.count) {
        case (0, 0):
            return .unchanged
        case (1, 1) where begins[0] < ends[0]:
            var lower = begins[0]
            if lower > 0, lines[lower - 1].content.trimmingCharacters(in: .whitespaces).isEmpty { lower -= 1 }
            lines.removeSubrange(lower...ends[0])
            return .write(lines.map { $0.content + $0.ending }.joined())
        default:
            return .conflict("unbalanced Batty markers (# \(key):begin / # \(key):end)")
        }
    }

    struct Line: Equatable {
        var content: String
        /// `"\n"`, `"\r\n"`, or empty for a last line with no terminator.
        var ending: String
    }

    static func splitLines(_ text: String) -> [Line] {
        let bytes = Array(text.utf8)
        var lines: [Line] = []
        var start = 0
        for index in bytes.indices where bytes[index] == UInt8(ascii: "\n") {
            let crlf = index > start && bytes[index - 1] == UInt8(ascii: "\r")
            let contentEnd = crlf ? index - 1 : index
            lines.append(Line(content: String(decoding: bytes[start..<contentEnd], as: UTF8.self), ending: crlf ? "\r\n" : "\n"))
            start = index + 1
        }
        if start < bytes.count {
            lines.append(Line(content: String(decoding: bytes[start...], as: UTF8.self), ending: ""))
        }
        return lines
    }

    /// CRLF when more lines end in CRLF than in a bare LF; LF otherwise, including for an empty file.
    static func dominantLineEnding(_ lines: [Line]) -> String {
        let crlf = lines.count { $0.ending == "\r\n" }
        let lf = lines.count { $0.ending == "\n" }
        return crlf > lf ? "\r\n" : "\n"
    }

    private static func conflicts(_ line: String, key: String) -> Bool {
        var compact = line.filter { !$0.isWhitespace }
        let names = ["mcp_servers.\(key)", "mcp_servers.\"\(key)\"", "mcp_servers.'\(key)'"]
        if compact.hasPrefix("["), !compact.hasPrefix("[[") {
            compact.removeFirst()
            guard let close = compact.firstIndex(of: "]") else { return false }
            let header = String(compact[..<close])
            return names.contains { header == $0 || header.hasPrefix($0 + ".") }
        }
        return names.contains { compact.hasPrefix($0 + "=") || compact.hasPrefix($0 + ".") }
    }
}
