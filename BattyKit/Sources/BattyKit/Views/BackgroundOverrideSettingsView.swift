// BackgroundOverrideSettingsView.swift

import SwiftUI

/// A level of the background chain the sheet can edit: a Pane, a Session, or a
/// Project Editor's draft.
protocol BackgroundOverrideHolder: AnyObject {
    var backgroundOverride: TerminalBackgroundSettings? { get }
    func setBackgroundOverride(_ newOverride: TerminalBackgroundSettings?)
    /// What this level shows while following.
    func inheritedBackground(appWide: TerminalBackgroundSettings) -> TerminalBackgroundSettings
}

/// The sheet's wording and identifiers for one level. Existing UI tests query
/// the Pane's identifiers.
struct BackgroundOverrideScope {
    let title: String
    let followTitle: String
    let customTitle: String
    let identifierPrefix: String

    static func pane(_ pane: PaneRuntime) -> Self {
        Self(
            title: String(localized: "Pane Background"),
            followTitle: pane.sessionBackgroundOverride == nil
                ? String(localized: "Follow App Default")
                : String(localized: "Follow Session"),
            customTitle: String(localized: "Custom for This Pane"),
            identifierPrefix: "pane-background-sheet"
        )
    }

    static var session: Self {
        Self(
            title: String(localized: "Session Background"),
            followTitle: String(localized: "Follow App Default"),
            customTitle: String(localized: "Custom for This Session"),
            identifierPrefix: "session-background-sheet"
        )
    }

    static var project: Self {
        Self(
            title: String(localized: "Project Background"),
            followTitle: String(localized: "Follow Settings"),
            customTitle: String(localized: "Custom for This Project"),
            identifierPrefix: "project-background-sheet"
        )
    }
}

/// The sheet's edits, apart from its view so they can be tested. All writes go
/// through the target's `setBackgroundOverride`, which is idempotent.
@MainActor
struct BackgroundOverrideEditor {
    let target: any BackgroundOverrideHolder
    let appWide: TerminalBackgroundSettings
    let originalOverride: TerminalBackgroundSettings?

    var isFollowing: Bool { target.backgroundOverride == nil }

    var current: TerminalBackgroundSettings {
        target.backgroundOverride ?? target.inheritedBackground(appWide: appWide)
    }

    func selectFollow() {
        target.setBackgroundOverride(nil)
    }

    /// Seeds from the value in effect, which then stops following.
    func selectCustom() {
        guard isFollowing else { return }
        target.setBackgroundOverride(current)
    }

    func cancel() {
        target.setBackgroundOverride(originalOverride)
    }

    /// Ignored while following, so an import that finishes after the user
    /// went back to following can't create an override.
    func update(_ transform: (TerminalBackgroundSettings) -> TerminalBackgroundSettings) {
        guard let override = target.backgroundOverride else { return }
        target.setBackgroundOverride(transform(override))
    }
}

/// Modelled on the Theme Selector, narrow enough to leave the terminal visible
/// because the terminal is the preview: every control applies live.
///
/// Every write to the target's override starts from a user event: a
/// control's `Binding` setter, a button, or the file importer's result. Its
/// observers only render, and `setTerminalConfiguration` touches neither the
/// responder nor layout, so nothing writes back.
struct BackgroundOverrideSettingsView: View {
    @Binding var isPresented: Bool
    let target: any BackgroundOverrideHolder
    let scope: BackgroundOverrideScope
    let appWide: TerminalBackgroundSettings
    let importer: TerminalBackgroundImageImporter

    /// `@State` because the presenting view re-inits this struct freely, and
    /// Cancel must restore what was there when the sheet opened.
    @State private var originalOverride: TerminalBackgroundSettings?
    @State private var importError: String?
    @State private var importTask: Task<Void, Never>?

    init(
        isPresented: Binding<Bool>,
        target: any BackgroundOverrideHolder,
        scope: BackgroundOverrideScope,
        appWide: TerminalBackgroundSettings,
        importer: TerminalBackgroundImageImporter
    ) {
        self._isPresented = isPresented
        self.target = target
        self.scope = scope
        self.appWide = appWide
        self.importer = importer
        self._originalOverride = State(initialValue: target.backgroundOverride)
    }

    private var editor: BackgroundOverrideEditor {
        BackgroundOverrideEditor(target: target, appWide: appWide, originalOverride: originalOverride)
    }

    var body: some View {
        let editor = editor
        let current = editor.current
        VStack(alignment: .leading, spacing: 14) {
            Text(scope.title)
                .font(.headline)

            HStack(spacing: 8) {
                modeCard(
                    title: scope.followTitle,
                    isSelected: editor.isFollowing,
                    identifier: "\(scope.identifierPrefix).follow",
                    action: editor.selectFollow
                )
                modeCard(
                    title: scope.customTitle,
                    isSelected: !editor.isFollowing,
                    identifier: "\(scope.identifierPrefix).custom",
                    action: editor.selectCustom
                )
            }

            TerminalBackgroundControls(
                current: current,
                isImporting: importTask != nil,
                message: importError,
                identifierPrefix: scope.identifierPrefix,
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
                Text("Below 100%, the desktop and other windows show through, except in full screen.")
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
                .accessibilityIdentifier("\(scope.identifierPrefix).cancel")
                Button("Done") {
                    commitTypedOpacity()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                // Done would end the import, which is cancelled on disappear,
                // and drop the image the user just chose.
                .disabled(importTask != nil)
                .accessibilityIdentifier("\(scope.identifierPrefix).done")
            }
        }
        .padding(16)
        .frame(width: 380)
        .onDisappear { importTask?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(scope.identifierPrefix).root")
    }

    private func modeCard(
        title: String,
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
