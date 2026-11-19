// ServerHTTPProbe.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ServerHTTPProbe")

public nonisolated enum ProbeResult: Equatable, Sendable {
    /// Any HTTP response counts as answering, whatever its status.
    case answered(status: Int)
    case noResponse(String)
}

public nonisolated enum StatsFetchResult: Equatable, Sendable {
    case body(status: Int, data: Data)
    case failed(String)
}

public protocol HTTPProbing: AnyObject, Sendable {
    func probe(_ url: URL) async -> ProbeResult
}

public protocol ServerStatsFetching: AnyObject, Sendable {
    func fetch(_ url: URL) async -> StatsFetchResult
}

/// One ephemeral `URLSession` with a 2 s timeout. A self-signed certificate
/// is trusted only for a loopback host.
public nonisolated final class URLSessionHTTPProbe: NSObject, HTTPProbing, ServerStatsFetching, URLSessionDelegate, @unchecked Sendable {
    public static let timeout: TimeInterval = 2
    private var session: URLSession!

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public static func isLoopback(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    public func probe(_ url: URL) async -> ProbeResult {
        do {
            let (_, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .noResponse("not HTTP") }
            return .answered(status: http.statusCode)
        } catch {
            return .noResponse(error.localizedDescription)
        }
    }

    public func fetch(_ url: URL) async -> StatsFetchResult {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .failed("not HTTP") }
            return .body(status: http.statusCode, data: data)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              Self.isLoopback(host: challenge.protectionSpace.host),
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        logger.debug("trusting loopback certificate for \(challenge.protectionSpace.host, privacy: .public)")
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
