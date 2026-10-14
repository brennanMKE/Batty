// PortablePath.swift

import Foundation

/// The home-relative form of a Project root in a sync record. Pure: the home
/// directory is a parameter and nothing touches the filesystem.
enum PortablePath {
    /// A path under `home` becomes `~/…`, `home` itself becomes `~`, and
    /// anything else (including a path that only shares a string prefix with
    /// `home`) is returned unchanged.
    static func encode(absolute: String, home: String) -> String {
        let home = normalizedHome(home)
        guard !home.isEmpty else { return absolute }
        if absolute == home { return "~" }
        if absolute.hasPrefix(home + "/") { return "~" + absolute.dropFirst(home.count) }
        return absolute
    }

    /// Expands only a bare `~` or a leading `~/`. `~user/…` and any other
    /// form is returned unchanged.
    static func decode(portable: String, home: String) -> String {
        let home = normalizedHome(home)
        guard !home.isEmpty else { return portable }
        if portable == "~" { return home }
        if portable.hasPrefix("~/") { return home + portable.dropFirst(1) }
        return portable
    }

    private static func normalizedHome(_ home: String) -> String {
        let standardized = Project.standardizedRoot(home)
        return standardized == "/" || !standardized.hasPrefix("/") ? "" : standardized
    }
}
