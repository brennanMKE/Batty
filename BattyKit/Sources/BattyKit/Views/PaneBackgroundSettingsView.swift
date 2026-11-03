// PaneBackgroundSettingsView.swift

import SwiftUI
import UniformTypeIdentifiers

/// The sheet's edits, apart from its view so they can be tested. All writes go
/// through `PaneRuntime.setBackgroundOverride`, which is idempotent.
@MainActor
struct PaneBackgroundEditor {
    let pane: PaneRuntime
    let appWide: TerminalBackgroundSettings
    let originalOverride: TerminalBackgroundSettings?

    var isFollowing: Bool { pane.backgroundOverride == nil }

    var current: TerminalBackgroundSettings {
        .effective(pane: pane.backgroundOverride, appWide: appWide)
    }

    func selectFollow() {
        pane.setBackgroundOverride(nil)
    }

    /// Seeds from the value in effect, which then stops following.
    func selectCustom() {
        guard isFollowing else { return }
        pane.setBackgroundOverride(current)
    }

    func cancel() {
        pane.setBackgroundOverride(originalOverride)
    }

    /// Ignored while following, so an import that finishes after the user
    /// went back to following can't create an override.
    func update(_ transform: (TerminalBackgroundSettings) -> TerminalBackgroundSettings) {
        guard let override = pane.backgroundOverride else { return }
        pane.setBackgroundOverride(transform(override))
    }
}

/// Modelled on the Theme Selector, narrow enough to leave the terminal visible
/// because the terminal is the preview: every control applies live.
///
/// Every write to `pane.backgroundOverride` starts from a user event: a
/// control's `Binding` setter, a button, or the file importer's result. Its
/// observers only render, and `setTerminalConfiguration` touches neither the
/// responder nor layout, so nothing writes back.
struct PaneBackgroundSettingsView: View {
    @Binding var isPresented: Bool
    let pane: PaneRuntime
    let appWide: TerminalBackgroundSettings
    let importer: TerminalBackgroundImageImporter

    /// `@State` because the presenting view re-inits this struct freely, and
    /// Cancel must restore what was there when the sheet opened.
    @State private var originalOverride: TerminalBackgroundSettings?
    @State private var isChoosingImage = false
    @State private var importError: String?
    @State private var importTask: Task<Void, Never>?

    init(
        isPresented: Binding<Bool>,
        pane: PaneRuntime,
        appWide: TerminalBackgroundSettings,
        importer: TerminalBackgroundImageImporter
    ) {
        self._isPresented = isPresented
        self.pane = pane
        self.appWide = appWide
        self.importer = importer
        self._originalOverride = State(initialValue: pane.backgroundOverride)
    }

    private var editor: PaneBackgroundEditor {
        PaneBackgroundEditor(pane: pane, appWide: appWide, originalOverride: originalOverride)
    }

    var body: some View {
        let editor = editor
        let current = editor.current
        VStack(alignment: .leading, spacing: 14) {
            Text("Pane Background")
                .font(.headline)

            HStack(spacing: 8) {
                modeCard(
                    title: "Follow App Default",
                    isSelected: editor.isFollowing,
                    identifier: "pane-background-sheet.follow",
                    action: editor.selectFollow
                )
                modeCard(
                    title: "Custom for This Pane",
                    isSelected: !editor.isFollowing,
                    identifier: "pane-background-sheet.custom",
                    action: editor.selectCustom
                )
            }

            Group {
                imageRow(current: current)
                imageOptions(current: current)
                opacitySlider(
                    "Terminal Opacity",
                    value: current.terminalOpacity,
                    identifier: "pane-background-sheet.terminal-opacity"
                ) { value in editor.update { $0.withTerminalOpacity(value) } }
            }
            .disabled(editor.isFollowing)

            VStack(alignment: .leading, spacing: 4) {
                Text("The Pane shows over the Theme's window color, not the desktop.")
                Text("Programs that paint their own background stay opaque.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    importTask?.cancel()
                    editor.cancel()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("pane-background-sheet.cancel")
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("pane-background-sheet.done")
            }
        }
        .padding(16)
        .frame(width: 380)
        .fileImporter(isPresented: $isChoosingImage, allowedContentTypes: [.png, .jpeg]) { result in
            switch result {
            case .success(let url):
                startImport(of: url)
            case .failure:
                importError = String(localized: "That file could not be opened.")
            }
        }
        .onDisappear { importTask?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane-background-sheet.root")
    }

    private func modeCard(
        title: LocalizedStringKey,
        isSelected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
        .activeOutline(isSelected, cornerRadius: 6)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(isSelected ? "selected" : "unselected")
    }

    @ViewBuilder
    private func imageRow(current: TerminalBackgroundSettings) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Image")
                Spacer()
                Text(current.imagePath.map(Self.displayName(forPath:)) ?? String(localized: "None"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("Choose…") { isChoosingImage = true }
                    .accessibilityIdentifier("pane-background-sheet.choose-image")
                Button("None") {
                    importTask?.cancel()
                    importError = nil
                    editor.update { $0.withImagePath(nil) }
                }
                .disabled(current.imagePath == nil)
                .accessibilityIdentifier("pane-background-sheet.no-image")
            }
            if let importError {
                Text(importError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func imageOptions(current: TerminalBackgroundSettings) -> some View {
        Group {
            Picker("Fit", selection: Binding(
                get: { current.fit },
                set: { value in editor.update { $0.withFit(value) } }
            )) {
                ForEach(BackgroundImageFit.allCases, id: \.self) { fit in
                    Text(verbatim: fit.rawValue.capitalized).tag(fit)
                }
            }
            Picker("Position", selection: Binding(
                get: { current.position },
                set: { value in editor.update { $0.withPosition(value) } }
            )) {
                ForEach(BackgroundImagePosition.allCases, id: \.self) { position in
                    Text(verbatim: position.rawValue.replacingOccurrences(of: "-", with: " ").capitalized).tag(position)
                }
            }
            opacitySlider(
                "Image Opacity",
                value: current.imageOpacity,
                identifier: "pane-background-sheet.image-opacity"
            ) { value in editor.update { $0.withImageOpacity(value) } }
        }
        .disabled(current.imagePath == nil)
    }

    /// The `0.05` step caps a full drag at 20 config updates per Tab, each of
    /// which costs the renderer. A stored value above 1 shows at the end of
    /// the track and isn't rewritten until the slider moves.
    private func opacitySlider(
        _ title: LocalizedStringKey,
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
        }
    }

    private func startImport(of url: URL) {
        importTask?.cancel()
        importError = nil
        let importer = importer
        let editor = editor
        importTask = Task {
            do {
                let path = try await importer.importImage(from: url)
                guard !Task.isCancelled else { return }
                editor.update { $0.pickingImage(path: path) }
            } catch {
                guard !Task.isCancelled else { return }
                importError = String(localized: "That image could not be read.")
            }
        }
    }

    private static func displayName(forPath path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
