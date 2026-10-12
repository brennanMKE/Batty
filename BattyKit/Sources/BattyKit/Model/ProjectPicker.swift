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
    case left, right, up, down
}

struct ProjectPickerCard: Identifiable, Equatable {
    struct Slot: Equatable {
        var frame: CGRect
        var kind: PaneContentKind
    }

    let id: UUID
    let name: String
    let color: SessionColor
    let displayPath: String
    let summary: String
    let isOpen: Bool
    let slots: [Slot]
}

enum ProjectPickerEmptyState: Equatable {
    case noProjects
    case noMatches
}

/// The picker's state and rules, free of views: which Projects show for a
/// filter, where the selection sits in the grid, what Return does and what
/// the hint line says.
struct ProjectPickerModel: Equatable {
    static let columnCount = 3

    private(set) var query = ""
    private(set) var selectedID: UUID?
    private var projects: [Project]
    private var openProjectIDs: Set<UUID>
    private let homeDirectory: String

    init(projects: [Project], openProjectIDs: Set<UUID>, homeDirectory: String) {
        self.projects = projects
        self.openProjectIDs = openProjectIDs
        self.homeDirectory = homeDirectory
        selectedID = projects.first?.id
    }

    /// The same query and selection over current data, for a view that reads
    /// Projects and open Sessions live. The selection stays on its Project by
    /// id; if that Project is gone or filtered out, the best match is chosen.
    func refreshed(projects: [Project], openProjectIDs: Set<UUID>) -> ProjectPickerModel {
        var copy = self
        copy.projects = projects
        copy.openProjectIDs = openProjectIDs
        if let selectedID, copy.filtered.contains(where: { $0.id == selectedID }) { return copy }
        copy.selectedID = copy.filtered.first?.id
        return copy
    }

    var cards: [ProjectPickerCard] {
        filtered.map(card(for:))
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

    /// Left and right step through the cards in reading order; up and down
    /// jump a row. Nothing wraps. Down from a row the next row cannot fully
    /// reach lands on the last card, so a short last row stays reachable.
    mutating func move(_ direction: ProjectPickerDirection) {
        let visible = filtered
        guard !visible.isEmpty else { return }
        guard let selectedID, let index = visible.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = visible[0].id
            return
        }
        let columns = Self.columnCount
        let target: Int
        switch direction {
        case .left:
            target = max(index - 1, 0)
        case .right:
            target = min(index + 1, visible.count - 1)
        case .up:
            target = index - columns >= 0 ? index - columns : index
        case .down:
            if index + columns < visible.count {
                target = index + columns
            } else if index / columns < (visible.count - 1) / columns {
                target = visible.count - 1
            } else {
                target = index
            }
        }
        self.selectedID = visible[target].id
    }

    /// Return opens, focusing the open Session if there is one; Option-Return
    /// always opens another.
    func openAction(optionHeld: Bool) -> ProjectPickerAction? {
        guard let selectedID else { return nil }
        return .open(selectedID, optionHeld ? .openNew : .focusExistingOrOpen)
    }

    func editAction() -> ProjectPickerAction? {
        selectedID.map { .edit($0) }
    }

    var hint: String {
        guard let card = selectedCard else { return "" }
        return card.isOpen
            ? String(localized: "\u{21A9} Switch to the open \(card.name) Session", comment: "Open Project picker: hint for a Project that already has an open Session")
            : String(localized: "\u{21A9} Open \(card.name) in a new Session", comment: "Open Project picker: hint for a Project with no open Session")
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
            displayPath: Self.abbreviate(path: project.rootPath, homeDirectory: homeDirectory),
            summary: Self.summary(panes: project.paneCount, tabs: project.tabCount, startupCommands: project.startupCommandCount),
            isOpen: openProjectIDs.contains(project.id),
            slots: zip(frames, panes).map { ProjectPickerCard.Slot(frame: $0, kind: $1.kind) }
        )
    }
}
