// SaveSessionAsProjectMenu.swift

import Foundation

/// What the Sidebar, File menu and Command Palette offer for "save this
/// Session as a Project", as data. A Session opened from a stored Project also
/// offers to update that Project; the plain item then means "as a new one".
struct SaveSessionAsProjectMenuModel: Equatable {
    struct UpdateTarget: Equatable {
        let id: UUID
        let name: String
    }

    /// Whether there is a Session to capture.
    let isEnabled: Bool
    let updateTarget: UpdateTarget?

    /// `backingProject` is the stored Project the Session was opened from,
    /// nil for any other Session or after that Project was deleted.
    static func make(hasSession: Bool, backingProject: Project?) -> SaveSessionAsProjectMenuModel {
        return SaveSessionAsProjectMenuModel(
            isEnabled: hasSession,
            updateTarget: backingProject.map { UpdateTarget(id: $0.id, name: $0.name) }
        )
    }
}
