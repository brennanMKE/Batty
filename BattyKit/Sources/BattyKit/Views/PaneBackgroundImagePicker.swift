// PaneBackgroundImagePicker.swift

import OSLog
import SwiftUI

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "PaneBackgroundImagePicker")

extension Notification.Name {
    /// Pane > Background Images…; the userInfo names the window and the Pane.
    static let battyChoosePaneBackgroundImage = Notification.Name("co.sstools.Batty.choosePaneBackgroundImage")
}

/// Pane > Background Images…: the picker for one terminal Pane, whose pick
/// sets that Pane's own image the way Choose… in its gear sheet does.
enum PaneBackgroundImagePicker {
    static let windowIDKey = "windowID"
    static let paneIDKey = "paneID"

    /// Copies the library image into the importer's folder, then writes it
    /// through the gear sheet's editor, so a Pane that followed gets its own
    /// override seeded from what it showed. Writes nothing when the copy fails.
    static func apply(
        libraryPath: String,
        to pane: PaneRuntime,
        appWide: TerminalBackgroundSettings,
        importer: TerminalBackgroundImageImporter,
        sources: [URL]
    ) async -> Bool {
        guard let adopted = await importer.adoptImage(path: libraryPath, from: sources) else { return false }
        guard !Task.isCancelled else { return false }
        let editor = BackgroundOverrideEditor(target: pane, appWide: appWide, originalOverride: pane.backgroundOverride)
        editor.selectCustom()
        editor.update { $0.pickingImage(path: adopted) }
        return true
    }
}

/// Every write starts from a pick or from closing the picker. Each pick
/// applies without closing; a newer pick cancels an older one still copying.
struct PaneBackgroundImagePickerSheet: View {
    let pane: PaneRuntime
    let store: AppStateStore
    @Binding var isPresented: Bool

    /// Not cancelled on disappear, so a double click's apply still lands.
    @State private var applyTask: Task<Void, Never>?

    var body: some View {
        BackgroundImagesView(
            model: store.backgroundImages,
            current: pane.effectiveBackground(appWide: store.backgroundGate.settings()).value.imagePath,
            onPick: pick,
            onClose: { isPresented = false }
        )
    }

    private func pick(_ path: String) {
        let pane = pane
        let appWide = store.backgroundGate.settings()
        let importer = store.backgroundImageImporter
        let sources = store.backgroundImages.pickSources
        applyTask?.cancel()
        applyTask = Task {
            let applied = await PaneBackgroundImagePicker.apply(libraryPath: path, to: pane, appWide: appWide, importer: importer, sources: sources)
            if !applied, !Task.isCancelled {
                logger.error("could not use the picked image for a Pane")
            }
        }
    }
}
