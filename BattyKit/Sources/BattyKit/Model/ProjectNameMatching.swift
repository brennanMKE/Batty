// ProjectNameMatching.swift

import Foundation

enum ProjectNameMatching {
    /// Names worth suggesting for a name that matched nothing: one contains
    /// the other, or they are within two edits, all case-insensitive. Store
    /// order is kept. Either string under three characters never matches.
    /// A shorter string than this would match almost everything.
    private static let minimumLength = 3

    static func closeMatches(to query: String, in names: [String]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return names.filter { name in
            let candidate = name.lowercased()
            guard min(candidate.count, needle.count) >= minimumLength else { return false }
            return candidate.contains(needle) || needle.contains(candidate)
                || editDistance(candidate, needle) <= 2
        }
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            for (j, cb) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}
