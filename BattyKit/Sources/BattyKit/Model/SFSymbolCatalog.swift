// SFSymbolCatalog.swift

import AppKit
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SFSymbolCatalog")

/// The SF Symbol names the Project symbol picker offers. macOS has no public
/// API to enumerate SF Symbols, so the names ship as the `SFSymbolNames.txt`
/// resource (its header says how to regenerate it) and are filtered at load
/// by the minimum macOS version each symbol needs, not by probing the OS.
nonisolated struct SFSymbolCatalog: Sendable, Equatable {
    struct Entry: Equatable, Sendable {
        let name: String
        /// First macOS major version that ships the symbol; 0 when unknown.
        let minMacOS: Int
    }

    /// Lowercase names in resource order.
    let names: [String]

    init(names: [String], isAvailable: (String) -> Bool = { _ in true }) {
        var seen = Set<String>()
        self.names = names.filter { seen.insert($0).inserted && isAvailable($0) }
    }

    /// Entries whose `minMacOS` is at most `osMajor`.
    init(entries: [Entry], osMajor: Int) {
        self.init(names: entries.filter { $0.minMacOS <= osMajor }.map(\.name))
    }

    /// `name<TAB>macOSMajor` per line; a line with no version gets 0. Blank
    /// lines and lines starting with `#` are skipped.
    static func parse(_ text: String) -> [Entry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return Entry(name: name, minMacOS: parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 : 0)
        }
    }

    static func systemDraws(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// Filters by version only, with no per-symbol probing, so it is cheap
    /// enough for the main actor. The 37 curated glyph names are always kept.
    @MainActor
    static func bundled(
        osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        legacyNames: [String] = ProjectSymbol.allCases.map(\.systemName)
    ) -> SFSymbolCatalog {
        guard let url = Bundle.module.url(forResource: "SFSymbolNames", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("SFSymbolNames.txt is missing; the picker offers only the suggested symbols")
            return SFSymbolCatalog(names: legacyNames)
        }
        let entries = parse(text) + legacyNames.map { Entry(name: $0, minMacOS: 0) }
        return SFSymbolCatalog(entries: entries, osMajor: osMajor)
    }

    /// Built once per process, on first use.
    @MainActor
    static let shared = SFSymbolCatalog.bundled()

    /// Names containing every whitespace-separated word of `query`, ignoring
    /// case. An empty query matches everything. Results are ranked exact match,
    /// then prefix matches, then other matches, in catalog order within each
    /// group, so typing a full name and pressing Return picks it.
    func filtered(_ query: String) -> [String] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return names }
        let whole = words.joined(separator: " ")
        var exact: [String] = []
        var prefix: [String] = []
        var rest: [String] = []
        for name in names where words.allSatisfy({ name.contains($0) }) {
            if name == whole { exact.append(name) } else if name.hasPrefix(whole) { prefix.append(name) } else { rest.append(name) }
        }
        return exact + prefix + rest
    }

    /// What the picker lists for `query`: with an empty query the suggested
    /// (legacy) symbols first, then every other name; otherwise the matches
    /// alone. `suggestedCount` is how many leading entries are suggestions.
    @MainActor
    func listing(for query: String) -> (names: [String], suggestedCount: Int) {
        let hasQuery = !query.trimmingCharacters(in: .whitespaces).isEmpty
        guard !hasQuery else { return (filtered(query), 0) }
        let suggested = ProjectSymbol.allCases.map(\.systemName).filter { ProjectSymbol.exists($0) }
        let suggestedSet = Set(suggested)
        return (suggested + names.filter { !suggestedSet.contains($0) }, suggested.count)
    }
}
