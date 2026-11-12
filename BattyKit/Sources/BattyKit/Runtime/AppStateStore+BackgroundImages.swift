// AppStateStore+BackgroundImages.swift

import Foundation

extension AppStateStore {
    /// `library` and `notificationCenter` are seams for tests' own folders.
    /// `hosting` is the seam for tests' fake fetcher, folders and clock.
    func makeBackgroundImagesModel(
        library: BackgroundImageLibrary? = nil,
        notificationCenter: NotificationCenter = .default,
        hosting: HostedBackgroundsDependencies? = nil
    ) -> BackgroundImagesModel {
        let libraryDirectory = library?.directory ?? BackgroundImageLibrary.directory(forProjectsFile: projectsFileURL)
        let hostedDirectory = libraryDirectory.appendingPathComponent("Hosted", isDirectory: true)
        return BackgroundImagesModel(
            library: library ?? BackgroundImageLibrary(
                directory: libraryDirectory,
                sources: [
                    TerminalBackgroundImageImporter.appWideDirectory(),
                    projectBackgrounds.directory,
                    TerminalBackgroundImageImporter.defaultDirectory(),
                ],
                hostedDirectory: hostedDirectory
            ),
            thumbnailer: BackgroundImageThumbnailer(),
            uses: { [weak self] in self?.backgroundImageUses() ?? [:] },
            refusal: { [weak self] in self?.removalRefusal(digest: $0) },
            clearUses: { [weak self] in try self?.clearBackgroundImageUses(digest: $0) },
            notificationCenter: notificationCenter,
            sharedImages: { [weak self] in self?.sharedProjectImages },
            hosted: HostedBackgroundsModel(
                imageDirectory: hostedDirectory,
                dependencies: hosting ?? Self.liveHostedDependencies(),
                defaults: preferences
            )
        )
    }

    /// Launch and daily catalog checks. A UI-test launch without a catalog
    /// fixture folder never starts them, so no UI run reaches the website.
    public func startBackgroundCatalogChecks(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let isUITestLaunch = environment.keys.contains { $0.hasPrefix("BATTY_UI_TEST_") }
        if isUITestLaunch, UITestDriver.backgroundCatalogFixtureDirectory(environment: environment) == nil { return }
        backgroundCatalogScheduler.start()
    }

    /// A UI-test launch with a fixture folder serves the catalog from disk and
    /// keeps its cache beside it, so no run reaches the website.
    static func liveHostedDependencies() -> HostedBackgroundsDependencies {
        if let fixture = UITestDriver.backgroundCatalogFixtureDirectory() {
            return HostedBackgroundsDependencies(
                fetcher: FixtureBackgroundCatalogFetcher(directory: fixture),
                cacheRoot: fixture.deletingLastPathComponent().appendingPathComponent("BackgroundCatalogCache", isDirectory: true),
                temporaryRoot: HostedImageStore.defaultTemporaryRoot(),
                clock: SystemClock()
            )
        }
        return HostedBackgroundsDependencies(
            fetcher: URLSessionBackgroundCatalogFetcher(),
            cacheRoot: BackgroundCatalogCache.defaultRoot(),
            temporaryRoot: HostedImageStore.defaultTemporaryRoot(),
            clock: SystemClock()
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

    /// Opening doesn't wait for this. A local Project has nothing to reconcile,
    /// so opening one can't be what first reaches the folder.
    func reconcileSharedImage(of project: Project) {
        guard project.isShared, project.sharedImage?.digest != nil else { return }
        sharedProjectImages?.reconcile(userInitiated: true)
    }

    /// An open Session the user hasn't changed gets the image on both its seed
    /// and override, so `SaveSessionAsProject` doesn't read this as their edit.
    func sharedImageArrived(project: Project, path: String) {
        for session in windows.flatMap(\.sessions) where session.projectID == project.id {
            guard let seed = session.projectBackgroundSeed, session.backgroundOverride == seed else { continue }
            let updated = seed.withImagePath(path)
            session.projectBackgroundSeed = updated
            session.setBackgroundOverride(updated)
        }
        openProjectEditorModel()?.sharedImageArrived(projectID: project.id, path: path)
    }
}
