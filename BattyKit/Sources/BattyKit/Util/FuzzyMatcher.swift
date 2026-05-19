// FuzzyMatcher.swift

import Foundation

/// Lightweight fuzzy substring scorer used for live-filter UIs.
/// Returns 0 when the query is not a subsequence of the target.
/// Higher scores indicate a better match (exact or prefix matches
/// score higher than scattered subsequence matches).
public enum FuzzyMatcher {
    /// Returns a relevance score > 0 when every character in `query`
    /// appears in `target` in order (case-insensitive), 0 otherwise.
    public static func score(_ query: String, in target: String) -> Int {
        guard !query.isEmpty else { return 1 }
        let q = query.lowercased()
        let t = target.lowercased()

        // Exact match: highest score.
        if t == q { return 1000 }
        // Prefix match: very high score.
        if t.hasPrefix(q) { return 900 }
        // Substring match: high score.
        if t.contains(q) { return 700 }

        // Subsequence match: score by how tight the match is.
        var qIdx = q.startIndex
        var matchCount = 0
        for ch in t {
            guard qIdx < q.endIndex else { break }
            if ch == q[qIdx] {
                q.formIndex(after: &qIdx)
                matchCount += 1
            }
        }
        guard qIdx == q.endIndex else { return 0 }
        return 100 + matchCount
    }
}
