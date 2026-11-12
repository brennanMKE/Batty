// AppStateStore+TabImages.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppStateStore+TabImages")

/// A Project Tab names its image by identity. This finds a copy on this Mac, or
/// downloads one into the cache, only when the user opens the Project or the
/// Project Editor shows it.
extension AppStateStore {
    func makeDownloadedImageCache() -> DownloadedImageCache {
        let dependencies = Self.liveHostedDependencies()
        return DownloadedImageCache(
            directory: tabImageIdentity.downloadedDirectory,
            fetcher: dependencies.fetcher,
            temporaryRoot: dependencies.temporaryRoot
        )
    }

    /// Records a local copy for each Tab whose identity has no usable path.
    /// Returns the Project as stored afterwards and the cached digests it used.
    func resolveTabImages(of project: Project) -> (project: Project, cachedDigests: Set<String>) {
        let identity = tabImageIdentity
        let library = projectBackgrounds
        var cachedDigests = Set<String>()
        var found: [ProjectTabImage: String] = [:]
        for tab in project.layout.backgroundEntries {
            guard let image = tab.image, let background = tab.background, found[image] == nil else { continue }
            if let path = background.imagePath, library.imageState(ofPath: path) == .usable {
                if path.hasPrefix(identity.downloadedDirectory.path), let digest = TerminalBackgroundImageImporter.digest(ofPath: path) {
                    cachedDigests.insert(digest)
                }
                continue
            }
            if let local = localCopy(of: image, identity: identity, library: library) {
                found[image] = local.path
                if local.cached, let digest = TerminalBackgroundImageImporter.digest(ofPath: local.path) { cachedDigests.insert(digest) }
            }
        }
        for (image, path) in found {
            do {
                try projectStore.setResolvedTabImage(projectID: project.id, identity: image, path: path)
            } catch {
                logger.error("could not record a Tab image path: \(error.localizedDescription, privacy: .public)")
            }
        }
        return (projectStore.project(id: project.id) ?? project, cachedDigests)
    }

    private func localCopy(of image: ProjectTabImage, identity: TabImageIdentity, library: ProjectBackgroundLibrary) -> (path: String, cached: Bool)? {
        let cached = DownloadedImageIndex.entries(in: identity.downloadedDirectory)
        switch image {
        case .custom(let digest, _):
            if let path = TerminalBackgroundImageImporter.existingCopy(digest: digest, in: library.directory) { return (path, false) }
            if cached.contains(where: { $0.digest == digest }),
               let path = TerminalBackgroundImageImporter.existingCopy(digest: digest, in: identity.downloadedDirectory) {
                return (path, true)
            }
        case .hosted(let url, _):
            if let record = HostedImageStore.records(in: identity.hostedDirectory).last(where: { $0.url == url }),
               let hosted = TerminalBackgroundImageImporter.existingCopy(digest: record.digest, in: identity.hostedDirectory),
               let adopted = TerminalBackgroundImageImporter.adopt(path: hosted, from: [identity.hostedDirectory], into: library.directory) {
                return (adopted, false)
            }
            if let entry = cached.last(where: { $0.url == url }),
               let path = TerminalBackgroundImageImporter.existingCopy(digest: entry.digest, in: identity.downloadedDirectory) {
                return (path, true)
            }
        }
        return nil
    }

    /// Starts one download per identity still pending, deduped across
    /// Sessions, and marks `touching` as recently used. Nothing is requested
    /// for a custom image without a transport.
    @discardableResult
    func requestTabImages(for project: Project, touching: Set<String> = []) -> Task<Void, Never> {
        let cache = downloadedImages
        var pending: [ProjectTabImage] = []
        for tab in project.layout.backgroundEntries {
            guard let image = tab.image, tab.background != nil, tab.background?.imagePath == nil, !pending.contains(image) else { continue }
            pending.append(image)
        }
        var started: [Task<Void, Never>] = []
        for image in pending {
            if let running = tabImageDownloads[image] {
                started.append(running)
                continue
            }
            switch image {
            case .hosted(let url, let name):
                let task = startHostedDownload(url: url, name: name, image: image, projectID: project.id, cache: cache)
                tabImageDownloads[image] = task
                started.append(task)
            case .custom(let digest, let name):
                sharedProjectImages?.requestTabImage(digest: digest, name: name, projectID: project.id)
            }
        }
        let task = Task {
            for digest in touching { await cache.touch(digest: digest) }
            for download in started { await download.value }
        }
        tabImageRequest = task
        return task
    }

