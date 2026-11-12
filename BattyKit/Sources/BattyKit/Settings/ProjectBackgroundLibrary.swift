// ProjectBackgroundLibrary.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProjectBackgroundLibrary")

/// The one place that knows where Projects' background copies live. A stored
/// path is untrusted, because `projects.json` can be hand-edited or restored,
/// so a path reaches a Tab only through `checked(_:)`. Building this touches no
/// files.
@MainActor
final class ProjectBackgroundLibrary {
    let directory: URL
    let importer: TerminalBackgroundImageImporter
    /// The downloaded image cache, whose copies a Tab may show but this
    /// library never owns or deletes.
    let downloadedDirectory: URL?
    private let adoptableFrom: [URL]
    private let inspect: (String) -> BackgroundImageState

    /// `inspect` is a seam so tests can count reads.
    init(directory: URL, adoptableFrom: [URL], downloadedDirectory: URL? = nil, inspect: ((String) -> BackgroundImageState)? = nil) {
        self.directory = directory
        self.adoptableFrom = adoptableFrom
        self.downloadedDirectory = downloadedDirectory
        self.importer = TerminalBackgroundImageImporter(directory: directory, cleanup: .unreferenced)
        let roots = [directory] + (downloadedDirectory.map { [$0] } ?? [])
        self.inspect = inspect ?? { path in
            let states = roots.map { TerminalBackgroundImageImporter.inspect(path: path, directory: $0) }
            return states.contains(.usable) ? .usable : states[0]
        }
    }

    private func isCached(_ path: String) -> Bool {
        guard let downloadedDirectory else { return false }
        return TerminalBackgroundImageImporter.inspect(path: path, directory: downloadedDirectory) == .usable
    }

    /// Beside `projects.json`, so each variant and each test store has its own,
    /// and outside `TerminalBackgrounds/`, whose first pick of a launch removes
    /// everything but the app-wide image.
    static func directory(forProjectsFile file: URL?) -> URL {
        let parent = file?.deletingLastPathComponent()
            ?? TerminalBackgroundImageImporter.appWideDirectory().deletingLastPathComponent()
        return parent.appendingPathComponent("ProjectBackgrounds", isDirectory: true)
    }

    /// `inspect` checks shape and digest only. A file named for its own digest
    /// can still be oversized, and libghostty aborts the process on a very wide
    /// image, so this also reads the header, which decodes no pixels.
    func imageState(ofPath path: String) -> BackgroundImageState {
        let state = inspect(path)
        guard state == .usable else { return state }
        guard TerminalBackgroundImageImporter.isWithinPixelLimit(path: path) else { return .rejected }
        return .usable
    }

    /// What a Tab may be given: the settings, without an image that failed.
    func checked(_ settings: TerminalBackgroundSettings) -> (settings: TerminalBackgroundSettings, problem: BackgroundImageState?) {
        guard let path = settings.imagePath else { return (settings, nil) }
        let state = imageState(ofPath: path)
        guard state != .usable else { return (settings, nil) }
        logger.error("project background image not used (\(String(describing: state), privacy: .public)): \(path, privacy: .private)")
        return (settings.withImagePath(nil), state)
    }

    /// A cached copy stays where it is: the cache owns it.
    func adopt(path: String) -> String? {
        if isCached(path) { return path }
        return TerminalBackgroundImageImporter.adopt(path: path, from: adoptableFrom, into: directory)
    }

    /// Removes copies that this store's list, `projects.json` as it is now and
    /// `inUse` all leave out. Re-reading the file shows another running copy's
    /// saves, however long ago that copy read its own list. The age covers what
    /// no file shows yet, such as that copy's unsaved draft: importing or
    /// adopting a copy refreshes its folder's date. Returns nil, removing
    /// nothing, unless the file can be trusted in full, because a leak is
    /// cheaper than a lost image. A folder whose digest a `sharedImage` names is
    /// kept too: a Project waiting for that image has no path to keep it by.
    @discardableResult
    func reclaim(
        store: ProjectStore,
        inUse: Set<String>,
        now: Date = Date(),
        minimumAge: TimeInterval = 86_400
    ) -> Task<Void, Never>? {
        guard !store.mayReferenceUnlistedImages,
              let inFile = store.imagePathsInFile(),
              let digestsInFile = store.sharedImageDigestsInFile()
        else {
            logger.notice("not reclaiming project background images: the projects file may name others")
            return nil
        }
        let keeping = inUse.union(inFile).union(store.projects.flatMap(\.allBackgroundImagePaths))
        let keepingDigests = digestsInFile
            .union(store.projects.compactMap { $0.sharedImage?.digest })
            .union(store.projects.flatMap(\.tabCustomDigests))
        let cutoff = now.addingTimeInterval(-minimumAge)
        let importer = importer
        return Task { await importer.removeUnreferenced(keeping: keeping, keepingDigests: keepingDigests, olderThan: cutoff) }
    }
}
