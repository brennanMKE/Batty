// TerminalBackgroundControls.swift

import SwiftUI
import UniformTypeIdentifiers

/// The controls every background level shares. It owns no import: the caller
/// runs the importer and says what to show while it does.
struct TerminalBackgroundControls: View {
    let current: TerminalBackgroundSettings
    let isImporting: Bool
    let message: String?
    let identifierPrefix: String
    let update: ((TerminalBackgroundSettings) -> TerminalBackgroundSettings) -> Void
    let onPickedFile: (URL) -> Void
    let onFileError: () -> Void
    let onRemoveImage: () -> Void

    @State private var isChoosingImage = false

    var body: some View {
        imageRow
        imageOptions
        opacityRow(
            "Terminal Opacity",
            fieldLabel: String(localized: "Terminal Opacity Percent"),
            value: current.terminalOpacity,
            identifier: "\(identifierPrefix).terminal-opacity"
        ) { value in update { $0.withTerminalOpacity(value) } }
        Toggle("Include programs that paint their own background", isOn: Binding(
            get: { current.opacityAffectsCells },
            set: { value in update { $0.withOpacityAffectsCells(value) } }
        ))
        .disabled(current.terminalOpacity >= 1)
        .accessibilityIdentifier("\(identifierPrefix).opacity-cells")
    }

    private var imageRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Image")
                Spacer()
                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("\(identifierPrefix).importing")
                }
                Text(current.imagePath.map(Self.displayName(forPath:)) ?? String(localized: "None"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("Choose…") { isChoosingImage = true }
                    .accessibilityIdentifier("\(identifierPrefix).choose-image")
                Button("None", action: onRemoveImage)
                    .disabled(current.imagePath == nil && !isImporting)
                    .accessibilityIdentifier("\(identifierPrefix).no-image")
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        // On this one view: a modifier on a multi-view container can apply to
        // each member, which would attach one importer per row.
        .fileImporter(isPresented: $isChoosingImage, allowedContentTypes: [.png, .jpeg]) { result in
            switch result {
            case .success(let url): onPickedFile(url)
            case .failure: onFileError()
            }
        }
    }

    private var imageOptions: some View {
        Group {
            Picker("Image Size", selection: Binding(
                get: { current.fit },
                set: { value in update { $0.withFit(value) } }
            )) {
                ForEach(BackgroundImageFit.allCases, id: \.self) { fit in
                    Text(fit.displayName).tag(fit)
                }
            }
            Picker("Position", selection: Binding(
                get: { current.position },
                set: { value in update { $0.withPosition(value) } }
            )) {
                ForEach(BackgroundImagePosition.allCases, id: \.self) { position in
                    Text(verbatim: position.rawValue.replacingOccurrences(of: "-", with: " ").capitalized).tag(position)
                }
            }
            opacityRow(
                "Image Opacity",
                fieldLabel: String(localized: "Image Opacity Percent"),
                value: current.imageOpacity,
                identifier: "\(identifierPrefix).image-opacity"
            ) { value in update { $0.withImageOpacity(value) } }
        }
        .disabled(current.imagePath == nil)
    }

    /// The `0.05` step caps a full drag at 20 config updates per Tab, each of
    /// which costs the renderer. A typed value keeps its whole percent: only a
    /// drag lands on the grid. A stored value above 1 shows at the end of the
    /// track and isn't rewritten until a control changes it.
    private func opacityRow(
        _ title: LocalizedStringKey,
        fieldLabel: String,
        value: Double,
        identifier: String,
        set: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Text(title)
            Slider(
                value: Binding(
                    get: { min(value, 1) },
                    set: { set(($0 * 20).rounded() / 20) }
                ),
                in: 0...1,
                step: 0.05
            )
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(title)
            OpacityPercentField(
                value: value,
                label: fieldLabel,
                identifier: "\(identifier)-field",
                onCommit: set
            )
            Text(verbatim: "%")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private static func displayName(forPath path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
