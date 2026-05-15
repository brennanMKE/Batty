// TUIAppRegistry.swift

import Foundation

public enum TUIAppRegistry {
    public static let displayNames: [String: String] = [
        // Major / frontier agents
        "claude":       "Claude Code",
        "codex":        "Codex",
        "opencode":     "OpenCode",
        "gemini":       "Gemini CLI",
        "crush":        "Crush",
        "amp":          "Amp",
        "droid":        "Droid",
        "cursor-agent": "Cursor CLI",

        // Open source / power-user tools
        "aider":        "Aider",
        "goose":        "Goose",
        "plandex":      "Plandex",
        "pdx":          "Plandex",
        "cn":           "Continue CLI",
        "qwen":         "Qwen Code",
        "cline":        "Cline CLI",
        "roo":          "Roo Code CLI",
        "kilo":         "Kilo Code CLI",
        "sweagent":     "SWE-agent",
        "gptme":        "gptme",
        "pi":           "Pi",
        "forge":        "Forge",

        // Big-tech CLIs
        "copilot":      "GitHub Copilot CLI",
        "q":            "Amazon Q Developer",
    ]

    public static func displayName(for command: String) -> String? {
        let key = (command as NSString).lastPathComponent.lowercased()
        return displayNames[key]
    }

    /// Lazily-built reverse index for matching titles that already contain a
    /// display name verbatim (e.g. a TUI sets its OSC 2 title to its product
    /// name like "Claude Code"). Lowercased on both sides.
    private static let displayNameIndex: [String: String] = {
        var idx: [String: String] = [:]
        for value in displayNames.values {
            idx[value.lowercased()] = value
        }
        return idx
    }()

    /// Derives a registered display name from an OSC 2 title string emitted
    /// by the shell or a running TUI. Returns nil when the title clearly
    /// describes a prompt (`user@host:cwd`) or doesn't match any registered
    /// command.
    ///
    /// The shell-integration path that motivates this:
    /// oh-my-zsh's `omz_termsupport_preexec` runs `title "$CMD" "$LONG"`
    /// which emits both OSC 1 (icon, `$CMD`) and OSC 2 (title, `$LONG`)
    /// when the user runs a command. libghostty surfaces OSC 2 but
    /// discards OSC 1, so we parse the long form to recover the command
    /// basename. The long form is `"%100>...>${LINE}%<<"` after zsh prompt
    /// expansion — `LINE` is the full command string, optionally prefixed
    /// by `...>` when zsh truncated it.
    ///
    /// Matching strategy, in order:
    ///   1. Exact case-insensitive match against a known display name
    ///      (catches TUIs that set their own product name as the title).
    ///   2. Strip a leading `...>` truncation marker, take the first
    ///      whitespace-separated token, basename it, and look up in the
    ///      command registry.
    ///   3. Bail to nil for titles that look like prompts (`user@host:` or
    ///      a path beginning with `~` or `/`).
    public static func displayNameFromTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = displayNameIndex[trimmed.lowercased()] {
            return direct
        }

        let withoutTruncation: String
        if trimmed.hasPrefix("...>") {
            withoutTruncation = String(trimmed.dropFirst(4))
        } else {
            withoutTruncation = trimmed
        }

        if withoutTruncation.contains("@"),
           let colonIdx = withoutTruncation.firstIndex(of: ":"),
           withoutTruncation[..<colonIdx].contains("@") {
            return nil
        }

        guard let firstToken = withoutTruncation
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
        else { return nil }

        let candidate = String(firstToken)
        if candidate.hasPrefix("~") || candidate.hasPrefix("/") {
            return nil
        }

        return displayName(for: candidate)
    }
}
