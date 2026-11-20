// AppStateStore+BackgroundListXPC.swift

import BattyXPCCore
import Foundation

extension AppStateStore {
    static let myImagesSetName = "My Images"

    /// The `backgroundList` verb. Exit 4 (a failure) only when nothing can
    /// be listed and some catalog has a problem or was never loaded, or for
    /// an unknown `set`.
    func backgroundListForXPC(_ request: BackgroundListRequest) async -> CLIOutcome<BackgroundListReply> {
        let images = backgroundImages
        let hosted = images.hosted
        await hosted.catalogsForCLI()
        await images.refresh()

        var entries: [BackgroundListEntry] = []
        var warnings: [String] = []
        var unloaded = false
        for state in hosted.catalogs {
            if let problem = state.problem {
                warnings.append(Self.catalogWarning(problem, host: state.host))
            }
            guard let catalog = state.catalog else {
                unloaded = true
                if state.isBuiltIn, !hosted.hasBrowsed {
                    warnings.append("the built-in Background Sets catalog hasn't been loaded yet; open Background Sets in Batty once to load it")
                }
                continue
            }
            for set in catalog.sets {
                for image in set.images {
                    entries.append(BackgroundListEntry(
                        set: set.name, title: image.title, id: image.full.absoluteString, source: .hosted,
                        thumbnailURL: image.thumbnail.absoluteString, fullURL: image.full.absoluteString,
                        catalogURL: state.url.absoluteString,
                        downloaded: hosted.available.contains(HostedImageKey(image))))
                }
            }
        }
        for entry in images.entries {
            entries.append(BackgroundListEntry(
                set: Self.myImagesSetName, title: entry.name, id: entry.digest, source: .myImages,
                downloaded: true, digest: entry.digest))
        }

        if let set = request.set {
            let filtered = entries.filter { $0.set.lowercased() == set.lowercased() }
            if filtered.isEmpty {
                var names: [String] = []
                for name in entries.map(\.set) where !names.contains(name) { names.append(name) }
                return .failure("no Background Set named \"\(set)\"" + (names.isEmpty ? "" : "; sets: " + names.joined(separator: ", ")))
            }
            entries = filtered
        }
        if entries.isEmpty, unloaded || !warnings.isEmpty {
            return .failure((warnings.isEmpty ? ["no Background Sets are loaded; open Background Sets in Batty once"] : warnings).joined(separator: "; "))
        }
        return .success(BackgroundListReply(images: entries, warnings: warnings))
    }

    private static func catalogWarning(_ problem: HostedCatalogProblem, host: String) -> String {
        switch problem {
        case .offlineShowingCache(let message): "\(host): \(message); showing the saved copy"
        case .offlineNoCache(let message), .invalid(let message), .fetchFailed(let message): "\(host): \(message)"
        }
    }
}
