// AppWideBackgroundGateTests.swift

import CoreGraphics
import Foundation
import GhosttyTerminal
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BattyKit

@MainActor
final class AppWideBackgroundGateTests {
    private let testDefaults = TestDefaults()
    private var defaults: UserDefaults { testDefaults.defaults }
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("batty-gate-tests-\(UUID().uuidString)", isDirectory: true)
    private var directory: URL { root.appendingPathComponent("TerminalBackgrounds", isDirectory: true) }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @MainActor deinit {
        testDefaults.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private func realGate() -> AppWideBackgroundGate {
        .make(defaults: defaults, directory: directory)
    }

    private func png(width: Int = 64, height: Int = 64) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
        return data as Data
    }

    /// A real import, stored with non-default values for every other key.
    private func importAndStore() async throws -> String {
        let source = root.appendingPathComponent("photo.png")
        try png().write(to: source)
        let importer = TerminalBackgroundImageImporter(directory: directory, cleanup: .allButRetained)
        let path = try await importer.importImage(from: source)
        store(path: path)
        return path
    }

    private func store(path: String) {
        defaults.set(path, forKey: SettingsPreference.backgroundImagePathKey)
        defaults.set("cover", forKey: SettingsPreference.backgroundImageFitKey)
        defaults.set("top-left", forKey: SettingsPreference.backgroundImagePositionKey)
        defaults.set(0.35, forKey: SettingsPreference.backgroundImageOpacityKey)
        defaults.set(0.5, forKey: SettingsPreference.backgroundOpacityKey)
    }

