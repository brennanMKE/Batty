// FuzzyMatcher.swift

import Foundation

enum FuzzyMatcher {
    /// Returns `true` when `query` is a case-insensitive subsequence of `text`.
    static func matches(_ query: String, in text: String) -> Bool {
        guard !query.isEmpty else { return true }
        let lq = query.lowercased()
        let lt = text.lowercased()
        var qi = lq.startIndex
        for ch in lt {
            guard qi < lq.endIndex else { break }
            if ch == lq[qi] {
                qi = lq.index(after: qi)
            }
        }
        return qi == lq.endIndex
    }

    /// Returns a relevance score (higher = better). 0 means no match.
    /// Contiguous prefix matches score highest; contiguous interior matches
    /// next; scattered subsequence matches score lowest.
    static func score(_ query: String, in text: String) -> Int {
        guard !query.isEmpty else { return 1 }
        let lq = query.lowercased()
        let lt = text.lowercased()
        guard matches(query, in: text) else { return 0 }
        if lt.hasPrefix(lq) { return 3 }
        if lt.contains(lq) { return 2 }
        return 1
    }
}
