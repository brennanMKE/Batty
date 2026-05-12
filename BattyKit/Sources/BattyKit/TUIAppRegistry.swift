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
}
