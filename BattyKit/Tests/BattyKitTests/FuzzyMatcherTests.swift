// FuzzyMatcherTests.swift

import Foundation
import Testing
@testable import BattyKit

struct FuzzyMatcherTests {

    @Test func emptyQueryReturnsNil() {
        #expect(FuzzyMatcher.match(query: "", in: "worker") == nil)
    }

    @Test func nonSubsequenceReturnsNil() {
        #expect(FuzzyMatcher.match(query: "xyz", in: "worker") == nil)
    }

    @Test func queryLongerThanCandidateReturnsNil() {
        #expect(FuzzyMatcher.match(query: "workers", in: "wor") == nil)
    }

    @Test func contiguousMatchBeatsScattered() {
        let contiguous = FuzzyMatcher.match(query: "wor", in: "worker")
        let scattered = FuzzyMatcher.match(query: "wor", in: "wandering-orange")
        #expect(contiguous != nil)
        #expect(scattered != nil)
        #expect(contiguous!.score > scattered!.score)
    }

    @Test func caseInsensitive() {
        let upper = FuzzyMatcher.match(query: "WOR", in: "worker")
        let lower = FuzzyMatcher.match(query: "wor", in: "WORKER")
        #expect(upper != nil)
        #expect(lower != nil)
        #expect(upper!.matchedIndices == [0, 1, 2])
        #expect(lower!.matchedIndices == [0, 1, 2])
    }

    @Test func returnsIndicesOfMatch() {
        let match = FuzzyMatcher.match(query: "bat", in: "batty")
        #expect(match?.matchedIndices == [0, 1, 2])
    }

    @Test func startOfStringBeatsMidWord() {
        let leading = FuzzyMatcher.match(query: "tab", in: "tablet")
        let trailing = FuzzyMatcher.match(query: "tab", in: "metabolism")
        #expect(leading != nil)
        #expect(trailing != nil)
        #expect(leading!.score > trailing!.score)
    }

    @Test func wordBoundaryBonusFiresAfterSeparator() {
        // "web" after a slash should beat "web" in the middle of a token.
        let boundary = FuzzyMatcher.match(query: "web", in: "src/web")
        let mid = FuzzyMatcher.match(query: "web", in: "scwebber")
        #expect(boundary != nil)
        #expect(mid != nil)
        #expect(boundary!.score > mid!.score)
    }

    @Test func scatteredMatchStillValid() {
        // "abc" appears as a subsequence in "axbxc"
        let match = FuzzyMatcher.match(query: "abc", in: "axbxc")
        #expect(match?.matchedIndices == [0, 2, 4])
    }

    @Test func partialContiguousScoresHigherThanFullyScattered() {
        let partial = FuzzyMatcher.match(query: "abc", in: "abxc")
        let fully = FuzzyMatcher.match(query: "abc", in: "axbxc")
        #expect(partial != nil)
        #expect(fully != nil)
        #expect(partial!.score > fully!.score)
    }
}
