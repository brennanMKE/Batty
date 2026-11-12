// BackgroundCatalogURLs.swift

import Foundation

nonisolated enum BackgroundCatalogURLRefusal: Error, Equatable, Sendable {
    case notHTTPS
    case duplicate
    case tooMany
    case fetch(String)

    var message: String {
        switch self {
        case .notHTTPS: "Only https:// URLs can be added"
        case .duplicate: "This catalog is already in the list"
        case .tooMany: "You can add up to \(BackgroundCatalogURLs.maxUserCatalogs) catalogs"
        case .fetch(let message): message
        }
    }
}

/// The user's Background Catalog URLs. Private and local hosts are allowed,
/// because the user typed the URL and `https` still needs a trusted certificate.
nonisolated enum BackgroundCatalogURLs {
    static let maxUserCatalogs = 20

    /// Lowercases scheme and host, drops port 443 and the fragment, and keeps
    /// the path and query as typed, since paths are case-sensitive.
    static func normalize(_ text: String) -> Result<URL, BackgroundCatalogURLRefusal> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { return .failure(.notHTTPS) }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        components.fragment = nil
        guard let url = components.url else { return .failure(.notHTTPS) }
        return .success(url)
    }
}