    private func lines(_ tab: TabRuntime) -> [String] {
        tab.terminal.renderedConfig.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func backgroundLines(_ tab: TabRuntime) -> [String] {
        lines(tab).filter { $0.hasPrefix("background-") }
    }

    /// The next launch's first Tab: a fresh gate, so no memo carries over.
    private func expectNoImageButOtherLinesKept(_ expected: BackgroundImageState) {
        let gate = realGate()
        #expect(gate.refreshImageState() == expected)
        let tab = TabRuntime(backgroundGate: gate)
        let rendered = lines(tab)
        #expect(tab.terminal.controller.lastConfigurationIssue == nil)
        #expect(!rendered.contains { $0.hasPrefix("background-image") })
        #expect(rendered.contains("background-opacity = 0.5"))
        #expect(rendered.contains { $0.hasPrefix("font-size = ") })
        #expect(rendered.contains("keybind = clear"))
        #expect(rendered.contains("env = BATTY_TAB_ID=\(tab.id.uuidString)"))
    }

    // MARK: - The safe path

    @Test func importedImageReachesTheBuilder() async throws {
        let path = try await importAndStore()
        let tab = TabRuntime(backgroundGate: realGate())
        #expect(backgroundLines(tab) == [
            "background-image = \"\(path)\"",
            "background-image-fit = cover",
            "background-image-position = top-left",
            "background-image-opacity = 0.35",
            "background-opacity = 0.5",
        ])
        #expect(tab.terminal.controller.lastConfigurationIssue == nil)
    }

    @Test func bitFlippedCopyEmitsNoImageAndKeepsOtherOverrides() async throws {
        let path = try await importAndStore()
        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: URL(fileURLWithPath: path))
        expectNoImageButOtherLinesKept(.rejected)
    }

    @Test func truncatedCopyIsRejected() async throws {
        let path = try await importAndStore()
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        try Data(bytes.prefix(bytes.count / 2)).write(to: URL(fileURLWithPath: path))
        expectNoImageButOtherLinesKept(.rejected)
    }

    @Test func oversizedFileSwappedIntoACopyIsRejected() async throws {
        let path = try await importAndStore()
        try png(width: 20000, height: 10).write(to: URL(fileURLWithPath: path))
        expectNoImageButOtherLinesKept(.rejected)
    }

    @Test func missingCopyEmitsNoImage() async throws {
        let path = try await importAndStore()
        try FileManager.default.removeItem(atPath: path)
        expectNoImageButOtherLinesKept(.missing)
    }

    @Test func handEditedPathOutsideTheDirectoryIsRejected() throws {
        let elsewhere = root.appendingPathComponent("elsewhere.png")
        try png().write(to: elsewhere)
        store(path: elsewhere.path)
        expectNoImageButOtherLinesKept(.rejected)
    }

    @Test func pathWithDotDotIsRejected() async throws {
        let path = try await importAndStore()
        let folder = (path as NSString).deletingLastPathComponent
        store(path: "\(folder)/../\((folder as NSString).lastPathComponent)/\((path as NSString).lastPathComponent)")
        expectNoImageButOtherLinesKept(.rejected)
    }

    @Test func folderNotADigestIsRejected() throws {
        let file = directory.appendingPathComponent("not-a-digest/photo.png")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png().write(to: file)
        store(path: file.path)
        expectNoImageButOtherLinesKept(.rejected)
    }

    @Test func fileDirectlyInTheDirectoryIsRejected() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("photo.png")
        try png().write(to: file)
        store(path: file.path)
        expectNoImageButOtherLinesKept(.rejected)
    }

    @Test func nonStringAndJunkStoredValuesFallBack() {
        defaults.set(["/tmp/a.png"], forKey: SettingsPreference.backgroundImagePathKey)
        defaults.set(7, forKey: SettingsPreference.backgroundImageFitKey)
        defaults.set(["x"], forKey: SettingsPreference.backgroundImagePositionKey)
        defaults.set("loud", forKey: SettingsPreference.backgroundImageOpacityKey)
        defaults.set("loud", forKey: SettingsPreference.backgroundOpacityKey)
        defaults.set("loud", forKey: SettingsPreference.backgroundOpacityCellsKey)
        let gate = realGate()
        #expect(gate.settings() == .off)
        let tab = TabRuntime(backgroundGate: gate)
        #expect(backgroundLines(tab).isEmpty)
        #expect(tab.terminal.controller.lastConfigurationIssue == nil)
    }

    // MARK: - No I/O in builders

    @Test func inspectionRunsOncePerPath() {
        store(path: "/tmp/batty-gate-tests/photo.png")
        var count = 0
        let gate = AppWideBackgroundGate(defaults: defaults) { _ in
            count += 1
            return .usable
        }
        let tabs = (0..<10).map { _ in TabRuntime(backgroundGate: gate) }
        tabs[0].attachContext(paneID: UUID(), sessionID: UUID())
        #expect(count == 1)
    }

    @Test func changedPathIsInspectedAgain() {
        store(path: "/tmp/batty-gate-tests/a.png")
        var inspected: [String] = []
        let gate = AppWideBackgroundGate(defaults: defaults) { path in
            inspected.append(path)
            return .usable
        }
        _ = gate.settings()
        store(path: "/tmp/batty-gate-tests/b.png")
        _ = gate.settings()
        #expect(inspected == ["/tmp/batty-gate-tests/a.png", "/tmp/batty-gate-tests/b.png"])
    }

    @Test func refreshSeesAFileThatChanged() async throws {
        let path = try await importAndStore()
        let gate = realGate()
        #expect(gate.settings().imagePath == path)
        try Data("corrupt".utf8).write(to: URL(fileURLWithPath: path))
        #expect(gate.refreshImageState() == .rejected)
        #expect(gate.settings().imagePath == nil)
    }

    @Test func rejectedImageIsNotSeededIntoAPaneOverride() throws {
        let elsewhere = root.appendingPathComponent("elsewhere.png")
        try png().write(to: elsewhere)
        store(path: elsewhere.path)
        let gate = realGate()
        let pane = PaneRuntime(tabBackgroundGate: gate)
        BackgroundOverrideEditor(target: pane, appWide: gate.settings(), originalOverride: nil).selectCustom()
        let override = try #require(pane.backgroundOverride)
        #expect(override.imagePath == nil)
        #expect(override.terminalOpacity == 0.5)
    }
}
