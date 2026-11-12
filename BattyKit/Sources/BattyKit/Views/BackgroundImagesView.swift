// BackgroundImagesView.swift

import SwiftUI
import UniformTypeIdentifiers

/// The Background Images window's content, and with `.pick` the sheet a
/// background control opens over whatever asked. Nothing in `body` writes
/// observed state: the model's writes start from `.task`, a button or the file
/// importer's result, and each cell's picture is its own `@State`.
struct BackgroundImagesView: View {
    enum Mode {
        case manage
        case pick(current: String?, onPick: (String) -> Void, onCancel: () -> Void)
    }

    enum Tab: Hashable {
        case myImages
        case backgroundSets
    }

    let model: BackgroundImagesModel
    let mode: Mode

    @State private var tab: Tab = .myImages
    @State private var selectedDigest: String?
    @State private var isAdding = false
    @State private var removal: BackgroundImagesModel.RemovalPlan?
    @FocusState private var gridFocused: Bool

    private static let minimumCellWidth: CGFloat = 170
    private static let spacing: CGFloat = 16

    private var isPicking: Bool {
        if case .pick = mode { return true }
        return false
    }

    private var currentDigest: String? {
        guard case .pick(let current, _, _) = mode else { return nil }
        return current.flatMap(TerminalBackgroundImageImporter.digest(ofPath:))
    }

