// PaneBackgroundImagePickerTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Pane > Background Images…: a pick writes the Pane's own image through the
/// gear sheet's editor.
@MainActor
final class PaneBackgroundImagePickerTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("batty-pane-picker-tests-\(UUID().uuidString)", isDirectory: true)
    private var libraryFolder: URL { root.appendingPathComponent("library", isDirectory: true) }
    private var importedFolder: URL { root.appendingPathComponent("imported/111", isDirectory: true) }

    private let testDefaults = TestDefaults()
    private var defaults: UserDefaults { testDefaults.defaults }
    private var gate: AppWideBackgroundGate { .acceptingEveryImage(defaults: defaults) }

    private static let otherPath = "/tmp/batty-pane-picker-tests/other.png"
    private static let paneCustom = TerminalBackgroundSettings(
        imagePath: otherPath, fit: .contain, position: .topRight, imageOpacity: 0.4, terminalOpacity: 0.6
    )
    private static let appWide = TerminalBackgroundSettings(
        imagePath: nil, fit: .contain, position: .bottomLeft, imageOpacity: 0.35, terminalOpacity: 0.7
    )

    @MainActor deinit {
        testDefaults.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private func pane(tabCount: Int = 1) -> PaneRuntime {
        PaneRuntime(tabs: (0..<tabCount).map { _ in TabRuntime(backgroundGate: gate) }, tabBackgroundGate: gate)
    }

    private func importer() -> TerminalBackgroundImageImporter {
        TerminalBackgroundImageImporter(directory: importedFolder, cleanup: .deadProcessFolders, isProcessAlive: { _ in false })
    }

    private func libraryImage() throws -> String {
        let data = try BackgroundTestImage.encoded(width: 32, height: 32)
        let folder = libraryFolder.appendingPathComponent(BackgroundTestImage.digest(of: data), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("photo.png")
        try data.write(to: file)
        return file.path
    }

    private func apply(_ path: String, to pane: PaneRuntime) async -> Bool {
        await PaneBackgroundImagePicker.apply(
            libraryPath: path, to: pane, appWide: Self.appWide, importer: importer(), sources: [libraryFolder]
        )
    }

    @Test func pickOnAFollowingPaneSetsItsOwnImage() async throws {
        let pane = pane()
        #expect(pane.backgroundOverride == nil)
        #expect(await apply(try libraryImage(), to: pane))
        let override = try #require(pane.backgroundOverride)
        let path = try #require(override.imagePath)
        #expect(path.hasPrefix(importedFolder.path))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(override.fit == Self.appWide.fit)
        #expect(override.position == Self.appWide.position)
        #expect(override.terminalOpacity == Self.appWide.terminalOpacity)
        #expect(override.imageOpacity == TerminalBackgroundSettings.firstImageOpacity)
    }

    @Test func pickKeepsTheOverridesOtherSettings() async throws {
        let pane = pane()
        pane.setBackgroundOverride(Self.paneCustom)
        #expect(await apply(try libraryImage(), to: pane))
        let override = try #require(pane.backgroundOverride)
        #expect(override.imagePath != Self.otherPath)
        #expect(override.withImagePath(Self.otherPath) == Self.paneCustom)
    }

    @Test func anUnreadablePathLeavesThePaneUnchanged() async throws {
        let pane = pane()
        pane.setBackgroundOverride(Self.paneCustom)
        let missing = libraryFolder.appendingPathComponent("missing/photo.png").path
        #expect(await apply(missing, to: pane) == false)
        #expect(pane.backgroundOverride == Self.paneCustom)
    }

    @Test func aPickReplacesTheTabsOwnValuesLikeTheGearSheet() async throws {
        let pane = pane(tabCount: 2)
        pane.tabs[0].setBackgroundOverride(Self.paneCustom)
        #expect(await apply(try libraryImage(), to: pane))
        let override = try #require(pane.backgroundOverride)
        #expect(override.imagePath?.hasPrefix(importedFolder.path) == true)
        #expect(override.fit == Self.paneCustom.fit)
        for tab in pane.tabs {
            #expect(tab.backgroundOverride == nil)
        }
    }
}
