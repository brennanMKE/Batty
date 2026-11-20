// AppStateStore+ProjectSlotBackgrounds.swift

import Foundation

/// The Project slot a Pane or Tab opened as, and the checked value the
/// Project last gave it. `value` is nil when the slot had no background.
struct ProjectBackgroundSeed: Equatable {
    let slot: Int
    /// nil for the Pane's own value.
    let tab: Int?
    var value: TerminalBackgroundSettings?
}

extension ProjectLayout {
    /// Same Panes, kinds and Tab counts, so slot and Tab indexes still name
    /// the same levels.
    func hasSameBackgroundSlots(as other: ProjectLayout) -> Bool {
        let mine = panes
        let theirs = other.panes
        guard mine.count == theirs.count else { return false }
        return zip(mine, theirs).allSatisfy { $0.kind == $1.kind && $0.tabs.count == $1.tabs.count }
    }
}

extension AppStateStore {
    /// Applies the saved Pane and Tab backgrounds to each level of `session`
    /// still showing the value the Project gave it. A level the user changed
    /// keeps its value. A save that changes the layout's shape clears the
    /// seeds instead, because indexes can't say which level moved. Returns
    /// whether any level is now waiting for an image.
    func applyProjectSlotBackgrounds(previous: Project, saved: Project, to session: SessionRuntime) -> Bool {
        let panes = session.tree.allPanes
        guard previous.layout.hasSameBackgroundSlots(as: saved.layout) else {
            for pane in panes {
                pane.projectBackgroundSeed = nil
                for tab in pane.tabs { tab.projectBackgroundSeed = nil }
            }
            return false
        }
        guard previous.layout.backgroundEntries != saved.layout.backgroundEntries else { return false }
        let slots = saved.layout.panes
        var waiting = false

        func entry(for seed: ProjectBackgroundSeed) -> ProjectBackgroundEntry? {
            guard slots.indices.contains(seed.slot) else { return nil }
            let pane = slots[seed.slot]
            guard let tab = seed.tab else { return ProjectBackgroundEntry(background: pane.background, image: pane.image) }
            guard pane.tabs.indices.contains(tab) else { return nil }
            return ProjectBackgroundEntry(background: pane.tabs[tab].background, image: pane.tabs[tab].image)
        }

        // Returns the value to write, or nil when the level is left alone.
        func resolve(current: TerminalBackgroundSettings?, seed: inout ProjectBackgroundSeed, entry: ProjectBackgroundEntry)
            -> (settings: TerminalBackgroundSettings?, pending: ProjectTabImage?)? {
            let checked = entry.background.map(projectBackgrounds.checked)
            if current == seed.value {
                seed.value = checked?.settings
                if let problem = checked?.problem, session.projectBackgroundImageProblem == nil {
                    session.projectBackgroundImageProblem = problem
                }
                let pending = entry.background != nil && checked?.settings.imagePath == nil ? entry.image : nil
                return (checked?.settings, pending)
            }
            if Self.sameBackground(current, checked?.settings) { seed.value = current }
            return nil
        }

        for pane in panes where pane.kind == .terminal {
            if var seed = pane.projectBackgroundSeed, let entry = entry(for: seed) {
                if let write = resolve(current: pane.backgroundOverride, seed: &seed, entry: entry) {
                    pane.restoreBackgroundOverride(write.settings)
                    pane.pendingImage = write.pending
                    if write.pending != nil { waiting = true }
                }
                pane.projectBackgroundSeed = seed
            }
            for tab in pane.tabs {
                guard var seed = tab.projectBackgroundSeed, let entry = entry(for: seed) else { continue }
                if let write = resolve(current: tab.backgroundOverride, seed: &seed, entry: entry) {
                    tab.restoreBackgroundOverride(write.settings, pendingImage: write.pending)
                    if write.pending != nil { waiting = true }
                }
                tab.projectBackgroundSeed = seed
            }
        }
        return waiting
    }

    /// Equal, or equal apart from paths that hold the same image.
    private static func sameBackground(_ lhs: TerminalBackgroundSettings?, _ rhs: TerminalBackgroundSettings?) -> Bool {
        if lhs == rhs { return true }
        guard let lhs, let rhs, let left = lhs.imagePath, let right = rhs.imagePath,
              lhs.withImagePath(nil) == rhs.withImagePath(nil),
              let digest = TerminalBackgroundImageImporter.digest(ofPath: left)
        else { return false }
        return digest == TerminalBackgroundImageImporter.digest(ofPath: right)
    }
}
