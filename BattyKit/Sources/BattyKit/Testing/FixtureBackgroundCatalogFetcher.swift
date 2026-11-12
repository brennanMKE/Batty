// FixtureBackgroundCatalogFetcher.swift

import Foundation

/// Used only by a UI-test launch that sets the background catalog fixture
/// folder: serves `https://batty.sstools.co/backgrounds/<rest>` from
/// `<directory>/<rest>` and appends each requested path to `requests.log`.
nonisolated final class FixtureBackgroundCatalogFetcher: BackgroundCatalogFetching, @unchecked Sendable {
    static let prefix = "https://batty.sstools.co/backgrounds/"

    private let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    func fetch(
        _ request: HostedFetchRequest,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws(HostedFetchError) -> HostedFetchResponse {
        let absolute = request.url.absoluteString
        guard absolute.hasPrefix(Self.prefix) else { throw .unreachable }
        let rest = String(absolute.dropFirst(Self.prefix.count))
        log(rest)
        let components = rest.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else { throw .notFound }
        let file = components.reduce(directory) { $0.appendingPathComponent($1) }
        guard let data = try? Data(contentsOf: file) else { throw .notFound }
        guard Int64(data.count) <= request.byteLimit else { throw .tooLarge }
        let etag = "\"\(TerminalBackgroundImageImporter.hexDigest(of: data))\""
        if request.etag == etag {
            return HostedFetchResponse(status: 304, body: nil, etag: etag, lastModified: nil, expectedLength: nil)
        }
        progress?(Int64(data.count))
        if case .file(let destination) = request.destination {
            do { try data.write(to: destination) } catch { throw .unreachable }
            return HostedFetchResponse(status: 200, body: nil, etag: etag, lastModified: nil, expectedLength: Int64(data.count))
        }
        return HostedFetchResponse(status: 200, body: data, etag: etag, lastModified: nil, expectedLength: Int64(data.count))
    }

    private func log(_ path: String) {
        lock.withLock {
            let file = directory.appendingPathComponent("requests.log")
            let line = Data((path + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
                try? handle.close()
            } else {
                try? line.write(to: file)
            }
        }
    }
}
