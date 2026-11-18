// BackgroundImagesViewScrollTests.swift

import AppKit
import SwiftUI
import Testing
@testable import BattyKit

/// Hosts the real `BackgroundImagesView` over a library too tall for the
/// window and checks where My Images opens: scrolled to the current image,
/// whether the scan had finished before the sheet appeared or finishes after.
@MainActor
struct BackgroundImagesViewScrollTests {
    private let f: ProjectBackgroundFixture

    init() throws { f = try ProjectBackgroundFixture() }

    /// 24 images, eight rows at the picker's three columns. Returns them in
    /// grid order, read from a store of their own so the store under test
    /// starts with no entries, as on the first open of a launch.
    private func seedLibrary() async throws -> [BackgroundImageEntry] {
        for index in 0..<24 {
            _ = try await f.copy(in: f.appWideFolder, width: 200 + index)
        }
        let scout = f.appStore().backgroundImages
        await scout.refresh()
        #expect(scout.entries.count == 24)
        return scout.entries
    }

    /// Takes every library image out of reach of the scan, so a picker opened
    /// now shows the empty state, and `restore` puts them back, folder dates
    /// and all, for the next scan to find.
    private func withhold() throws {
        for folder in [f.libraryFolder, f.appWideFolder] {
            try FileManager.default.moveItem(at: folder, to: held(folder))
        }
    }

    private func restore() throws {
        let fileManager = FileManager.default
        for folder in [f.libraryFolder, f.appWideFolder] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for item in try fileManager.contentsOfDirectory(at: held(folder), includingPropertiesForKeys: nil) {
                let destination = folder.appendingPathComponent(item.lastPathComponent)
                if fileManager.fileExists(atPath: destination.path) { continue }
                try fileManager.moveItem(at: item, to: destination)
            }
        }
    }

    private func held(_ folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + "-held", isDirectory: true)
    }

    /// The first open of a launch: the sheet appears and its scan finds
    /// nothing yet, then a later scan delivers the library and builds the grid.
    private func openBeforeTheLibraryArrives(current: String) async throws -> (NSWindow, NSView) {
        try withhold()
        let model = f.appStore().backgroundImages
        let (window, view) = host(model, current: current)
        await pump(view)
        #expect(model.entries.isEmpty)
        #expect(find(NSScrollView.self, in: view) == nil, "the grid was built before the library arrived")
        try restore()
        await model.refresh()
        #expect(model.entries.count == 24)
        await pump(view)
        return (window, view)
    }

    private func host(_ model: BackgroundImagesModel, current: String?) -> (NSWindow, NSView) {
        let controller = NSHostingController(rootView: BackgroundImagesView(
            model: model, current: current, onPick: { _ in }, onCancel: {}))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 620, height: 460))
        return (window, controller.view)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let found = find(type, in: child) { return found }
        }
        return nil
    }

    /// One real main-queue turn per step, re-running layout after each, as in
    /// `BackgroundSetsScrollStabilityTests`. `turns` is the settle bound,
    /// rechecked by the caller's reads.
    private func pump(_ view: NSView, turns: Int = 20) async {
        view.layoutSubtreeIfNeeded()
        for _ in 0..<turns {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            view.layoutSubtreeIfNeeded()
        }
    }

    private func gridOrigin(in view: NSView) throws -> CGFloat {
        let scroll = try #require(find(NSScrollView.self, in: view), "no grid in My Images")
        let document = scroll.documentView?.frame.height ?? 0
        #expect(document > scroll.contentView.bounds.height, "the library fits the window, so nothing can scroll")
        return scroll.contentView.bounds.origin.y
    }

    @Test func currentImageIsScrolledIntoViewWhenTheLibraryIsAlreadyLoaded() async throws {
        let last = try #require(try await seedLibrary().last)
        let model = f.appStore().backgroundImages
        await model.refresh()
        let (window, view) = host(model, current: last.path)
        await pump(view)
        #expect(try gridOrigin(in: view) > 0, "the current image was not scrolled into view")
        _ = window
    }

    @Test func currentImageIsScrolledIntoViewWhenTheScanFinishesAfterAppear() async throws {
        let last = try #require(try await seedLibrary().last)
        let (window, view) = try await openBeforeTheLibraryArrives(current: last.path)
        #expect(try gridOrigin(in: view) > 0, "the current image was not scrolled into view")
        _ = window
    }

    @Test func currentImageInTheFirstRowLeavesTheGridAtTheTop() async throws {
        let first = try #require(try await seedLibrary().first)
        let (window, view) = try await openBeforeTheLibraryArrives(current: first.path)
        #expect(try gridOrigin(in: view) == 0)
        _ = window
    }

    /// With no image the picker opens on Background Sets; switching to My
    /// Images through the segment, as a click does, must not scroll.
    @Test func noCurrentImageLeavesMyImagesAtTheTop() async throws {
        _ = try await seedLibrary()
        let model = f.appStore().backgroundImages
        await model.refresh()
        let (window, view) = host(model, current: nil)
        await pump(view)
        let segments = try #require(find(NSSegmentedControl.self, in: view), "no tab control")
        #expect(segments.selectedSegment == 1, "the picker did not open on Background Sets")
        segments.selectedSegment = 0
        segments.sendAction(segments.action, to: segments.target)
        await pump(view)
        #expect(try gridOrigin(in: view) == 0)
        _ = window
    }
}
