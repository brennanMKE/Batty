// PaneBackgroundSettingsView.swift

import SwiftUI

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

            TerminalBackgroundControls(
                current: current,
                isImporting: importTask != nil,
                message: importError,
                identifierPrefix: "pane-background-sheet",
                update: { editor.update($0) },
                onPickedFile: startImport(of:),
                onFileError: { importError = String(localized: "That file could not be opened.") },
                onRemoveImage: {
                    cancelImport()
                    editor.update { $0.withImagePath(nil) }
                }
            )
            .disabled(editor.isFollowing)

            VStack(alignment: .leading, spacing: 4) {
                Text("The Pane shows over the Theme's window color, not the desktop.")
                Text("Programs that paint their own background stay opaque unless you include them. Image opacity is relative to terminal opacity.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    commitTypedOpacity()
                    cancelImport()
                    editor.cancel()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("pane-background-sheet.cancel")
                Button("Done") {
                    commitTypedOpacity()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                // Done would end the import, which is cancelled on disappear,
                // and drop the image the user just chose.
                .disabled(importTask != nil)
                .accessibilityIdentifier("pane-background-sheet.done")
            }
        }
        .padding(16)
        .frame(width: 380)
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

    /// Clicking a button doesn't end editing. Without this, a typed opacity
    /// would be lost on Done, or commit as the sheet closes and undo Cancel.
    /// Runs in a button's action, outside any view update.
    private func commitTypedOpacity() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importError = nil
    }

    private func startImport(of url: URL) {
        cancelImport()
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
            importTask = nil
        }
    }
}
