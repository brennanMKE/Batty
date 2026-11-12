// BackgroundSetsView.swift

import SwiftUI

/// The Background Sets tab. Shows thumbnails only; a full-size image is fetched
/// only when it's picked as a background. Nothing in `body` writes observed
/// state: the model's writes start from `.task` or a click, and each cell's
/// picture and digest are its own `@State`.
struct BackgroundSetsView: View {
    let hosted: HostedBackgroundsModel
    let uses: [String: [BackgroundImageUse]]
    /// Nil in manage mode, where a click only selects.
    let onPick: ((String) -> Void)?

    @State private var selected: HostedImageKey?

    private static let minimumCellWidth: CGFloat = 170
    private static let spacing: CGFloat = 16

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(hosted.catalogs) { state in
                    catalogSection(state)
                }
            }
            .padding(Self.spacing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await hosted.browseAppeared() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("background-sets.root")
    }

    @ViewBuilder
    private func catalogSection(_ state: HostedCatalogState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if hosted.catalogs.count > 1 {
                Text(verbatim: Self.header(for: state.url, among: hosted.catalogs.map(\.url)))
                    .font(.title3.weight(.semibold))
            }
            if let problem = state.problem {
                banner(problem, url: state.url)
            }
            if state.catalog == nil, state.problem == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            ForEach(state.catalog?.sets ?? []) { set in
                setSection(set, catalogURL: state.url)
            }
        }
    }

    private func banner(_ problem: HostedCatalogProblem, url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(verbatim: Self.message(for: problem))
                .lineLimit(2)
            Spacer()
            if Self.offersRetry(problem) {
                Button("Retry") {
                    Task { await hosted.refresh(url) }
                }
                .accessibilityIdentifier("background-sets.retry")
            }
        }
        .font(.callout)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("background-sets.banner")
    }

    /// Host only, unless another listed catalog shares it.
    static func header(for url: URL, among urls: [URL]) -> String {
        if url == BackgroundCatalog.builtInURL { return "Batty" }
        let host = url.host ?? url.absoluteString
        let shared = urls.contains { $0 != url && $0.host == url.host }
        return shared ? host + url.path : host
    }

    static func message(for problem: HostedCatalogProblem) -> String {
        switch problem {
        case .offlineShowingCache(let host):
            String(localized: "Can't reach \(host). Showing the last copy.", comment: "Background Sets: offline with a cached catalog")
        case .offlineNoCache(let host):
            String(localized: "Can't reach \(host). Try again when you're online.", comment: "Background Sets: offline with nothing cached")
        case .invalid(let message), .fetchFailed(let message):
            message
        }
    }

    private static func offersRetry(_ problem: HostedCatalogProblem) -> Bool {
        if case .offlineShowingCache = problem { return false }
        return true
    }

    private func setSection(_ set: BackgroundSet, catalogURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: BackgroundCatalogParser.displayText(set.name))
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.minimumCellWidth), spacing: Self.spacing)],
                alignment: .leading,
                spacing: Self.spacing
            ) {
                ForEach(set.images) { image in
                    let key = HostedImageKey(image)
                    HostedBackgroundCell(
                        image: image,
                        catalogURL: catalogURL,
                        hosted: hosted,
                        uses: uses,
                        isHighlighted: selected == key
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { click(image, key: key) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("background-sets.set.\(set.name)")
    }

    private func click(_ image: HostedBackgroundImage, key: HostedImageKey) {
        selected = key
        guard let onPick else { return }
        hosted.pick(image) { onPick($0) }
    }
}

private struct HostedBackgroundCell: View {
    let image: HostedBackgroundImage
    let catalogURL: URL
    let hosted: HostedBackgroundsModel
    let uses: [String: [BackgroundImageUse]]
    let isHighlighted: Bool

    @State private var thumbnail: BackgroundImageThumbnail?
    @State private var digest: String?

    private var key: HostedImageKey { HostedImageKey(image) }
    private var accessibilityName: String { HostedBackgroundImage.fileStem(of: image.full) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The thumbnail's shape isn't known until it loads, so every cell
            // is 16:10 and the picture fits inside.
            Color.clear
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { picture }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .activeOutline(isHighlighted, cornerRadius: 6)
            Text(verbatim: BackgroundCatalogParser.displayText(image.title))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            status
        }
        .task(id: image) {
            thumbnail = await hosted.thumbnail(for: image, catalogURL: catalogURL)
        }
        .task(id: hosted.available.contains(key)) {
            let path = await hosted.store.localPath(for: image)
            digest = path.flatMap(TerminalBackgroundImageImporter.digest(ofPath:))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("background-sets.cell.\(accessibilityName)")
    }

    @ViewBuilder
    private var status: some View {
        switch hosted.fetches[key] {
        case .fetching:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Button("Cancel") { hosted.cancelFetch(key) }
                    .controlSize(.small)
                    .accessibilityIdentifier("background-sets.cell.\(accessibilityName).cancel")
            }
            .accessibilityIdentifier("background-sets.cell.\(accessibilityName).progress")
        case .failed(let message):
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .accessibilityIdentifier("background-sets.cell.\(accessibilityName).failed")
        case nil:
            if let digest, !(uses[digest] ?? []).isEmpty {
                Text("In use")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("background-sets.cell.\(accessibilityName).in-use")
            } else if hosted.available.contains(key) {
                Text("Available offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("background-sets.cell.\(accessibilityName).available")
            }
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let picture = thumbnail?.image {
            Image(decorative: picture, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if thumbnail == nil {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}
