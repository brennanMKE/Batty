// ProjectRecency.swift

import Foundation

/// The single sorter behind every Projects list except the Project Editor's.
enum ProjectRecency {
    enum OpenPlacement: Sendable { case last, inPlace, first }

    static let defaultPlacement: OpenPlacement = .last

    /// `projects` in the order the user arranged them; returns them most
    /// recently opened first, then never-opened Projects in the given order.
    /// Equal dates keep the given order.
    static func ranked(
        _ projects: [Project],
        openProjectIDs: Set<UUID>,
        placement: OpenPlacement = defaultPlacement
    ) -> [Project] {
        let entries = projects.enumerated().sorted { a, b in
            if placement != .inPlace {
                let aOpen = openProjectIDs.contains(a.element.id)
                let bOpen = openProjectIDs.contains(b.element.id)
                if aOpen != bOpen { return placement == .first ? aOpen : bOpen }
            }
            switch (a.element.lastOpenedAt, b.element.lastOpenedAt) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }
        return entries.map(\.element)
    }
}
