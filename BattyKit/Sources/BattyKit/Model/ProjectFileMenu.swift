// ProjectFileMenu.swift

import Foundation

/// The File menu's Open Project submenu as data, so what it lists, in what
/// order and which Projects carry a check mark is testable without a menu.
struct ProjectFileMenuModel: Equatable {
    enum Item: Equatable, Identifiable {
        case project(id: UUID, name: String, symbol: ProjectSymbol, isOpen: Bool, customSymbolName: String? = nil)
        case divider
        case projects
        case newProject

        var id: String {
            switch self {
            case .project(let id, _, _, _, _): "project:\(id.uuidString)"
            case .divider: "divider"
            case .projects: "projects"
            case .newProject: "newProject"
            }
        }
    }

    let items: [Item]

    static func make(projects: [Project], openProjectIDs: Set<UUID>) -> ProjectFileMenuModel {
        var items: [Item] = ProjectRecency.ranked(projects, openProjectIDs: openProjectIDs).map { .project(id: $0.id, name: $0.name, symbol: $0.symbol, isOpen: openProjectIDs.contains($0.id), customSymbolName: $0.customSymbolName) }
        if !items.isEmpty { items.append(.divider) }
        items.append(.projects)
        items.append(.newProject)
        return ProjectFileMenuModel(items: items)
    }

    /// The Project the Projects… item selects in the editor: the Session's
    /// Project while it still exists. Nil while the editor is already open,
    /// because a selection request on a dirty editor raises the unsaved-changes
    /// prompt, and bringing the window forward should never interrupt an edit.
    static func editorSelection(projectID: UUID?, projects: [Project], editorIsOpen: Bool) -> UUID? {
        guard !editorIsOpen, let projectID, projects.contains(where: { $0.id == projectID }) else { return nil }
        return projectID
    }
}
