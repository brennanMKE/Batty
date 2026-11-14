// BackgroundCatalogFilter.swift

import Foundation

/// The Background Sets filter field: a set whose name matches keeps every
/// image, otherwise only the images whose titles match.
nonisolated enum BackgroundCatalogFilter {
    struct Section: Identifiable, Equatable {
        let content: HostedCatalogContent
        let sets: [BackgroundSet]
        var id: URL { content.url }
    }

    static func normalizedQuery(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func matches(_ raw: String, query: String) -> Bool {
        BackgroundCatalogParser.displayText(raw).range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    static func filter(_ sets: [BackgroundSet], query raw: String) -> [BackgroundSet] {
        guard let query = normalizedQuery(raw) else { return sets }
        return sets.compactMap { set in
            if matches(set.name, query: query) { return set }
            let images = set.images.filter { matches($0.title, query: query) }
            return images.isEmpty ? nil : BackgroundSet(id: set.id, name: set.name, images: images)
        }
    }

    /// With a query, catalogs not loaded yet or with nothing matching are left out.
    static func sections(_ catalogs: [HostedCatalogContent], query: String) -> [Section] {
        guard normalizedQuery(query) != nil else {
            return catalogs.map { Section(content: $0, sets: $0.catalog?.sets ?? []) }
        }
        return catalogs.compactMap { content in
            let sets = filter(content.catalog?.sets ?? [], query: query)
            return sets.isEmpty ? nil : Section(content: content, sets: sets)
        }
    }
}