    var body: some View {
        VStack(spacing: 0) {
            if case .pick = mode {
                HStack {
                    Text("Choose an Image")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
            }
            Picker("", selection: tabBinding) {
                Text("My Images").tag(Tab.myImages)
                Text("Background Sets").tag(Tab.backgroundSets)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 8)
            .accessibilityIdentifier("background-images.tab")
            Divider()
            switch tab {
            case .myImages:
                content
            case .backgroundSets:
                BackgroundSetsView(
                    hosted: model.hosted,
                    uses: model.uses,
                    onPick: pickHandler
                )
            }
            Divider()
            bottomBar
        }
        .frame(
            minWidth: isPicking ? 620 : 520,
            idealWidth: isPicking ? 620 : 760,
            minHeight: isPicking ? 460 : 400,
            idealHeight: isPicking ? 460 : 560
        )
        .task { await model.refresh() }
        // Touches no observed state: the generation is observation-ignored and
        // a cancelled fetch clears its cell from its own task.
        .onDisappear { if isPicking { model.hosted.supersedePicks() } }
        // Writes here, outside the GeometryReader. On the first open of a launch
        // the grid doesn't exist until the scan's `await` writes `entries`, so
        // that flip is an event, not layout.
        .defaultFocus($gridFocused, true, priority: .userInitiated)
        .onAppear { if tab == .myImages { gridFocused = true } }
        .onChange(of: model.entries.isEmpty) { _, isEmpty in
            if !isEmpty, tab == .myImages { gridFocused = true }
        }
        .confirmationDialog(
            removal.map(Self.dialogTitle) ?? "",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            presenting: removal
        ) { plan in
            if plan.refusal == nil {
                Button("Remove", role: .destructive) {
                    Task { await model.remove(plan.entry) }
                }
                .accessibilityIdentifier("background-images.confirm-remove")
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { plan in
            Text(Self.dialogMessage(plan))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isPicking ? "background-images.picker.root" : "background-images.root")
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                if model.isScanning {
                    ProgressView()
                } else {
                    Text("No background images yet.")
                        .foregroundStyle(.secondary)
                    Button("Add from File…") { isAdding = true }
                        .accessibilityIdentifier("background-images.empty-add")
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("background-images.empty")
        } else {
            // Read here rather than stored: the width only computes a local
            // for this pass, so a resize writes nothing observed.
            GeometryReader { geometry in
                let columns = max(1, Int((geometry.size.width - Self.spacing) / (Self.minimumCellWidth + Self.spacing)))
                grid(columns: columns)
            }
        }
    }

    private func grid(columns: Int) -> some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top), count: columns),
                spacing: Self.spacing
            ) {
                ForEach(model.entries) { entry in
                    BackgroundImageCell(
                        entry: entry,
                        uses: model.uses[entry.digest] ?? [],
                        sharedStatus: model.sharedStatus(forDigest: entry.digest),
                        thumbnailer: model.thumbnailer,
                        isHighlighted: entry.digest == selectedDigest || entry.digest == currentDigest
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { click(entry) }
                    .contextMenu {
                        if !isPicking {
                            Button("Remove…") { requestRemoval(of: entry) }
                        }
                    }
                }
            }
            .padding(Self.spacing)
        }
        // The grid holds focus itself: a zero-size holder set from inside this
        // GeometryReader never took it, and the arrow keys selected nothing.
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onKeyPress(.leftArrow) { move(.left, columns: columns); return .handled }
        .onKeyPress(.rightArrow) { move(.right, columns: columns); return .handled }
        .onKeyPress(.upArrow) { move(.up, columns: columns); return .handled }
        .onKeyPress(.downArrow) { move(.down, columns: columns); return .handled }
        .onKeyPress(.return) { activateSelection(); return .handled }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard !isPicking else { return .ignored }
            requestRemovalOfSelection()
            return .handled
        }
    }

    /// The segment's own action is the event that moves focus back to the grid.
    private var tabBinding: Binding<Tab> {
        Binding(
            get: { tab },
            set: { newValue in
                guard newValue != tab else { return }
                tab = newValue
                if newValue == .myImages { gridFocused = true }
            }
        )
    }

    private var pickHandler: ((String) -> Void)? {
        guard case .pick(_, let onPick, _) = mode else { return nil }
        return onPick
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if tab == .myImages {
                myImagesButtons
            }
            Spacer()
            if tab == .myImages {
                Text(total)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("background-images.total")
            }
            if case .pick(_, _, let onCancel) = mode {
                Button("Cancel") {
                    model.hosted.supersedePicks()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("background-images.picker.cancel")
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var myImagesButtons: some View {
        // On this one button, with the file panel's result handled here: a
        // modifier on a multi-view container can apply to each member, which
        // would attach one importer per row.
        Button("Add from File…") { isAdding = true }
            .accessibilityIdentifier("background-images.add")
            .fileImporter(isPresented: $isAdding, allowedContentTypes: [.png, .jpeg]) { result in
                switch result {
                case .success(let url): add(url)
                case .failure: model.reportFileError()
                }
            }
        if !isPicking {
            Button("Remove…") { requestRemovalOfSelection() }
                .disabled(selectedEntry == nil)
                .accessibilityIdentifier("background-images.remove")
        }
        if let message = model.message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("background-images.message")
        }
    }

    private var total: String {
        let size = ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file)
        return model.entries.count == 1
            ? String(localized: "1 image, \(size)", comment: "Background Images: the footer total")
            : String(localized: "\(model.entries.count) images, \(size)", comment: "Background Images: the footer total")
    }

    private var selectedEntry: BackgroundImageEntry? {
        model.entries.first { $0.digest == selectedDigest }
    }

    private func move(_ direction: ProjectPickerDirection, columns: Int) {
        let digests = model.entries.map(\.digest)
        guard !digests.isEmpty else { return }
        let cursor = ProjectPickerGridCursor(sections: [.init(columns: columns, count: digests.count)])
        let start = selectedDigest.flatMap(digests.firstIndex(of:))
            ?? currentDigest.flatMap(digests.firstIndex(of:))
        selectedDigest = digests[start.map { cursor.moved(from: $0, direction) } ?? 0]
    }

    private func click(_ entry: BackgroundImageEntry) {
        selectedDigest = entry.digest
        gridFocused = true
        if isPicking { pick(entry) }
    }

    private func activateSelection() {
        guard isPicking, let entry = selectedEntry else { return }
        pick(entry)
    }

    /// Asks the thumbnailer rather than the cell, whose picture may still be
    /// loading: a cell that turns out usable is picked once the check finishes,
    /// and one the check rejects, as "Can't be used" shows, never is.
    private func pick(_ entry: BackgroundImageEntry) {
        guard case .pick(_, let onPick, _) = mode else { return }
        model.hosted.supersedePicks()
        let thumbnailer = model.thumbnailer
        Task {
            guard await thumbnailer.thumbnail(for: entry).state == .usable else { return }
            onPick(entry.path)
        }
    }

    private func add(_ url: URL) {
        if isPicking { model.hosted.supersedePicks() }
        Task {
            guard let entry = await model.add(from: url) else { return }
            selectedDigest = entry.digest
            if case .pick(_, let onPick, _) = mode { onPick(entry.path) }
        }
    }

    private func requestRemovalOfSelection() {
        guard let entry = selectedEntry else { return }
        requestRemoval(of: entry)
    }

    private func requestRemoval(of entry: BackgroundImageEntry) {
        removal = model.prepareRemoval(entry)
    }

    private static func dialogTitle(_ plan: BackgroundImagesModel.RemovalPlan) -> String {
        plan.refusal == nil
            ? String(localized: "Remove \(plan.entry.name)?", comment: "Background Images: the Remove confirmation's title")
            : String(localized: "\(plan.entry.name) can't be removed", comment: "Background Images: the title when Remove is refused")
    }

    private static func dialogMessage(_ plan: BackgroundImagesModel.RemovalPlan) -> String {
        if let refusal = plan.refusal { return refusal }
        guard !plan.uses.isEmpty else {
            return String(localized: "It isn't in use on this Mac.", comment: "Background Images: the Remove confirmation for an unused image")
        }
        let list = plan.uses.map(\.localizedDescription).joined(separator: "\n")
        let message = String(localized: "These will have no image:\n\(list)", comment: "Background Images: the Remove confirmation; the argument lists the image's uses, one per line")
        guard plan.keepsOnOtherMacs else { return message }
        let warning = String(localized: "Your other Macs keep this image. It comes back here if another Mac changes that Project.", comment: "Background Images: the Remove confirmation when a Shared Project uses the image")
        return message + "\n\n" + warning
    }
}

