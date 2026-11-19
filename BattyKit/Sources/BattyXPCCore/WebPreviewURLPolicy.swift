// WebPreviewURLPolicy.swift

import Foundation

/// What a Web Preview Pane may load (`docs/design/web-preview-pane.md`).
/// Top-level pages stay on loopback; subresources may come from anywhere on
/// http(s), so pages that load their scripts from a CDN still render.
public nonisolated enum WebPreviewURLPolicy {
    public enum Decision: Equatable, Sendable {
        case allow
        case openExternally
        case cancel
    }

    public struct Origin: Hashable, Sendable {
        public let scheme: String
        public let host: String
        public let port: Int
    }

    public static let refusalMessage = "web previews show only http(s) URLs on localhost, 127.0.0.1 or [::1]"

    /// Exact host names only: `127.0.0.1.evil.com` is not loopback.
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    public static func isAllowedTopLevel(_ url: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        return isLoopbackHTTP(url)
    }

    public static func decide(url: URL, isMainFrame: Bool, isUserActivated: Bool) -> Decision {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "file" { return .cancel }
        if !isMainFrame {
            return ["http", "https", "data", "blob", "about"].contains(scheme) ? .allow : .cancel
        }
        if isAllowedTopLevel(url) { return .allow }
        if (scheme == "http" || scheme == "https"), isUserActivated { return .openExternally }
        return .cancel
    }

    /// Scheme, host and port with the scheme's default port filled in. Nil
    /// for a URL with no http(s) scheme or host.
    public static func origin(of url: URL) -> Origin? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return Origin(scheme: scheme, host: host, port: port)
    }

    private static func isLoopbackHTTP(_ url: URL) -> Bool {
        guard let origin = origin(of: url) else { return false }
        return loopbackHosts.contains(origin.host)
    }
}
