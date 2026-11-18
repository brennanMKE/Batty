// BackgroundPickerOpening.swift

import Foundation

/// Which tab the Background Images picker opens on, and which image it shows
/// as current there, worked out from the path the caller passes.
nonisolated struct BackgroundPickerOpening: Equatable, Sendable {
    enum Tab: Hashable, Sendable {
        case myImages
        case backgroundSets
    }

    let tab: Tab
    let hostedKey: HostedImageKey?
    let libraryDigest: String?

    /// `current` is always an adopted copy in a digest folder, so a hosted
    /// image is recognised by its digest's record, the same rule as Tab writers.
    static func resolve(currentPath: String?, hostedRecords: [HostedImageRecord], cacheEntries: [DownloadedImageEntry]) -> Self {
        guard let currentPath,
              let image = ProjectTabImage.derive(path: currentPath, hostedRecords: hostedRecords, cacheEntries: cacheEntries)
        else { return Self(tab: .backgroundSets, hostedKey: nil, libraryDigest: nil) }
        switch image {
        case .hosted(let url, _):
            return Self(tab: .backgroundSets, hostedKey: HostedImageKey(url: url), libraryDigest: nil)
        case .custom(let digest, _):
            return Self(tab: .myImages, hostedKey: nil, libraryDigest: digest)
        }
    }

    static func contents(_ contents: [HostedCatalogContent], contain key: HostedImageKey) -> Bool {
        contents.contains { content in
            content.catalog?.allImages.contains { HostedImageKey($0) == key } ?? false
        }
    }
}

/// A one-shot flag that is deliberately not observed, so clearing it from a
/// change handler writes no state SwiftUI tracks.
final class PickerScrollOnce {
    var pending = true
    /// Whether the scroll view has a size, below which a scroll lands nowhere.
    var viewportSized = false
}
