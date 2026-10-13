// ProjectFileMenu.swift

import Foundation

/// The File menu's Open Project submenu as data, so what it lists, in what
/// order and which Projects carry a check mark is testable without a menu.
/// Nil while the Projects flag is off: the submenu is absent, not disabled.
struct ProjectFileMenuModel: Equatable {
    enum Item: Equatable, Identifiable {
        case project(id: UUID, name: String, symbol: ProjectSymbol, isOpen: Bool)
        case divider
        case chooseProject
        case newProject

        var id: String {
            switch self {
            case .project(let id, _, _, _): "project:\(id.uuidString)"
            case .divider: "divider"
            case .chooseProject: "chooseProject"
            case .newProject: "newProject"
            }
        }
    }

    let items: [Item]

    static func make(featureEnabled: Bool, projects: [Project], openProjectIDs: Set<UUID>) -> ProjectFileMenuModel? {
        guard featureEnabled else { return nil }
        var items: [Item] = projects.map { .project(id: $0.id, name: $0.name, symbol: $0.symbol, isOpen: openProjectIDs.contains($0.id)) }
        if !items.isEmpty { items.append(.divider) }
        items.append(.chooseProject)
        items.append(.newProject)
        return ProjectFileMenuModel(items: items)
    }
}
