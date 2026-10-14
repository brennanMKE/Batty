// ProjectPicker.swift

import BattyXPCCore
import CoreGraphics
import Foundation

/// What the Open Project picker asks its host to do once the sheet has
/// closed. Opening runs after dismissal so the startup-command trust sheet,
/// which presents from the same view, is not competing with a closing sheet.
enum ProjectPickerAction: Equatable {
    case open(UUID, AppStateStore.ProjectOpenMode)
    case edit(UUID)
    case newProject
}

enum ProjectPickerDirection {
    case left, right, up, down, home, end
}

struct ProjectPickerCard: Identifiable, Equatable {
    struct Slot: Equatable {
        var frame: CGRect
        var kind: PaneContentKind
    }

    let id: UUID
    let name: String
    let color: SessionColor
    let symbol: ProjectSymbol
    let displayPath: String
    let summary: String
    let isOpen: Bool
    let slots: [Slot]
    let lastOpenedAt: Date?
    let isShared: Bool
    let rootIsMissing: Bool
}

enum ProjectPickerTier: Equatable {
    case featured, rest, openNow
}

/// Where the selected card sits, so a re-rank that moves it can be noticed
/// even though its id did not change.
struct ProjectPickerPosition: Equatable {
    let id: UUID
    let tier: ProjectPickerTier
    let index: Int
}

enum ProjectPickerEscape: Equatable {
    case cleared
    case dismiss
}

enum ProjectPickerEmptyState: Equatable {
    case noProjects
    case noMatches
}

/// The picker's state and rules, free of views: which Projects show for a
/// filter, where the selection sits in the grid, what Return does and what
/// the hint line says.
struct ProjectPickerModel: Equatable {
    static let featuredCount = 3
    static let featuredColumns = 3
    static let restColumns = 4
    static let openNowColumns = 4

    private(set) var query = ""
    private(set) var selectedID: UUID?
    private var projects: [Project]
    private var openProjectIDs: Set<UUID>
    private let homeDirectory: String
    private let rootCache: RootExistenceCache

    /// Answers whether a root folder exists, once per root, and shares the
    /// answers across every copy of the model (`refreshed` returns copies),
    /// so the view's per-render path never repeats a check. It is a class
    /// so a copy made for one render writes back to the cache the next
    /// render reads. A folder created or deleted while the sheet is up is
    /// not noticed.
    final class RootExistenceCache: Equatable {
        private let exists: (String) -> Bool
        private var answers: [String: Bool] = [:]

        init(_ exists: @escaping (String) -> Bool) { self.exists = exists }

        func isMissing(_ path: String) -> Bool {
            if let known = answers[path] { return !known }
            let found = exists(path)
            answers[path] = found
            return !found
        }

        static func == (lhs: RootExistenceCache, rhs: RootExistenceCache) -> Bool { true }
    }

    init(
        projects: [Project],
        openProjectIDs: Set<UUID>,
        homeDirectory: String,
        rootExists: @escaping (String) -> Bool = { ProjectEditorViewModel.fileSystemDirectoryExists($0) }
    ) {
        let ranked = ProjectRecency.ranked(projects, openProjectIDs: openProjectIDs)
        self.projects = ranked
        self.openProjectIDs = openProjectIDs
        self.homeDirectory = homeDirectory
        rootCache = RootExistenceCache(rootExists)
        selectedID = ranked.first?.id
    }

    /// The same query and selection over current data, for a view that reads
    /// Projects and open Sessions live. The selection stays on its Project by
    /// id; if that Project is gone or filtered out, the best match is chosen.
    func refreshed(projects: [Project], openProjectIDs: Set<UUID>) -> ProjectPickerModel {
        var copy = self
        copy.projects = ProjectRecency.ranked(projects, openProjectIDs: openProjectIDs)
        copy.openProjectIDs = openProjectIDs
        if let selectedID, copy.filtered.contains(where: { $0.id == selectedID }) { return copy }
        copy.selectedID = copy.filtered.first?.id
        return copy
    }

    var cards: [ProjectPickerCard] {
        filtered.map(card(for:))
    }

