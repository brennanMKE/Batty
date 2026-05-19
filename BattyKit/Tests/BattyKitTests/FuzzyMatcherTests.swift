// FuzzyMatcherTests.swift

import Foundation
import Testing
@testable import BattyKit

struct FuzzyMatcherTests {

    // MARK: matches — subsequence

    @Test func matchesExactSubstringCaseInsensitive() {
        #expect(FuzzyMatcher.matches("bird", in: "Bird"))
        #expect(FuzzyMatcher.matches("BIRD", in: "Bird"))
        #expect(FuzzyMatcher.matches("Bird", in: "bird"))
    }

    @Test func matchesScatteredSubsequence() {
        #expect(FuzzyMatcher.matches("cpy", in: "Capybara"))
    }

    @Test func doesNotMatchAbsentCharacters() {
        #expect(!FuzzyMatcher.matches("bird", in: "Cat"))
        #expect(!FuzzyMatcher.matches("bird", in: "Dog"))
        #expect(!FuzzyMatcher.matches("bird", in: "Capybara"))
        #expect(!FuzzyMatcher.matches("xyz", in: "Bird"))
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(FuzzyMatcher.matches("", in: "anything"))
        #expect(FuzzyMatcher.matches("", in: ""))
    }

    // MARK: scoring — ordering

    @Test func contiguousScoresHigherThanScattered() {
        #expect(FuzzyMatcher.score("bir", in: "Bird") > FuzzyMatcher.score("bir", in: "Bartleby Ire"))
    }

    @Test func prefixScoresHigherThanInterior() {
        #expect(FuzzyMatcher.score("bird", in: "Bird") > FuzzyMatcher.score("bird", in: "Mockingbird"))
    }

    @Test func noMatchScoresZero() {
        #expect(FuzzyMatcher.score("bird", in: "Cat") == 0)
    }

    @Test func emptyQueryScoresPositive() {
        #expect(FuzzyMatcher.score("", in: "anything") > 0)
    }

    // MARK: reproduction — the Cat/Dog/Bird/Capybara case (raw matcher level)

    @Test func birdQueryOnlyMatchesBird() {
        let candidates = ["Cat", "Dog", "Bird", "Capybara"]
        let matches = candidates.filter { FuzzyMatcher.matches("bird", in: $0) }
        #expect(matches == ["Bird"])
    }

    @Test func birdQuerySortedTopIsBird() {
        let candidates = ["Cat", "Dog", "Bird", "Capybara"]
        let sorted = candidates
            .filter { FuzzyMatcher.matches("bird", in: $0) }
            .sorted { FuzzyMatcher.score("bird", in: $0) > FuzzyMatcher.score("bird", in: $1) }
        #expect(sorted.first == "Bird")
    }

    @Test func birdQueryAgainstComposedDisplayTitles() {
        let titles = ["Cat \u{203A} ~", "Dog \u{203A} ~", "Bird \u{203A} ~", "Capybara \u{203A} ~"]
        let matched = titles.filter { FuzzyMatcher.matches("bird", in: $0) }
        #expect(matched == ["Bird \u{203A} ~"])
    }
}

struct OpenQuicklyFilterTests {

    private func makeResults(_ pairs: [(String, String)]) -> [QuickOpenResult] {
        pairs.map { sessionTitle, tabTitle in
            QuickOpenResult(
                sessionID: UUID(),
                sessionTitle: sessionTitle,
                tabID: UUID(),
                tabTitle: tabTitle
            )
        }
    }

    // MARK: regression — the Cat/Dog/Bird/Capybara reproduction

    @Test func birdQueryReturnsOnlyBirdSession() {
        let results = makeResults([
            ("Cat", "~"),
            ("Dog", "~"),
            ("Bird", "~"),
            ("Capybara", "~"),
        ])
        let filtered = OpenQuicklyFilter.apply(query: "bird", to: results)
        #expect(filtered.count == 1)
        #expect(filtered.first?.sessionTitle == "Bird")
    }

    @Test func birdQueryAgainstTabFallbackTitles() {
        // Fallback tab title is "Tab"; verify the filter still picks Bird.
        let results = makeResults([
            ("Cat", "Tab"),
            ("Dog", "Tab"),
            ("Bird", "Tab"),
            ("Capybara", "Tab"),
        ])
        let filtered = OpenQuicklyFilter.apply(query: "bird", to: results)
        #expect(filtered.first?.sessionTitle == "Bird")
    }

    // MARK: empty query returns everything in input order

    @Test func emptyQueryPassesThroughInOrder() {
        let results = makeResults([
            ("Cat", "~"),
            ("Dog", "~"),
            ("Bird", "~"),
        ])
        let filtered = OpenQuicklyFilter.apply(query: "", to: results)
        #expect(filtered.map(\.sessionTitle) == ["Cat", "Dog", "Bird"])
    }

    // MARK: matching against tab title

    @Test func matchHitsTabTitleWhenSessionNameDoesNot() {
        let results = makeResults([
            ("Alpha", "worker"),
            ("Beta", "db"),
            ("Gamma", "tail-logs"),
        ])
        let filtered = OpenQuicklyFilter.apply(query: "wor", to: results)
        #expect(filtered.first?.tabTitle == "worker")
    }

    @Test func matchHitsSessionNameWhenTabTitleDoesNot() {
        let results = makeResults([
            ("backend", "~"),
            ("frontend", "~"),
        ])
        let filtered = OpenQuicklyFilter.apply(query: "back", to: results)
        #expect(filtered.first?.sessionTitle == "backend")
    }

    // MARK: contiguity / prefix ranking

    @Test func sessionPrefixMatchOutranksScatteredInterior() {
        let results = makeResults([
            ("Mockingbird", "~"),
            ("Bird", "~"),
        ])
        let filtered = OpenQuicklyFilter.apply(query: "bird", to: results)
        #expect(filtered.first?.sessionTitle == "Bird")
    }

    // MARK: case insensitivity

    @Test func upperCaseQueryMatchesLowerCaseSession() {
        let results = makeResults([
            ("cat", "~"),
            ("bird", "~"),
        ])
        let filtered = OpenQuicklyFilter.apply(query: "BIRD", to: results)
        #expect(filtered.first?.sessionTitle == "bird")
    }

    // MARK: no match returns empty

    @Test func unmatchedQueryReturnsEmpty() {
        let results = makeResults([
            ("Cat", "~"),
            ("Dog", "~"),
            ("Bird", "~"),
            ("Capybara", "~"),
        ])
        let filtered = OpenQuicklyFilter.apply(query: "xyz", to: results)
        #expect(filtered.isEmpty)
    }

    // MARK: identity stability

    @Test func resultIdMatchesTabID() {
        let tabID = UUID()
        let result = QuickOpenResult(
            sessionID: UUID(),
            sessionTitle: "Cat",
            tabID: tabID,
            tabTitle: "~"
        )
        #expect(result.id == tabID)
    }
}
