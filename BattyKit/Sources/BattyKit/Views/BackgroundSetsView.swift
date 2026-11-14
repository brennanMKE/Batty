// BackgroundSetsView.swift

import SwiftUI

/// The Background Sets tab. Shows thumbnails only; a full-size image is fetched
/// only when it's picked as a background. Nothing in `body` writes observed
/// state, and each cell's picture and digest are its own `@State`. The model's writes start from `.task`,
/// a click or Refresh; `query` is written only by the filter field and its clear button.
///
/// `body` reads only what changes the sections: the catalogs' contents and the
/// query. A check's progress, the selection and each image's download state are
/// read by the controls and the cells, so a check or a click doesn't
/// re-evaluate the grids above a scrolled viewport.
struct BackgroundSetsView: View {
    let model: BackgroundImagesModel
    /// Nil in manage mode, where a click only selects.
    let onPick: ((String) -> Void)?

    @State private var selection = GridSelection<HostedImageKey>()
    @State private var query = ""

    private var hosted: HostedBackgroundsModel { model.hosted }

    private static let minimumCellWidth: CGFloat = 170
    private static let spacing: CGFloat = 16

    var body: some View {
        let sections = BackgroundCatalogFilter.sections(hosted.contents, query: query)
        let trimmed = BackgroundCatalogFilter.normalizedQuery(query)
        VStack(spacing: 0) {
            BackgroundSetsControls(hosted: hosted, query: $query)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(sections) { section in
                        catalogSection(section.content, sets: section.sets, filtering: trimmed != nil)
                    }
                    if let trimmed, sections.isEmpty {
                        Text("No backgrounds match “\(trimmed)”")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                            .accessibilityIdentifier("background-sets.no-matches")
                    }
                }
                .padding(Self.spacing)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task { await hosted.browseAppeared() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("background-sets.root")
        }
    }

    @ViewBuilder
    private func catalogSection(_ content: HostedCatalogContent, sets: [BackgroundSet], filtering: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if hosted.contents.count > 1 {
                Text(verbatim: Self.header(for: content.url, among: hosted.contents.map(\.url)))
                    .font(.title3.weight(.semibold))
            }
            if let problem = content.problem {
                banner(problem, url: content.url)
            }
            if !filtering, content.catalog == nil, content.problem == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            ForEach(sets) { set in
                setSection(set, catalogURL: content.url)
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
                columns: [GridItem(.adaptive(minimum: Self.minimumCellWidth), spacing: Self.spacing, alignment: .top)],
                alignment: .leading,
                spacing: Self.spacing
            ) {
                ForEach(set.images) { image in
                    let key = HostedImageKey(image)
                    HostedBackgroundCell(
                        image: image,
                        catalogURL: catalogURL,
                        model: model,
                        selection: selection,
                        offersCancel: onPick != nil,
                        activate: { click(image, key: key) }
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("background-sets.set.\(set.name)")
    }

    private func click(_ image: HostedBackgroundImage, key: HostedImageKey) {
        guard let onPick else {
            selection.select(key)
            return
        }
        // After a cancelling click nothing is being picked, so nothing is highlighted.
        selection.select(hosted.pickOrCancel(image) { onPick($0) } == nil ? nil : key)
    }
}

/// Reads the check state, so a check's start and finish re-render only this bar.
private struct BackgroundSetsControls: View {
    let hosted: HostedBackgroundsModel
    @Binding var query: String

    private static let spacing: CGFloat = 16

    var body: some View {
        HStack(spacing: 8) {
            TextField("Filter", text: $query, prompt: Text("Filter sets and images"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .accessibilityIdentifier("background-sets.filter")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Clear Filter"))
                .accessibilityIdentifier("background-sets.filter.clear")
            }
            Spacer()
            if hosted.isCheckingAny {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("background-sets.refreshing")
            }
            Button("Refresh") {
                Task { await hosted.refreshAll() }
            }
            .disabled(hosted.isCheckingAny)
            .help("Check every catalog for new sets")
            .accessibilityIdentifier("background-sets.refresh")
        }
        .padding(.horizontal, Self.spacing)
        .padding(.vertical, 8)
    }
}

private struct HostedBackgroundCell: View {
    let image: HostedBackgroundImage
    let catalogURL: URL
    /// Its uses come from here rather than the grid, so a change to them
    /// re-renders the cells and not the grids.
    let model: BackgroundImagesModel
    let selection: GridSelection<HostedImageKey>
    /// Pick mode, where a click on a downloading image cancels it.
    let offersCancel: Bool
    let activate: () -> Void

    @State private var thumbnail: BackgroundImageThumbnail?
    @State private var digest: String?

    private var hosted: HostedBackgroundsModel { model.hosted }
    private var key: HostedImageKey { HostedImageKey(image) }
    private var accessibilityName: String { HostedBackgroundImage.fileStem(of: image.full) }
    private var isDownloading: Bool { hosted.fetches[key] == .fetching }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The thumbnail's shape isn't known until it loads, so every cell
            // is 16:10 and the picture fits inside.
            Color.clear
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { picture }
                .overlay {
                    if isDownloading {
                        ZStack {
                            Color.black.opacity(0.25)
                            ProgressView().controlSize(.regular)
                        }
                        .allowsHitTesting(false)
                        .accessibilityElement()
                        .accessibilityLabel(Text("Downloading"))
                        .accessibilityIdentifier("background-sets.cell.\(accessibilityName).progress")
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .activeOutline(selection.id == key, cornerRadius: 6)
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
        .contentShape(Rectangle())
        .onTapGesture(perform: activate)
        .accessibilityActions {
            if offersCancel, isDownloading {
                Button("Cancel Download", action: activate)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch hosted.fetches[key] {
        case .fetching:
            EmptyView()
        case .failed(let message):
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .accessibilityIdentifier("background-sets.cell.\(accessibilityName).failed")
        case nil:
            if let digest, !(model.uses[digest] ?? []).isEmpty {
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