    var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The cards split into the picker's three groups, derived once from the
    /// ranked list. With a blank query open Projects leave the two tiers for
    /// the Open now strip; `ProjectRecency` already ranks them last and in
    /// recency order, so this is a partition and not a sort. While filtering,
    /// every match is one compact grid and no strip shows.
    struct Tiers: Equatable {
        let featured: [ProjectPickerCard]
        let rest: [ProjectPickerCard]
        let openNow: [ProjectPickerCard]
    }

    var tiers: Tiers {
        let all = cards
        guard !isFiltering else { return Tiers(featured: [], rest: all, openNow: []) }
        let closed = all.filter { !$0.isOpen }
        return Tiers(
            featured: Array(closed.prefix(Self.featuredCount)),
            rest: Array(closed.dropFirst(Self.featuredCount)),
            openNow: all.filter(\.isOpen))
    }

    /// The first three closed Projects in ranked order; empty while filtering.
    var featured: [ProjectPickerCard] { tiers.featured }

    var rest: [ProjectPickerCard] { tiers.rest }

    var openNow: [ProjectPickerCard] { tiers.openNow }

    private var closedCount: Int {
        let tiers = tiers
        return tiers.featured.count + tiers.rest.count
    }

    var showsNewProjectCard: Bool {
        !isFiltering && !projects.isEmpty && closedCount < Self.featuredCount
    }

    /// The tier headings are drawn from three closed Projects up; below that
    /// the row holds the Projects and the New Project card on their own.
    var showsTierHeadings: Bool {
        !isFiltering && closedCount >= Self.featuredCount
    }

    var matchCountText: String {
        Self.matchCountText(cards.count)
    }

    static func matchCountText(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 match", comment: "Open Project picker: heading above the filtered Projects")
            : String(localized: "\(count) matches", comment: "Open Project picker: heading above the filtered Projects")
    }

    var selectedPosition: ProjectPickerPosition? {
        guard let selectedID else { return nil }
        return Self.position(of: selectedID, in: tiers)
    }

    private static func position(of id: UUID, in tiers: Tiers) -> ProjectPickerPosition? {
        let groups: [(ProjectPickerTier, [ProjectPickerCard])] = [
            (.featured, tiers.featured), (.rest, tiers.rest), (.openNow, tiers.openNow),
        ]
        for (tier, cards) in groups {
            if let index = cards.firstIndex(where: { $0.id == id }) {
                return ProjectPickerPosition(id: id, tier: tier, index: index)
            }
        }
        return nil
    }

    var cursor: ProjectPickerGridCursor {
        Self.cursor(for: tiers)
    }

    private static func cursor(for tiers: Tiers) -> ProjectPickerGridCursor {
        ProjectPickerGridCursor(sections: [
            .init(columns: featuredColumns, count: tiers.featured.count),
            .init(columns: restColumns, count: tiers.rest.count),
            .init(columns: openNowColumns, count: tiers.openNow.count),
        ])
    }

    var selectedCard: ProjectPickerCard? {
        guard let selectedID else { return nil }
        return cards.first { $0.id == selectedID }
    }

    var emptyState: ProjectPickerEmptyState? {
        if projects.isEmpty { return .noProjects }
        return filtered.isEmpty ? .noMatches : nil
    }

    /// A new filter selects its best match, because the old selection may
    /// have been filtered out and the best match is where Return should land.
    mutating func setQuery(_ newValue: String) {
        guard newValue != query else { return }
        query = newValue
        selectedID = filtered.first?.id
    }

    mutating func select(_ id: UUID) {
        guard filtered.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Escape clears a filter first and asks to dismiss only when there is none.
    mutating func escape() -> ProjectPickerEscape {
        guard isFiltering else { return .dismiss }
        setQuery("")
        return .cleared
    }

    /// The cursor decides where each direction lands over the tiers in
    /// reading order (see `ProjectPickerGridCursor`).
    mutating func move(_ direction: ProjectPickerDirection) {
        let tiers = tiers
        let visible = tiers.featured + tiers.rest + tiers.openNow
        guard !visible.isEmpty else { return }
        guard let selectedID, let index = visible.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = visible[0].id
            return
        }
        self.selectedID = visible[Self.cursor(for: tiers).moved(from: index, direction)].id
    }

