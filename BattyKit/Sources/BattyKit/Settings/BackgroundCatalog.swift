// BackgroundCatalog.swift

import Foundation

/// One hosted image. Its identity is its resolved full-size URL.
nonisolated struct HostedBackgroundImage: Sendable, Equatable, Hashable, Identifiable {
    let title: String
    let full: URL
    let thumbnail: URL

    var id: URL { full }

    /// The full-size file's name without its extension: the name UI tests find a cell by.
    static func fileStem(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

nonisolated struct BackgroundSet: Sendable, Equatable, Identifiable {
    /// The set's position in the catalog. Names needn't be unique.
    let id: Int
    let name: String
    let images: [HostedBackgroundImage]
}

nonisolated struct BackgroundCatalog: Sendable, Equatable {
    static let builtInURL = URL(string: "https://batty.sstools.co/backgrounds/catalog.json")!

    let sets: [BackgroundSet]

    var allImages: [HostedBackgroundImage] { sets.flatMap(\.images) }
}

nonisolated enum BackgroundCatalogLimits {
    static let catalogBytes = 1_000_000
    static let sets = 50
    static let imagesPerSet = 100
    static let imagesPerCatalog = 1_000
    static let titleLength = 100
    static let thumbnailBytes: Int64 = 2_000_000
    static let thumbnailPixels = 1024
    static let fullBytes: Int64 = 50_000_000
    static let fullPixels = 8192
    static let redirects = 5
    static let catalogTimeout: TimeInterval = 30
    static let thumbnailTimeout: TimeInterval = 30
    static let fullTimeout: TimeInterval = 60
    static let supportedTypes: Set<String> = ["public.png", "public.jpeg"]

    /// PNG or JPEG, and the decoded type must match the URL's extension.
    static func isAccepted(type: String, for url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "png": type == "public.png"
        case "jpg", "jpeg": type == "public.jpeg"
        default: false
        }
    }
}

nonisolated enum BackgroundCatalogError: Error, Equatable, Sendable {
    case invalid(path: String)
    case tooLarge

    var message: String {
        switch self {
        case .invalid(let path): "Not a background catalog: \(path)"
        case .tooLarge: "Catalog is larger than 1 MB"
        }
    }
}

/// Walks `JSONSerialization` output by hand so every error names the first bad
/// path, such as `sets[1].images[3].full`. Unknown fields are ignored.
nonisolated enum BackgroundCatalogParser {
    static func parse(_ data: Data, catalogURL: URL) throws(BackgroundCatalogError) -> BackgroundCatalog {
        guard data.count <= BackgroundCatalogLimits.catalogBytes else { throw .tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { throw .invalid(path: "(root)") }

        guard let rawSets = root["sets"] as? [Any] else { throw .invalid(path: "sets") }
        guard rawSets.count <= BackgroundCatalogLimits.sets else { throw .invalid(path: "sets") }
        var fullURLs = Set<URL>()
        var total = 0
        var sets: [BackgroundSet] = []
        for (setIndex, rawSet) in rawSets.enumerated() {
            let setPath = "sets[\(setIndex)]"
            guard let set = rawSet as? [String: Any] else { throw .invalid(path: setPath) }
            let name = try requiredString(set["name"], path: "\(setPath).name", limit: BackgroundCatalogLimits.titleLength)
            guard let rawImages = set["images"] as? [Any] else { throw .invalid(path: "\(setPath).images") }
            guard rawImages.count <= BackgroundCatalogLimits.imagesPerSet else { throw .invalid(path: "\(setPath).images") }
            total += rawImages.count
            guard total <= BackgroundCatalogLimits.imagesPerCatalog else { throw .invalid(path: "\(setPath).images") }
            var images: [HostedBackgroundImage] = []
            for (imageIndex, rawImage) in rawImages.enumerated() {
                let imagePath = "\(setPath).images[\(imageIndex)]"
                guard let image = rawImage as? [String: Any] else { throw .invalid(path: imagePath) }
                let full = try fileURL(image["full"], path: "\(imagePath).full", catalogURL: catalogURL)
                guard fullURLs.insert(full).inserted else { throw .invalid(path: "\(imagePath).full") }
                let thumbnail = try fileURL(image["thumbnail"], path: "\(imagePath).thumbnail", catalogURL: catalogURL)
                let title = try requiredString(image["title"], path: "\(imagePath).title", limit: BackgroundCatalogLimits.titleLength)
                images.append(HostedBackgroundImage(title: title, full: full, thumbnail: thumbnail))
            }
            sets.append(BackgroundSet(id: setIndex, name: name, images: images))
        }
        return BackgroundCatalog(sets: sets)
    }

    /// Catalog text is shown only through `Text(verbatim:)`; this removes what
    /// could still disturb a layout.
    static func displayText(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            let category = $0.properties.generalCategory
            return category != .control && category != .format
        }))
    }

    private static func fileURL(_ raw: Any?, path: String, catalogURL: URL) throws(BackgroundCatalogError) -> URL {
        guard let text = raw as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let resolved = URL(string: text, relativeTo: catalogURL)?.absoluteURL,
              isHTTPS(resolved)
        else { throw .invalid(path: path) }
        return resolved
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
    }

    private static func requiredString(_ raw: Any?, path: String, limit: Int) throws(BackgroundCatalogError) -> String {
        guard let text = raw as? String else { throw .invalid(path: path) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit else { throw .invalid(path: path) }
        return trimmed
    }
}
