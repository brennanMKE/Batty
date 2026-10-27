// NonProjectDirectory.swift

import Foundation

/// Folders that are never named as a project: the account home, `/`, any
/// top-level directory, and the temp roots. Lexical only; no filesystem access.
enum NonProjectDirectory {
    static func contains(
        _ path: String,
        home: String = NSHomeDirectory(),
        temporaryDirectory: String = NSTemporaryDirectory()
    ) -> Bool {
        guard let normalized = normalize(path, home: home) else { return false }
        if let normalizedHome = normalize(home, home: home), normalized == normalizedHome { return true }
        if normalized.split(separator: "/").count <= 1 { return true }
        if normalized == "/var/tmp" { return true }
        if let normalizedTemp = normalize(temporaryDirectory, home: home), normalized == normalizedTemp { return true }
        return false
    }

    /// `/tmp`, `/var` and `/etc` are symlinks into `/private`, and the shell
    /// reports either spelling, so `/private/tmp` and `/tmp` compare equal.
    private static func normalize(_ path: String, home: String) -> String? {
        var expanded = path
        if expanded == "~" {
            expanded = home
        } else if expanded.hasPrefix("~/") {
            expanded = home + "/" + expanded.dropFirst(2)
        }
        guard expanded.hasPrefix("/") else { return nil }
        var standardized = Project.standardizedRoot(expanded)
        for linked in ["/tmp", "/var", "/etc"] {
            let prefixed = "/private" + linked
            if standardized == prefixed || standardized.hasPrefix(prefixed + "/") {
                standardized.removeFirst("/private".count)
                break
            }
        }
        return standardized
    }
}
