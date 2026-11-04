// ProjectBackgroundLibrary.swift

import Foundation
import ImageIO
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
    private let adoptableFrom: [URL]
    private let inspect: (String) -> BackgroundImageState

    /// `inspect` is a seam so tests can count reads.
    init(directory: URL, adoptableFrom: [URL], inspect: ((String) -> BackgroundImageState)? = nil) {
        self.directory = directory
        self.adoptableFrom = adoptableFrom
        self.importer = TerminalBackgroundImageImporter(directory: directory, cleanup: .unreferenced)
        self.inspect = inspect ?? { TerminalBackgroundImageImporter.inspect(path: $0, directory: directory) }
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
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) <= TerminalBackgroundImageImporter.maxPixelSize
        else { return .rejected }
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

    func adopt(path: String) -> String? {
        TerminalBackgroundImageImporter.adopt(path: path, from: adoptableFrom, into: directory)
    }

    /// Removes copies that this store's list, `projects.json` as it is now and
    /// `inUse` all leave out. Re-reading the file shows another running copy's
    /// saves, however long ago that copy read its own list. The age covers what
    /// no file shows yet, such as that copy's unsaved draft: importing or
    /// adopting a copy refreshes its folder's date. Returns nil, removing
    /// nothing, unless the file can be trusted in full, because a leak is
    /// cheaper than a lost image.
    @discardableResult
    func reclaim(
        store: ProjectStore,
        inUse: Set<String>,
        now: Date = Date(),
        minimumAge: TimeInterval = 86_400
    ) -> Task<Void, Never>? {
        guard !store.mayReferenceUnlistedImages, let inFile = store.imagePathsInFile() else {
            logger.notice("not reclaiming project background images: the projects file may name others")
            return nil
        }
        let keeping = inUse.union(inFile).union(store.projects.compactMap { $0.background?.imagePath })
        let cutoff = now.addingTimeInterval(-minimumAge)
        let importer = importer
        return Task { await importer.removeUnreferenced(keeping: keeping, olderThan: cutoff) }
    }
}
