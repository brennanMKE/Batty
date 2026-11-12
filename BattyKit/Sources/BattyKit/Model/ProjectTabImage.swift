// ProjectTabImage.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProjectTabImage")

/// Which image a Project Tab shows, in a form another Mac can find: the
/// Background Sets URL for a hosted image, whose digest differs per Mac because
/// each re-encodes its download, or the digest for any other image. Never a path.
public nonisolated enum ProjectTabImage: Codable, Sendable, Hashable {
    case hosted(url: URL, name: String)
    case custom(digest: String, name: String)

    nonisolated static let maxURLBytes = 2_048

    public var name: String {
        switch self {
        case .hosted(_, let name), .custom(_, let name): name
        }
    }

    var digest: String? {
        if case .custom(let digest, _) = self { return digest }
        return nil
    }

    var url: URL? {
        if case .hosted(let url, _) = self { return url }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case url, digest, name
    }

    nonisolated static func isAcceptable(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty && url.absoluteString.utf8.count <= maxURLBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = TerminalBackgroundImageImporter.sanitizedImageName(
            (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "", maxBytes: ProjectSharedImage.maxNameBytes)
        if let text = try? c.decodeIfPresent(String.self, forKey: .url) {
            guard let url = URL(string: text), Self.isAcceptable(url) else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "not an https URL")
            }
            self = .hosted(url: url, name: name)
            return
        }
        let digest = try c.decode(String.self, forKey: .digest)
        guard TerminalBackgroundImageImporter.isDigest(digest) else {
            throw DecodingError.dataCorruptedError(forKey: .digest, in: c, debugDescription: "not a digest")
        }
        self = .custom(digest: digest, name: name)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hosted(let url, let name):
            try c.encode(url.absoluteString, forKey: .url)
            try c.encode(name, forKey: .name)
        case .custom(let digest, let name):
            try c.encode(digest, forKey: .digest)
            try c.encode(name, forKey: .name)
        }
    }

    /// A bad value is no identity, logged, and never fails the Tab.
    nonisolated static func decodeTolerantly<K: CodingKey>(from c: KeyedDecodingContainer<K>, forKey key: K) -> ProjectTabImage? {
        guard c.contains(key) else { return nil }
        if let decoded = try? c.decodeIfPresent(ProjectTabImage.self, forKey: key) { return decoded }
        if !((try? c.decodeNil(forKey: key)) ?? false) { logger.error("unreadable project tab image; the Tab shows no image") }
        return nil
    }

    /// Pure. `.hosted` when a hosted record or a cached entry with a URL has the
    /// path's digest, otherwise `.custom`. Nil when the path isn't in a folder
    /// named for a digest.
    static func derive(path: String, hostedRecords: [HostedImageRecord], cacheEntries: [DownloadedImageEntry]) -> ProjectTabImage? {
        guard let digest = TerminalBackgroundImageImporter.digest(ofPath: path) else { return nil }
        let name = TerminalBackgroundImageImporter.sanitizedImageName(
            ((path as NSString).lastPathComponent as NSString).deletingPathExtension, maxBytes: ProjectSharedImage.maxNameBytes)
        if let record = hostedRecords.last(where: { $0.digest == digest }), isAcceptable(record.url) {
            return .hosted(url: record.url, name: name)
        }
        if let url = cacheEntries.last(where: { $0.digest == digest })?.url, isAcceptable(url) {
            return .hosted(url: url, name: name)
        }
        return .custom(digest: digest, name: name)
    }
}
