// StaticFilePathResolver.swift

import Foundation

public nonisolated enum StaticResolution: Equatable, Sendable {
    case file(URL)
    case redirect(location: String)
    case listing(directory: URL, relativePath: String)
    case forbidden
    case notFound
    case reserved
}

/// Maps a request target to a file under one root, refusing anything that
/// could leave it (`docs/design/server-pane-view.md` §6, item 4).
public nonisolated struct StaticFilePathResolver: Sendable {
    public static let reservedSegment = "__batty"

    /// The root's `realpath(3)`. `URL.resolvingSymlinksInPath()` is not used:
    /// it maps `/private/var` to `/var`, which breaks the prefix check.
    public let rootRealPath: String

    public init?(root: URL) {
        guard let real = Self.realPath(root.path) else { return nil }
        rootRealPath = real
    }

    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The target's path with its query and fragment removed, still
    /// percent-encoded. Nil for anything that isn't origin-form.
    public static func rawPath(of target: String) -> String? {
        let path = String(target.prefix { $0 != "?" && $0 != "#" })
        return path.hasPrefix("/") ? path : nil
    }

    public func resolve(target: String) -> StaticResolution {
        guard let raw = Self.rawPath(of: target), !raw.contains("\0") else { return .forbidden }
        guard let decoded = raw.removingPercentEncoding, !decoded.contains("\0") else { return .forbidden }
        let parts = decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.contains("..") { return .forbidden }
        let segments = parts.filter { !$0.isEmpty && $0 != "." }
        if segments.first == Self.reservedSegment { return .reserved }
        if segments.contains(where: { $0.hasPrefix(".") }) { return .notFound }

        let candidate = ([rootRealPath] + segments).joined(separator: "/")
        guard let real = Self.realPath(candidate) else { return .notFound }
        guard isInsideRoot(real) else { return .forbidden }
        if relativeComponents(of: real).contains(where: { $0.hasPrefix(".") }) { return .notFound }

        var info = stat()
        guard stat(real, &info) == 0 else { return .notFound }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            let relative = segments.isEmpty ? "/" : "/" + segments.map(Self.encodeSegment).joined(separator: "/") + "/"
            if !decoded.hasSuffix("/") {
                return .redirect(location: relative)
            }
            let index = real + "/index.html"
            if let indexReal = Self.realPath(index), isInsideRoot(indexReal), Self.isRegularFile(indexReal) {
                return .file(URL(fileURLWithPath: indexReal))
            }
            return .listing(directory: URL(fileURLWithPath: real, isDirectory: true), relativePath: relative)
        case S_IFREG:
            return .file(URL(fileURLWithPath: real))
        default:
            return .notFound
        }
    }

    private func isInsideRoot(_ real: String) -> Bool {
        if rootRealPath == "/" { return true }
        return real == rootRealPath || real.hasPrefix(rootRealPath + "/")
    }

    private func relativeComponents(of real: String) -> [Substring] {
        guard real.count > rootRealPath.count else { return [] }
        return real.dropFirst(rootRealPath.count).split(separator: "/")
    }

    private static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    static func encodeSegment(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }
}
