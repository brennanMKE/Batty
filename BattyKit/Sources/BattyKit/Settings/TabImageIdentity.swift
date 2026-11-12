// TabImageIdentity.swift

import Foundation

/// Works out the identity a Tab's image path stands for, from the Hosted and
/// Downloaded record files. Every writer of a Tab path goes through it.
@MainActor
struct TabImageIdentity {
    let hostedDirectory: URL
    let downloadedDirectory: URL

    init(hostedDirectory: URL, downloadedDirectory: URL) {
        self.hostedDirectory = hostedDirectory
        self.downloadedDirectory = downloadedDirectory
    }

    /// Beside `projects.json`, like the other image folders.
    init(projectsFile: URL?) {
        let library = BackgroundImageLibrary.directory(forProjectsFile: projectsFile)
        self.init(
            hostedDirectory: library.appendingPathComponent("Hosted", isDirectory: true),
            downloadedDirectory: DownloadedImageCache.directory(inLibrary: library)
        )
    }

    /// `keeping` stays when `path` is still a copy of it on this Mac, so a
    /// slider edit or a re-save never turns a hosted image into a custom one.
    /// Nil for no path, or a path that isn't in a digest folder.
    func identity(forPath path: String?, keeping: ProjectTabImage?, previousPath: String? = nil) -> ProjectTabImage? {
        guard let path, let digest = TerminalBackgroundImageImporter.digest(ofPath: path) else { return nil }
        let hosted = HostedImageStore.records(in: hostedDirectory)
        let cached = DownloadedImageIndex.entries(in: downloadedDirectory)
        if let keeping {
            if let previousPath, TerminalBackgroundImageImporter.digest(ofPath: previousPath) == digest { return keeping }
            switch keeping {
            case .custom(let kept, _):
                if kept == digest { return keeping }
            case .hosted(let url, _):
                if hosted.contains(where: { $0.url == url && $0.digest == digest })
                    || cached.contains(where: { $0.url == url && $0.digest == digest }) {
                    return keeping
                }
            }
        }
        return ProjectTabImage.derive(path: path, hostedRecords: hosted, cacheEntries: cached)
    }
}
