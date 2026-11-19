// ProjectAgentSnippet.swift

import Foundation

/// The short Batty section offered for a project's `AGENTS.md`/`CLAUDE.md`.
/// Variant-neutral, because project files are shared through git.
public nonisolated enum ProjectAgentSnippet {
    public static let beginMarker = "<!-- batty:begin -->"
    public static let endMarker = "<!-- batty:end -->"

    public static let block = """
        \(beginMarker)
        ## Batty

        This project is often worked on inside Batty (macOS terminal multiplexer). When `BATTY_PANE_ID` is set you are in a Batty Pane; drive Batty with `batty` (`batty-beta` in Batty Beta) — run `batty capabilities` first.

        - Show status in Batty Panes (`batty pane split --view git-status --unique`) rather than printing it.
        - Start dev servers with `batty server start --port N -- <command>` (or `batty server attach --port N` if one is already running) when `batty capabilities` lists it. Don't open a browser yourself; pass `--split` only when the user asked for a placement.
        - Preview static pages with `batty server serve <dir> --open`, never `python3 -m http.server`.
        - Use `batty notify` to get the user's attention.
        \(endMarker)
        """

    public enum SnippetError: Error, Equatable, CustomStringConvertible {
        case unmatchedMarker

        public var description: String {
            "the file has an unmatched \(beginMarker) / \(endMarker) marker; fix it by hand first"
        }
    }

    public enum SnippetDecision: Sendable, Equatable {
        case write
        case prompt
        case refuse
        case preview
    }

    /// `AGENTS.md` when Claude Code will see it (no `CLAUDE.md`, or one that
    /// imports `@AGENTS.md`); else an existing `CLAUDE.md`; else a new `AGENTS.md`.
    public static func targetFile(in directory: URL, fileManager: FileManager = .default) -> URL {
        let agents = directory.appending(path: "AGENTS.md", directoryHint: .notDirectory)
        let claude = directory.appending(path: "CLAUDE.md", directoryHint: .notDirectory)
        let hasAgents = fileManager.fileExists(atPath: agents.path(percentEncoded: false))
        let claudeText = try? String(contentsOf: claude, encoding: .utf8)
        if hasAgents && (claudeText == nil || claudeText!.contains("@AGENTS.md")) {
            return agents
        }
        if claudeText != nil {
            return claude
        }
        return agents
    }

    /// Inserts the block, or replaces the existing one; text outside the markers is kept byte for byte.
    public static func apply(to existing: String?) throws(SnippetError) -> String {
        guard let existing, !existing.isEmpty else { return block + "\n" }
        let begins = existing.ranges(of: beginMarker)
        let ends = existing.ranges(of: endMarker)
        if begins.isEmpty && ends.isEmpty {
            let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
            return existing + separator + block + "\n"
        }
        guard begins.count == 1, ends.count == 1, let begin = begins.first, let end = ends.first, begin.upperBound <= end.lowerBound else {
            throw .unmatchedMarker
        }
        var result = existing
        result.replaceSubrange(begin.lowerBound..<end.upperBound, with: block)
        return result
    }

    public static func confirmationRequired(isTTY: Bool, yes: Bool, dryRun: Bool) -> SnippetDecision {
        if dryRun { return .preview }
        if yes { return .write }
        return isTTY ? .prompt : .refuse
    }
}
