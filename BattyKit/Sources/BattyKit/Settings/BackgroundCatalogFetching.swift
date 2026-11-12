// BackgroundCatalogFetching.swift

import Foundation

nonisolated struct HostedFetchRequest: Sendable, Equatable {
    enum Destination: Sendable, Equatable {
        case memory
        case file(URL)
    }

    let url: URL
    var etag: String?
    var lastModified: String?
    let byteLimit: Int64
    let timeout: TimeInterval
    var destination: Destination = .memory
}

nonisolated struct HostedFetchResponse: Sendable, Equatable {
    /// 200 or 304.
    let status: Int
    /// Nil for a 304 or a `.file` destination.
    let body: Data?
    let etag: String?
    let lastModified: String?
    let expectedLength: Int64?
}

nonisolated enum HostedFetchError: Error, Equatable, Sendable {
    case notFound
    case server(Int)
    case http(Int)
    case unreachable
    case untrustedCertificate
    case insecureRedirect
    case tooManyRedirects
    case tooLarge
    case timedOut
    case cancelled

    func message(host: String) -> String {
        switch self {
        case .notFound: "Not found (404)"
        case .server(let code): "Server error (\(code))"
        case .http(let code): "Unexpected response (\(code))"
        case .unreachable: "Can't reach \(host)"
        case .untrustedCertificate: "\(host) has an untrusted certificate"
        case .insecureRedirect: "Redirected to an insecure address"
        case .tooManyRedirects: "Too many redirects"
        case .tooLarge: "File is larger than allowed"
        case .timedOut: "\(host) took too long to answer"
        case .cancelled: "Cancelled"
        }
    }
}

/// The only way the hosted-background code reaches the network, so tests
/// inject a fake and never touch it.
nonisolated protocol BackgroundCatalogFetching: Sendable {
    func fetch(
        _ request: HostedFetchRequest,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws(HostedFetchError) -> HostedFetchResponse
}

nonisolated enum HostedFetchPolicy {
    /// `count` is how many redirects this one would make, starting at 1.
    static func allowsRedirect(to url: URL?, count: Int) -> HostedFetchError? {
        guard count <= BackgroundCatalogLimits.redirects else { return .tooManyRedirects }
        guard let url, url.scheme?.lowercased() == "https", !(url.host ?? "").isEmpty else { return .insecureRedirect }
        return nil
    }

    /// Nil for the statuses a caller handles: 200 and 304.
    static func error(forStatus status: Int) -> HostedFetchError? {
        switch status {
        case 200, 304: nil
        case 404, 410: .notFound
        case 500...599: .server(status)
        default: .http(status)
        }
    }

    static func error(for urlError: URLError) -> HostedFetchError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            .unreachable
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .secureConnectionFailed:
            .untrustedCertificate
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .httpTooManyRedirects: .tooManyRedirects
        case .dataLengthExceedsMaximum: .tooLarge
        default: .unreachable
        }
    }
}

/// Counts streamed bytes against a limit.
nonisolated struct ByteLimitCounter: Sendable {
    let limit: Int64
    private(set) var received: Int64 = 0

    init(limit: Int64) { self.limit = limit }

    /// False once the total passes the limit.
    mutating func add(_ count: Int) -> Bool {
        received += Int64(count)
        return received <= limit
    }

    func accepts(expectedLength: Int64?) -> Bool {
        guard let expectedLength, expectedLength >= 0 else { return true }
        return expectedLength <= limit
    }
}
