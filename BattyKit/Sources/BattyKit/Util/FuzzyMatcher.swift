// FuzzyMatcher.swift

import Foundation

/// Lightweight subsequence fuzzy matcher used by the Open Quickly panel.
/// Case-insensitive, returns matched character positions for highlighting,
/// and assigns a score that rewards contiguous matches over scattered ones.
///
/// Kept deliberately small — when the command palette (`#0126`) lands and
/// wants to share fuzzy infrastructure, this is the candidate to extract
/// behind a generic finder. Until then it stays local to Open Quickly's
/// needs.
public enum FuzzyMatcher {
    public struct Match: Sendable {
        public let score: Double
        public let matchedIndices: [Int]

        public init(score: Double, matchedIndices: [Int]) {
            self.score = score
            self.matchedIndices = matchedIndices
        }
    }

    /// Returns a `Match` when every character of `query` appears as a
    /// subsequence of `candidate` (case-insensitive). `nil` when there's
    /// no match. An empty query is treated as "no filtering" — the caller
    /// is expected to handle that case explicitly (typically by showing
    /// recency-ordered results), so this returns `nil` for an empty query.
    public static func match(query: String, in candidate: String) -> Match? {
        guard !query.isEmpty else { return nil }
        let qChars = Array(query.lowercased())
        let cChars = Array(candidate.lowercased())
        guard qChars.count <= cChars.count else { return nil }

        var matched: [Int] = []
        matched.reserveCapacity(qChars.count)
        var qi = 0
        for (ci, ch) in cChars.enumerated() where qi < qChars.count {
            if ch == qChars[qi] {
                matched.append(ci)
                qi += 1
            }
        }
        guard qi == qChars.count else { return nil }

        let score = computeScore(matchedIndices: matched, candidate: cChars)
        return Match(score: score, matchedIndices: matched)
    }

    /// Higher is better. Components:
    ///   * Contiguity reward: each pair of adjacent matched indices adds 3.0.
    ///   * Start-of-string bonus: match starting at index 0 adds 2.0.
    ///   * Word-boundary bonus: matches right after `_`, `-`, ` `, `/`, `.`
    ///     add 1.0 — these are where users mentally anchor.
    ///   * Density: shorter span between first and last matched index is
    ///     better; we subtract `0.1 * (span - queryLen)` so a tight match
    ///     across a long candidate beats a scattered one across a short
    ///     candidate of comparable token count.
    private static func computeScore(matchedIndices: [Int], candidate: [Character]) -> Double {
        guard let first = matchedIndices.first, let last = matchedIndices.last else { return 0 }
        var score = Double(matchedIndices.count)
        for i in 1..<matchedIndices.count where matchedIndices[i] == matchedIndices[i - 1] + 1 {
            score += 3.0
        }
        if first == 0 {
            score += 2.0
        }
        for idx in matchedIndices where idx > 0 {
            let prev = candidate[idx - 1]
            if prev == "_" || prev == "-" || prev == " " || prev == "/" || prev == "." {
                score += 1.0
            }
        }
        let span = last - first + 1
        let queryLen = matchedIndices.count
        score -= 0.1 * Double(max(0, span - queryLen))
        return score
    }
}
