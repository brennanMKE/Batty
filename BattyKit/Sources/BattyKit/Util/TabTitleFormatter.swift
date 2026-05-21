// TabTitleFormatter.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "TabTitleFormatter")

public enum TabTitleFormatter {
    public static func chipTitle(for tab: TabRuntime, fallback: String? = nil) -> String {
        let resolvedFallback = fallback ?? String(localized: "Tab")
        if let override = tab.titleOverride, !override.isEmpty {
            logger.debug("tab-rename: chipTitle tab=\(tab.id, privacy: .public) branch=override value=\(override, privacy: .public)")
            return override
        }
        if let cwd = tab.terminal.workingDirectory {
            if cwd == NSHomeDirectory() || cwd == "~" {
                logger.debug("tab-rename: chipTitle tab=\(tab.id, privacy: .public) branch=home")
                return "~"
            }
        }
        if let running = tab.runningCommandDisplayName, !running.isEmpty {
            logger.debug("tab-rename: chipTitle tab=\(tab.id, privacy: .public) branch=running value=\(running, privacy: .public)")
            return running
        }
        if let stripped = stripShellPromptPrefix(tab.terminal.title), !stripped.isEmpty {
            let result = prettifyPath(stripped)
            logger.debug("tab-rename: chipTitle tab=\(tab.id, privacy: .public) branch=shellTitle value=\(result, privacy: .public)")
            return result
        }
        if let cwd = tab.terminal.workingDirectory, !cwd.isEmpty {
            if let projectName = ProjectNameResolver.shared.resolve(at: cwd), !projectName.isEmpty {
                logger.debug("tab-rename: chipTitle tab=\(tab.id, privacy: .public) branch=projectName value=\(projectName, privacy: .public)")
                return projectName
            }
            let result = prettifyPath(cwd)
            logger.debug("tab-rename: chipTitle tab=\(tab.id, privacy: .public) branch=cwd value=\(result, privacy: .public)")
            return result
        }
        logger.debug("tab-rename: chipTitle tab=\(tab.id, privacy: .public) branch=fallback")
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
