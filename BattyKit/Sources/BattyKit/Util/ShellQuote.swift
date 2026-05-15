// ShellQuote.swift

import Foundation

enum ShellQuote {
    static func posix(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'" + escaped + "'"
    }

    static func joinPaths(_ paths: [String]) -> String {
        guard !paths.isEmpty else { return "" }
        return paths.map(posix(_:)).joined(separator: " ") + " "
    }
}
