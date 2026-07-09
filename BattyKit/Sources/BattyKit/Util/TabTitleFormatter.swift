// TabTitleFormatter.swift

import Foundation

public enum TabTitleFormatter {
    public static func chipTitle(for tab: TabRuntime, fallback: String? = nil) -> String {
        let resolvedFallback = fallback ?? String(localized: "Tab")
        if let override = tab.titleOverride, !override.isEmpty {
            return override
        }
        // `tab.workingDirectory`, not `tab.terminal.workingDirectory` — the
        // latter is Combine-backed and invisible to Observation, which left
        // this chip stuck on the tab's initial directory after `cd` (#0260).
        if let cwd = tab.workingDirectory {
            if cwd == NSHomeDirectory() || cwd == "~" {
                return "~"
            }
        }
        if let running = tab.runningCommandDisplayName, !running.isEmpty {
            return running
        }
        if let stripped = stripShellPromptPrefix(tab.terminal.title), !stripped.isEmpty {
            return prettifyPath(stripped)
        }
        // AI-suggested name (Apple Intelligence, gated by the auto-name
        // setting — see AppStateStore.updateTabAutoName(for:)) takes the
        // slot the project-name/prettified-path fallback used to own
        // outright; a live title or running command is still more specific
        // and wins above.
        if let aiName = tab.aiSuggestedName, !aiName.isEmpty {
            return aiName
        }
        if let cwd = tab.workingDirectory, !cwd.isEmpty {
            if let projectName = ProjectNameResolver.shared.resolve(at: cwd), !projectName.isEmpty {
                return projectName
            }
            return prettifyPath(cwd)
        }
        return resolvedFallback
    }

    /// Strips the leading `user@host:` prefix when present, leaving whatever
    /// the shell encoded as the rest of the OSC title. Default shells emit
    /// `user@host:cwd` for the window title; the cwd portion is what
    /// distinguishes tabs in a row.
    ///
    /// Returns the trimmed input as-is when no `user@host:` prefix is
    /// detected (so a custom title like `vim - file.txt` is preserved).
    /// Returns `nil` for empty/whitespace input.
    static func stripShellPromptPrefix(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let colonIdx = trimmed.firstIndex(of: ":"),
           trimmed[..<colonIdx].contains("@") {
            let rest = trimmed[trimmed.index(after: colonIdx)...]
                .trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return trimmed
    }

    /// Compact display for a path-like string: collapses `$HOME` (or a
    /// literal `~`) to `~`; returns the basename for deeper paths. Plain
    /// strings without slashes pass through unchanged.
    static func prettifyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home || path == "~" { return "~" }
        if path == "/" { return "/" }
        if path.hasPrefix(home + "/") {
            let basename = URL(fileURLWithPath: path).lastPathComponent
            return basename.isEmpty ? "~" : basename
        }
        if path.hasPrefix("~/") {
            let basename = (path as NSString).lastPathComponent
            return basename.isEmpty ? "~" : basename
        }
        let basename = URL(fileURLWithPath: path).lastPathComponent
        return basename.isEmpty ? path : basename
    }
}
