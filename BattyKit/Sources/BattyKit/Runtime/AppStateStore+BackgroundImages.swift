// AppStateStore+BackgroundImages.swift

import Foundation

extension AppStateStore {
    /// `library` and `notificationCenter` are seams for tests' own folders.
    func makeBackgroundImagesModel(
        library: BackgroundImageLibrary? = nil,
        notificationCenter: NotificationCenter = .default
    ) -> BackgroundImagesModel {
        BackgroundImagesModel(
            library: library ?? BackgroundImageLibrary(
                directory: BackgroundImageLibrary.directory(forProjectsFile: projectsFileURL),
                sources: [
                    TerminalBackgroundImageImporter.appWideDirectory(),
                    projectBackgrounds.directory,
                    TerminalBackgroundImageImporter.defaultDirectory(),
                ]
            ),
            thumbnailer: BackgroundImageThumbnailer(),
            uses: { [weak self] in self?.backgroundImageUses() ?? [:] },
            refusal: { [weak self] in self?.removalRefusal(digest: $0) },
            clearUses: { [weak self] in try self?.clearBackgroundImageUses(digest: $0) },
            notificationCenter: notificationCenter
        )
    }

    /// From memory only, keyed by digest because a Session's override can name
    /// the Project folder's copy and a Pane's the Caches copy of one picture.
    /// Another running copy's Sessions and Panes can't be seen from here.
    func backgroundImageUses() -> [String: [BackgroundImageUse]] {
        var uses: [String: [BackgroundImageUse]] = [:]
        func record(_ path: String?, _ use: BackgroundImageUse) {
            guard let path, let digest = TerminalBackgroundImageImporter.digest(ofPath: path) else { return }
            uses[digest, default: []].append(use)
        }
        record(backgroundGate.storedSettings().imagePath, .appWide)
        let projectStore = self.projectStore
        for project in projectStore.projects {
            record(project.background?.imagePath, .project(id: project.id, name: project.name, isShared: project.isShared))
        }
        if let draft = openProjectEditorModel()?.draft {
            let saved = projectStore.project(id: draft.id)?.background?.imagePath
            let draftPath = draft.background?.imagePath
            if draftPath.flatMap(TerminalBackgroundImageImporter.digest(ofPath:)) != saved.flatMap(TerminalBackgroundImageImporter.digest(ofPath:)) {
                record(draftPath, .projectDraft)
            }
        }
        for session in windows.flatMap(\.sessions) {
            record(session.backgroundOverride?.imagePath, .session(id: session.id, title: session.title))
            for pane in session.tree.allPanes {
                record(pane.backgroundOverride?.imagePath, .pane(id: pane.id, sessionTitle: session.title))
            }
        }
        return uses
    }

    /// Why this image can't be removed now, the same rule as `reclaim`: if a
    /// Project this list doesn't show might name it, clearing the list's uses
    /// would leave that Project pointing at a deleted file.
    func removalRefusal(digest: String) -> String? {
        let projectStore = self.projectStore
        projectStore.retryLoadIfNeeded()
        let refusal = String(localized: "Batty can't read all of your saved Projects, so one of them may use this image. Nothing was removed.", comment: "Background Images: Remove refused because projects.json can't be trusted")
        if projectStore.mayReferenceUnlistedImages { return refusal }
        if projectStore.fileIsAbsent { return nil }
        guard projectStore.imagePathsInFile() != nil else { return refusal }
        if projectStore.fileNamesImageTheListDoesNot(digest: digest) {
            return String(localized: "Another running copy of Batty saved a Project that uses this image. Nothing was removed.", comment: "Background Images: Remove refused because projects.json names the image for a Project this copy hasn't loaded")
        }
        return nil
    }

    /// In this order so a failed Projects write leaves every use as it was.
    func clearBackgroundImageUses(digest: String) throws {
        func names(_ settings: TerminalBackgroundSettings?) -> Bool {
            settings?.imagePath.flatMap(TerminalBackgroundImageImporter.digest(ofPath:)) == digest
        }
        try projectStore.clearBackgroundImage(digest: digest)
        openProjectEditorModel()?.backgroundImageWasRemoved(digest: digest)
        if names(backgroundGate.storedSettings()) {
            AppWideBackgroundEditor(store: self).removeImage()
        }
        for session in windows.flatMap(\.sessions) {
            if names(session.projectBackgroundSeed) {
                session.projectBackgroundSeed = session.projectBackgroundSeed?.withImagePath(nil)
            }
            if names(session.backgroundOverride) {
                session.setBackgroundOverride(session.backgroundOverride?.withImagePath(nil))
            }
            for pane in session.tree.allPanes where names(pane.backgroundOverride) {
                pane.setBackgroundOverride(pane.backgroundOverride?.withImagePath(nil))
            }
        }
    }
}
