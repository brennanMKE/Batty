// BackgroundOverrideSettingsView.swift

import SwiftUI

/// A level of the background chain the sheet can edit: a Tab, a Pane, a
/// Session, or a Project Editor's draft or one of its Tabs.
protocol BackgroundOverrideHolder: AnyObject {
    var backgroundOverride: TerminalBackgroundSettings? { get }
    func setBackgroundOverride(_ newOverride: TerminalBackgroundSettings?)
    /// What this level shows while following.
    func inheritedBackground(appWide: TerminalBackgroundSettings) -> TerminalBackgroundSettings
    /// Whether Cancel should put this path back even if its file is gone,
    /// because a saved value names it and the holder reports that itself.
    func isSavedImagePath(_ path: String) -> Bool
    /// The narrower levels' own values that a write here replaces, keyed by
    /// Tab id, so Cancel can put them back.
    func replacedOverrides() -> [UUID: TerminalBackgroundSettings]
    func restoreReplacedOverrides(_ overrides: [UUID: TerminalBackgroundSettings])
}

extension BackgroundOverrideHolder {
    func isSavedImagePath(_ path: String) -> Bool { false }
    func replacedOverrides() -> [UUID: TerminalBackgroundSettings] { [:] }
    func restoreReplacedOverrides(_ overrides: [UUID: TerminalBackgroundSettings]) {}
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

    static func tab(_ tab: TabRuntime) -> Self {
        let followTitle: String = if tab.paneBackgroundOverride != nil {
            String(localized: "Follow Pane")
        } else if tab.sessionBackgroundOverride != nil {
            String(localized: "Follow Session")
        } else {
            String(localized: "Follow App Default")
        }
        return Self(
            title: String(localized: "Tab Background"),
            followTitle: followTitle,
            customTitle: String(localized: "Custom for This Tab"),
            identifierPrefix: "tab-background-sheet"
        )
    }

    static var projectTab: Self {
        Self(
            title: String(localized: "Tab Background"),
            followTitle: String(localized: "Follow Project"),
            customTitle: String(localized: "Custom for This Tab"),
            identifierPrefix: "project-tab-background-sheet"
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
    var replacedOverrides: [UUID: TerminalBackgroundSettings] = [:]

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

    /// A copy-shaped path whose file is gone was removed in the Background
    /// Images window while this sheet was open: new Tabs must not get it back.
    func cancel() {
        target.setBackgroundOverride(originalOverride.map(restorable))
        if !replacedOverrides.isEmpty {
            target.restoreReplacedOverrides(replacedOverrides.mapValues(restorable))
        }
    }

    private func restorable(_ value: TerminalBackgroundSettings) -> TerminalBackgroundSettings {
        if let path = value.imagePath,
           TerminalBackgroundImageImporter.digest(ofPath: path) != nil,
           !target.isSavedImagePath(path),
           !FileManager.default.fileExists(atPath: path) {
            return value.withImagePath(nil)
        }
        return value
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
/// control's `Binding` setter, a button, or the picker's choice. Its
/// observers only render, and `setTerminalConfiguration` touches neither the
/// responder nor layout, so nothing writes back.
struct BackgroundOverrideSettingsView: View {
    @Binding var isPresented: Bool
    let target: any BackgroundOverrideHolder
    let scope: BackgroundOverrideScope
    let appWide: TerminalBackgroundSettings
    let importer: TerminalBackgroundImageImporter
    let images: BackgroundImagesModel

    /// `@State` because the presenting view re-inits this struct freely, and
    /// Cancel must restore what was there when the sheet opened.
    @State private var originalOverride: TerminalBackgroundSettings?
    @State private var replacedOverrides: [UUID: TerminalBackgroundSettings]
    @State private var importError: String?
    @State private var importTask: Task<Void, Never>?

    init(
        isPresented: Binding<Bool>,
        target: any BackgroundOverrideHolder,
        scope: BackgroundOverrideScope,
        appWide: TerminalBackgroundSettings,
        importer: TerminalBackgroundImageImporter,
        images: BackgroundImagesModel
    ) {
        self._isPresented = isPresented
        self.target = target
        self.scope = scope
        self.appWide = appWide
        self.importer = importer
        self.images = images
        self._originalOverride = State(initialValue: target.backgroundOverride)
        self._replacedOverrides = State(initialValue: target.replacedOverrides())
    }

    private var editor: BackgroundOverrideEditor {
        BackgroundOverrideEditor(target: target, appWide: appWide, originalOverride: originalOverride, replacedOverrides: replacedOverrides)
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
                images: images,
                onPickedLibraryImage: startAdopt(ofLibraryPath:),
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

    private func startAdopt(ofLibraryPath libraryPath: String) {
        cancelImport()
        let importer = importer
        let editor = editor
        let sources = images.pickSources
        importTask = Task {
            let adopted = await importer.adoptImage(path: libraryPath, from: sources)
            guard !Task.isCancelled else { return }
            if let adopted {
                editor.update { $0.pickingImage(path: adopted) }
            } else {
                importError = String(localized: "That image could not be read.")
            }
            importTask = nil
        }
    }
}
