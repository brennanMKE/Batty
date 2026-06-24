// SessionURLBuilder.swift

import Foundation

/// Builds and parses `batty://session?path=…` URLs used for CLI-to-app IPC.
public struct SessionURLBuilder {

    /// Resolves a user-supplied path string into an absolute, standardized
    /// directory path. Returns `nil` if the path does not exist or is not a
    /// directory. Relative paths are resolved against `currentDirectory`.
    public nonisolated static func resolve(
        path input: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String? {
        let expanded = (input as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(filePath: expanded)
        } else {
            url = URL(filePath: currentDirectory).appending(path: expanded)
        }
        var standardized = url.standardizedFileURL.path(percentEncoded: false)
        // Strip trailing slash that URL(filePath:) may add for directories.
        if standardized.hasSuffix("/"), standardized != "/" {
            standardized = String(standardized.dropLast())
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir),
              isDir.boolValue
        else { return nil }
        return standardized
    }

    /// Builds a `batty://session?path=<percent-encoded-abs-path>` URL.
    /// Returns `nil` only if URL component assembly fails (should not happen
    /// for valid absolute paths).
    public nonisolated static func buildURL(absolutePath: String) -> URL? {
        var components = URLComponents()
        components.scheme = "batty"
        components.host = "session"
        components.queryItems = [URLQueryItem(name: "path", value: absolutePath)]
        return components.url
    }

    /// Parses a `batty://session?path=…` URL back to an absolute path.
    /// Returns `nil` if the URL is not a recognized batty:// session command.
    public nonisolated static func sessionPath(from url: URL) -> String? {
        guard url.scheme == "batty", url.host() == "session" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let pathItem = components.queryItems?.first(where: { $0.name == "path" }),
              let path = pathItem.value,
              !path.isEmpty
        else { return nil }
        return path
    }
}