    private func startHostedDownload(url: URL, name: String, image: ProjectTabImage, projectID: UUID, cache: DownloadedImageCache) -> Task<Void, Never> {
        let hosts = tabImageAllowedHosts
        let pinned = pinnedDownloadedDigests()
        return Task { [weak self] in
            let result: Result<DownloadedImageCache.Insertion, HostedImageError>
            do throws(HostedImageError) {
                result = .success(try await cache.fetchHosted(url: url, name: name, allowedHosts: hosts, pinned: pinned))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            tabImageDownloads[image] = nil
            switch result {
            case .success(let insertion):
                tabImagesEvicted(insertion.evicted)
                tabImageArrived(projectID: projectID, identity: image, path: insertion.path)
            case .failure(let error):
                logger.error("a Tab image download failed: \(String(describing: error), privacy: .public)")
                for session in windows.flatMap(\.sessions) where session.projectID == projectID && session.projectBackgroundImageProblem == nil {
                    session.projectBackgroundImageProblem = .missing
                }
            }
        }
    }

    /// The cache never evicts these: images something on this Mac shows or is
    /// waiting for. Stored Project definitions don't pin, or nothing a Project
    /// names could ever be evicted.
    func pinnedDownloadedDigests() -> Set<String> {
        var digests = Set<String>()
        func pin(_ settings: TerminalBackgroundSettings?) {
            if let digest = settings?.imagePath.flatMap(TerminalBackgroundImageImporter.digest(ofPath:)) { digests.insert(digest) }
        }
        pin(backgroundGate.storedSettings())
        for session in windows.flatMap(\.sessions) {
            pin(session.backgroundOverride)
            for pane in session.tree.allPanes {
                pin(pane.backgroundOverride)
                if let digest = pane.pendingImage?.digest { digests.insert(digest) }
                for tab in pane.tabs {
                    pin(tab.backgroundOverride)
                    if let digest = tab.pendingTabImage?.digest { digests.insert(digest) }
                }
            }
        }
        if let draft = openProjectEditorModel()?.draft {
            for path in draft.makeProject().tabBackgroundImagePaths {
                if let digest = TerminalBackgroundImageImporter.digest(ofPath: path) { digests.insert(digest) }
            }
        }
        return digests
    }

    /// Device state: the identities stay, so the next open downloads again.
    func tabImagesEvicted(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        do {
            try projectStore.clearTabImagePaths(Set(paths))
        } catch {
            logger.error("could not clear evicted Tab image paths: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Only a Pane or Tab still waiting for this image gets it; one the user
    /// changed since it opened has stopped waiting and keeps its value.
    func tabImageArrived(projectID: UUID, identity: ProjectTabImage, path: String) {
        do {
            try projectStore.setResolvedTabImage(projectID: projectID, identity: identity, path: path)
        } catch {
            logger.error("could not record an arrived Tab image: \(error.localizedDescription, privacy: .public)")
        }
        for session in windows.flatMap(\.sessions) where session.projectID == projectID {
            for pane in session.tree.allPanes where pane.pendingImage == identity {
                pane.pendingImage = nil
                guard let current = pane.backgroundOverride else { continue }
                pane.restoreBackgroundOverride(current.withImagePath(path))
            }
            for tab in session.tree.allPanes.flatMap(\.tabs) where tab.pendingTabImage == identity {
                tab.pendingTabImage = nil
                guard let current = tab.backgroundOverride else { continue }
                tab.setBackgroundOverride(current.withImagePath(path))
            }
        }
        openProjectEditorModel()?.tabImageArrived(projectID: projectID, identity: identity, path: path)
    }

    /// The Project Editor is showing `project`: a user action, like opening it.
    @discardableResult
    func projectEditorShowed(_ project: Project) -> Task<Void, Never>? {
        guard !project.tabImages.isEmpty else { return nil }
        let resolved = resolveTabImages(of: project)
        if let model = openProjectEditorModel() {
            for tab in resolved.project.layout.backgroundEntries {
                guard let image = tab.image, let path = tab.background?.imagePath else { continue }
                model.tabImageArrived(projectID: project.id, identity: image, path: path)
            }
        }
        return requestTabImages(for: resolved.project, touching: resolved.cachedDigests)
    }
}
