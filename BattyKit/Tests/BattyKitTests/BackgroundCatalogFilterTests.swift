// BackgroundCatalogFilterTests.swift

import Foundation
import Testing
@testable import BattyKit

struct BackgroundCatalogFilterTests {
    private func image(_ title: String) -> HostedBackgroundImage {
        let slug = title.replacingOccurrences(of: " ", with: "-")
        return HostedBackgroundImage(
            title: title,
            full: URL(string: "https://example.com/\(slug).png")!,
            thumbnail: URL(string: "https://example.com/\(slug)-thumb.png")!
        )
    }

    private var deepSpace: BackgroundSet {
        BackgroundSet(id: 0, name: "Deep Space", images: [image("Nebula"), image("Galaxy")])
    }

    private var cities: BackgroundSet {
        BackgroundSet(id: 1, name: "Future Cities", images: [image("Tokyo Night"), image("Harbor Dawn")])
    }

    private func state(_ host: String, sets: [BackgroundSet]?) -> HostedCatalogState {
        var state = HostedCatalogState(url: URL(string: "https://\(host)/catalog.json")!, isBuiltIn: false)
        state.catalog = sets.map { BackgroundCatalog(sets: $0) }
        return state
    }

    @Test func setNameMatchesIgnoringCaseAndDiacritics() {
        for query in ["deep", "DEEP", "Déep"] {
            #expect(BackgroundCatalogFilter.filter([deepSpace, cities], query: query).map(\.name) == ["Deep Space"])
        }
    }

    @Test func setNameMatchKeepsEveryImage() {
        #expect(BackgroundCatalogFilter.filter([deepSpace], query: "space") == [deepSpace])
    }

    @Test func imageTitleMatchKeepsOnlyTheMatchingImages() {
        let result = BackgroundCatalogFilter.filter([deepSpace, cities], query: "harbor")
        #expect(result.count == 1)
        #expect(result.first?.id == 1)
        #expect(result.first?.name == "Future Cities")
        #expect(result.first?.images.map(\.title) == ["Harbor Dawn"])
    }

    @Test func setsWithNoMatchingNameOrImageAreDropped() {
        #expect(BackgroundCatalogFilter.filter([deepSpace, cities], query: "zzz").isEmpty)
    }

    @Test func whitespaceOnlyQueryMatchesEverything() {
        for query in ["", "  \n"] {
            #expect(BackgroundCatalogFilter.filter([deepSpace, cities], query: query) == [deepSpace, cities])
        }
    }

    @Test func queryIsTrimmedBeforeMatching() {
        #expect(BackgroundCatalogFilter.filter([deepSpace, cities], query: " space ").map(\.name) == ["Deep Space"])
    }

    @Test func matchesTheDisplayTextNotTheRawText() {
        let set = BackgroundSet(id: 0, name: "De\u{200B}ep", images: [image("One")])
        #expect(BackgroundCatalogFilter.filter([set], query: "deep") == [set])
    }

    @Test func sectionsWithNoMatchingSetsAreHidden() {
        let a = state("a.example.com", sets: [deepSpace])
        let b = state("b.example.com", sets: [cities])
        #expect(BackgroundCatalogFilter.sections([a, b], query: "tokyo").map(\.id) == [b.url])
    }

    @Test func withoutAQueryEverySectionShowsIncludingUnloadedOnes() {
        let loaded = state("a.example.com", sets: [deepSpace])
        let unloaded = state("b.example.com", sets: nil)
        let sections = BackgroundCatalogFilter.sections([loaded, unloaded], query: " ")
        #expect(sections.map(\.id) == [loaded.url, unloaded.url])
        #expect(sections.last?.sets == [])
    }

    @Test func withAQueryUnloadedSectionsAreHidden() {
        let loaded = state("a.example.com", sets: [deepSpace])
        let unloaded = state("b.example.com", sets: nil)
        #expect(BackgroundCatalogFilter.sections([loaded, unloaded], query: "deep").map(\.id) == [loaded.url])
    }
}