private struct BackgroundImageCell: View {
    let entry: BackgroundImageEntry
    let uses: [BackgroundImageUse]
    let sharedStatus: SharedImageStatus?
    let thumbnailer: BackgroundImageThumbnailer
    let isHighlighted: Bool

    @State private var thumbnail: BackgroundImageThumbnail?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            picture
                .frame(maxWidth: .infinity)
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .activeOutline(isHighlighted, cornerRadius: 6)
            Text(entry.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(ByteCountFormatter.string(fromByteCount: entry.sizeInBytes, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("background-images.cell.\(entry.name).size")
            Text(usesLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("background-images.cell.\(entry.name).uses")
            if let sharedStatus {
                Text(sharedStatus == .inICloudDrive
                    ? String(localized: "In iCloud Drive for a Shared Project", comment: "Background Images: this image's copy is in iCloud Drive")
                    : String(localized: "Waiting to upload", comment: "Background Images: this Shared Project image hasn't reached iCloud Drive yet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("background-images.cell.\(entry.name).shared")
            }
        }
        .task(id: entry.digest) {
            thumbnail = await thumbnailer.thumbnail(for: entry)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("background-images.cell.\(entry.name)")
    }

    @ViewBuilder
    private var picture: some View {
        if let image = thumbnail?.image {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if thumbnail == nil {
            ProgressView().controlSize(.small)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                Text("Can't be used")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var usesLine: String {
        uses.isEmpty
            ? String(localized: "Not in use", comment: "Background Images: an image nothing on this Mac uses")
            : uses.map(\.localizedDescription).joined(separator: ", ")
    }
}
