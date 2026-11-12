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

    var tabImageIdentity: TabImageIdentity { TabImageIdentity(projectsFile: projectsFileURL) }

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
        func digests(_ paths: [String]) -> Set<String> {
            Set(paths.compactMap(TerminalBackgroundImageImporter.digest(ofPath:)))
        }
        for project in projectStore.projects {
            let use = BackgroundImageUse.project(id: project.id, name: project.name, isShared: project.isShared)
            var seen = Set<String>()
            for path in project.allBackgroundImagePaths {
                guard let digest = TerminalBackgroundImageImporter.digest(ofPath: path), seen.insert(digest).inserted else { continue }
                record(path, use)
            }
        }
        if let draft = openProjectEditorModel()?.draft {
            let saved = projectStore.project(id: draft.id)
            let savedPath = saved?.background?.imagePath
            let draftPath = draft.background?.imagePath
            if draftPath.flatMap(TerminalBackgroundImageImporter.digest(ofPath:)) != savedPath.flatMap(TerminalBackgroundImageImporter.digest(ofPath:)) {
                record(draftPath, .projectDraft)
            }
            let savedTabs = digests(saved?.tabBackgroundImagePaths ?? [])
            var seen = digests(draftPath.map { [$0] } ?? [])
            for path in draft.makeProject().tabBackgroundImagePaths {
                guard let digest = TerminalBackgroundImageImporter.digest(ofPath: path),
                      !savedTabs.contains(digest), seen.insert(digest).inserted
                else { continue }
                record(path, .projectDraft)
            }
        }
        for session in windows.flatMap(\.sessions) {
            record(session.backgroundOverride?.imagePath, .session(id: session.id, title: session.title))
            for pane in session.tree.allPanes {
                record(pane.backgroundOverride?.imagePath, .pane(id: pane.id, sessionTitle: session.title))
                guard pane.kind == .terminal else { continue }
                for tab in pane.tabs {
                    record(tab.backgroundOverride?.imagePath, .tab(id: tab.id, sessionTitle: session.title))
                }
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
        // The Tabs keep their identities, so a later open downloads it again.
        let cache = downloadedImages
        tabImageRequest = Task { await cache.remove(digest: digest) }
        if names(backgroundGate.storedSettings()) {
            AppWideBackgroundEditor(store: self).removeImage()
        }
        for session in windows.flatMap(\.sessions) {
            if names(session.backgroundOverride) {
                session.setBackgroundOverride(session.backgroundOverride?.withImagePath(nil))
            }
            for pane in session.tree.allPanes {
                for tab in pane.tabs {
                    if names(tab.backgroundOverride) {
                        tab.setBackgroundOverride(tab.backgroundOverride?.withImagePath(nil))
                    }
                }
                // Removing an image is not a Pane edit, so it keeps the Tabs'
                // own values and pending images that a Pane write would end.
                if names(pane.backgroundOverride) {
                    pane.restoreBackgroundOverride(pane.backgroundOverride?.withImagePath(nil))
                }
            }
        }
    }

    /// Opening doesn't wait for this. A local Project has nothing to reconcile,
    /// so opening one can't be what first reaches the folder.
    func reconcileSharedImage(of project: Project) {
        guard project.isShared, project.sharedImage?.digest != nil else { return }
        sharedProjectImages?.reconcile(userInitiated: true)
    }

    /// Only an open Session still waiting for the image gets it; one whose
    /// background the user changed keeps their value. Applying it ends the
    /// wait.
    func sharedImageArrived(project: Project, path: String) {
        for session in windows.flatMap(\.sessions) where session.projectID == project.id {
            session.arrivedProjectImagePath = path
        }
        for session in windows.flatMap(\.sessions) where session.projectID == project.id && session.pendingProjectImage {
            guard let current = session.backgroundOverride else { continue }
            session.setBackgroundOverride(current.withImagePath(path))
        }
        openProjectEditorModel()?.sharedImageArrived(projectID: project.id, path: path)
    }
}
