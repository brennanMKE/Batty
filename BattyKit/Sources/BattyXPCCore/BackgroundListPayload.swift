// BackgroundListPayload.swift

import Foundation

/// Payloads for the `backgroundList` XPC verb (`batty background list`).

public nonisolated struct BackgroundListRequest: Codable, Sendable, Equatable {
    /// Case-insensitive, exact set name.
    public let set: String?

    public static let timeoutSeconds = 30

    public init(set: String? = nil) {
        self.set = set
    }
}

/// A hosted entry's `id` is its full-size URL, which is stable; a My Images
/// entry's `id` is its digest. Neither carries a filesystem path.
public nonisolated struct BackgroundListEntry: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case hosted
        case myImages
    }

    public let set: String
    public let title: String
    public let id: String
    public let source: Source
    public let thumbnailURL: String?
    public let fullURL: String?
    public let catalogURL: String?
    public let downloaded: Bool
    public let digest: String?

    public init(set: String, title: String, id: String, source: Source, thumbnailURL: String? = nil, fullURL: String? = nil, catalogURL: String? = nil, downloaded: Bool, digest: String? = nil) {
        self.set = set
        self.title = title
        self.id = id
        self.source = source
        self.thumbnailURL = thumbnailURL
        self.fullURL = fullURL
        self.catalogURL = catalogURL
        self.downloaded = downloaded
        self.digest = digest
    }
}

public nonisolated struct BackgroundListReply: Codable, Sendable, Equatable {
    public let images: [BackgroundListEntry]
    public let warnings: [String]

    public init(images: [BackgroundListEntry], warnings: [String]) {
        self.images = images
        self.warnings = warnings
    }
}
