// AppStateStore+ProjectLink.swift

import AppKit

extension AppStateStore {
    /// Makes the live Session `source` names a Session of `project` without
    /// touching its terminals: link, symbol, name, color, Theme, mute and
    /// every background level. Nil when that Session has closed.
    @discardableResult
    func linkSession(_ source: ProjectSessionSource, to project: Project) -> SessionRuntime? {
        linkSession(source, to: project, isDark: NSApp?.effectiveAppearance.isDark ?? true)
    }

    @discardableResult
    func linkSession(_ source: ProjectSessionSource, to project: Project, isDark: Bool) -> SessionRuntime? {
        guard let window = windowOwning(sessionID: source.sessionID),
              let session = window.sessions.first(where: { $0.id == source.sessionID })
        else { return nil }
        // Already linked: `applyProjectSave` brought it up to date.
        guard session.projectID != project.id else { return session }
        let resolution = project.tabImages.isEmpty ? (project: project, cachedDigests: Set<String>()) : resolveTabImages(of: project)
        window.applyProjectIdentity(project, to: session)
        seedProjectBackground(project, on: session)
        let waiting = applyLinkedSlotBackgrounds(resolution.project, source: source, to: session)
        applyActiveSessionTheme(for: session, isDark: isDark)
        if waiting { requestTabImages(for: resolution.project, touching: resolution.cachedDigests) }
        reconcileSharedImage(of: project)
        return session
    }

    /// Writes each slot's saved background onto the Pane or Tab it was
    /// captured from and seeds it as `ProjectTreeBuilder` does at open. When
    /// the layout no longer matches the live Session, clears every seed and
    /// leaves the backgrounds alone. Returns whether any level is waiting for
    /// an image.
    private func applyLinkedSlotBackgrounds(_ project: Project, source: ProjectSessionSource, to session: SessionRuntime) -> Bool {
        let panes = session.tree.allPanes
        let slots = project.layout.panes
        var matched: [(slot: Int, pane: PaneRuntime, tabs: [TabRuntime])] = []
        var shapeMatches = slots.count == source.paneIDs.count
        if shapeMatches {
            for (slot, stored) in slots.enumerated() {
                guard let paneID = source.paneIDs[slot],
                      let pane = panes.first(where: { $0.id == paneID }),
                      pane.kind == stored.kind
                else { shapeMatches = false; break }
                guard pane.kind == .terminal else { continue }
                let tabIDs = source.tabIDs[slot] ?? []
                let tabs = tabIDs.compactMap { id in pane.tabs.first(where: { $0.id == id }) }
                guard tabIDs.count == stored.tabs.count, tabs.count == tabIDs.count else { shapeMatches = false; break }
                matched.append((slot, pane, tabs))
            }
        }
        guard shapeMatches else {
            for pane in panes {
                pane.projectBackgroundSeed = nil
                for tab in pane.tabs { tab.projectBackgroundSeed = nil }
            }
            return false
        }
        var waiting = false
        func note(_ problem: BackgroundImageState?) {
            if let problem, session.projectBackgroundImageProblem == nil { session.projectBackgroundImageProblem = problem }
        }
        for (slot, pane, tabs) in matched {
            let stored = slots[slot]
            let checked = stored.background.map(projectBackgrounds.checked)
            note(checked?.problem)
            pane.restoreBackgroundOverride(checked?.settings)
            let pending = stored.background != nil && checked?.settings.imagePath == nil ? stored.image : nil
            if pane.pendingImage != pending { pane.pendingImage = pending }
            if pending != nil { waiting = true }
            pane.projectBackgroundSeed = ProjectBackgroundSeed(slot: slot, tab: nil, value: pane.backgroundOverride)
            for (index, tab) in tabs.enumerated() {
                let storedTab = stored.tabs[index]
                let tabChecked = storedTab.background.map(projectBackgrounds.checked)
                note(tabChecked?.problem)
                let tabPending = storedTab.background != nil && tabChecked?.settings.imagePath == nil ? storedTab.image : nil
                tab.restoreBackgroundOverride(tabChecked?.settings, pendingImage: tabPending)
                if tabPending != nil { waiting = true }
                tab.projectBackgroundSeed = ProjectBackgroundSeed(slot: slot, tab: index, value: tab.backgroundOverride)
            }
        }
        return waiting
    }
}