    /// Return opens, focusing the open Session if there is one; Option-Return
    /// always opens another.
    func openAction(optionHeld: Bool) -> ProjectPickerAction? {
        guard let selectedID else { return nil }
        return .open(selectedID, optionHeld ? .openNew : .focusExistingOrOpen)
    }

    /// The Open now chip's `+` button: a plain click that opens another copy
    /// of a Project that is open; a closed Project has no such affordance.
    func anotherCopyAction(for id: UUID) -> ProjectPickerAction? {
        guard openProjectIDs.contains(id), projects.contains(where: { $0.id == id }) else { return nil }
        return .open(id, .openNew)
    }

    func editAction() -> ProjectPickerAction? {
        selectedID.map { .edit($0) }
    }

    var hint: String {
        guard let card = selectedCard else { return "" }
        return Self.hint(name: card.name, isOpen: card.isOpen)
    }

    static func hint(name: String, isOpen: Bool) -> String {
        isOpen
            ? String(localized: "\u{21A9} Switch to the open \(name) Session", comment: "Open Project picker: hint for a Project that already has an open Session")
            : String(localized: "\u{21A9} Open \(name) in a new Session", comment: "Open Project picker: hint for a Project with no open Session")
    }

    static func summary(panes: Int, tabs: Int, startupCommands: Int) -> String {
        let paneText = panes == 1
            ? String(localized: "1 pane", comment: "Open Project picker: Project summary")
            : String(localized: "\(panes) panes", comment: "Open Project picker: Project summary")
        let tabText = tabs == 1
            ? String(localized: "1 tab", comment: "Open Project picker: Project summary")
            : String(localized: "\(tabs) tabs", comment: "Open Project picker: Project summary")
        let commandText: String
        switch startupCommands {
        case 0: commandText = String(localized: "no startup commands", comment: "Open Project picker: Project summary")
        case 1: commandText = String(localized: "1 startup command", comment: "Open Project picker: Project summary")
        default: commandText = String(localized: "\(startupCommands) startup commands", comment: "Open Project picker: Project summary")
        }
        return "\(paneText) \u{00B7} \(tabText) \u{00B7} \(commandText)"
    }

    /// Replaces a leading home directory with `~`, only on a path-component
    /// boundary, so `/Users/bob2/x` is not shortened for home `/Users/bob`.
    static func abbreviate(path: String, homeDirectory: String) -> String {
        let home = homeDirectory.count > 1 && homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private var filtered: [Project] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return projects }
        let scored: [(offset: Int, project: Project, score: Int)] = projects.enumerated().compactMap { offset, project in
            let nameScore = FuzzyMatcher.score(trimmed, in: project.name) * 2
            let shownPath = Self.abbreviate(path: project.rootPath, homeDirectory: homeDirectory)
            let pathMatches = [project.rootPath, shownPath].contains { $0.range(of: trimmed, options: .caseInsensitive) != nil }
            let pathScore = pathMatches ? 1 : 0
            let best = max(nameScore, pathScore)
            return best > 0 ? (offset, project, best) : nil
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.project)
    }

    private func card(for project: Project) -> ProjectPickerCard {
        let frames = project.layout.slotFrames
        let panes = project.layout.panes
        return ProjectPickerCard(
            id: project.id,
            name: project.name,
            color: project.color,
            symbol: project.symbol,
            displayPath: Self.abbreviate(path: project.rootPath, homeDirectory: homeDirectory),
            summary: Self.summary(panes: project.paneCount, tabs: project.tabCount, startupCommands: project.startupCommandCount),
            isOpen: openProjectIDs.contains(project.id),
            slots: zip(frames, panes).map { ProjectPickerCard.Slot(frame: $0, kind: $1.kind) },
            lastOpenedAt: project.lastOpenedAt,
            isShared: project.isShared,
            rootIsMissing: rootCache.isMissing(project.rootPath)
        )
    }
}
