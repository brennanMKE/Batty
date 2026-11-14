// BackgroundSetsScrollStabilityTests.swift

import AppKit
import SwiftUI
import Testing
@testable import BattyKit

/// Hosts the real `BackgroundSetsView` with four sets of eight images, some
/// downloaded so their cells carry an "Available offline" line and the rows
/// above the bottom are uneven, scrolls to the bottom, re-renders the view, and
/// checks the visible rows stay where they were.
@MainActor
struct BackgroundSetsScrollStabilityTests {
    private let f: ProjectBackgroundFixture
    private let store: AppStateStore
    private var hosted: HostedBackgroundsModel { store.backgroundImages.hosted }
    private let catalogURL = BackgroundCatalog.builtInURL
    private static let sets = ["future-cities", "cool-vehicles", "beautiful-landscapes", "deep-space"]

    init() throws {
        f = try ProjectBackgroundFixture()
        store = f.appStore()
    }

    private func url(_ name: String) -> URL {
        URL(string: "https://batty.sstools.co/backgrounds/\(name)")!
    }

    private func serveCatalog() throws {
        var sets: [[String: Any]] = []
        for set in Self.sets {
            var images: [[String: Any]] = []
            for index in 1...8 {
                let id = "\(set)-0\(index)"
                fetcherSet(try BackgroundTestImage.encoded(width: 96, height: 60), for: url("\(id).png"))
                fetcherSet(try BackgroundTestImage.encoded(width: 48, height: 30), for: url("\(id)-thumb.png"))
                images.append(["title": "Picture \(id)", "full": "\(id).png", "thumbnail": "\(id)-thumb.png"])
            }
            sets.append(["name": set, "images": images])
        }
        f.catalogFetcher.set(.ok(CatalogJSON.data(["sets": sets]), etag: "\"c1\""), for: catalogURL)
    }

    private func fetcherSet(_ data: Data, for url: URL) {
        f.catalogFetcher.set(.ok(data), for: url)
    }

    private func image(_ id: String) throws -> HostedBackgroundImage {
        try #require(hosted.catalogs.first?.catalog?.allImages.first { $0.full == url("\(id).png") })
    }

    /// Downloads 01, 02 and 05 of every set but the last, so the rows above
    /// the bottom differ in height and the bottom set's rows don't.
    private func downloadUnevenPattern() async throws {
        for set in Self.sets.dropLast() {
            for index in [1, 2, 5] {
                let path = await hosted.select(try image("\(set)-0\(index)")).value
                #expect(path != nil, "\(set)-0\(index) did not download")
            }
        }
        await hosted.reconcileAvailability()
        #expect(hosted.available.count == 9)
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }

    /// One real main-queue turn per step, re-running layout after each, so
    /// SwiftUI's lazy grids build the rows the new scroll position shows.
    /// `turns` is the settle bound, rechecked by the caller's reads.
    private func pump(_ view: NSView, turns: Int = 20) async {
        view.layoutSubtreeIfNeeded()
        for _ in 0..<turns {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            view.layoutSubtreeIfNeeded()
        }
    }

    /// How far the viewport's bottom is above the content's bottom. Zero when
    /// scrolled to the bottom; a re-estimate above the viewport that grows
    /// the content leaves the clip origin where it was and raises this.
    private func gapBelowViewport(_ scroll: NSScrollView) -> CGFloat {
        let document = scroll.documentView?.frame.height ?? 0
        let clip = scroll.contentView.bounds
        return document - clip.maxY
    }

    /// 120 pt at a time, as a scroll wheel would, so each set's grid is built
    /// on the way down and left behind above the viewport.
    private func scrollToBottom(_ scroll: NSScrollView, in view: NSView) async {
        for _ in 0..<40 {
            let document = scroll.documentView?.frame.height ?? 0
            let top = min(max(0, document - scroll.contentView.bounds.height), scroll.contentView.bounds.origin.y + 120)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: top))
            scroll.reflectScrolledClipView(scroll.contentView)
            await pump(view)
            if abs(gapBelowViewport(scroll)) < 0.5 { return }
        }
    }

    private struct Measure: CustomStringConvertible {
        let origin: CGFloat
        let document: CGFloat
        let gap: CGFloat
        init(_ scroll: NSScrollView, gap: CGFloat) {
            origin = scroll.contentView.bounds.origin.y
            document = scroll.documentView?.frame.height ?? 0
            self.gap = gap
        }
        var description: String { "origin \(origin), document \(document), gap \(gap)" }
    }

    /// What `windowDidBecomeKey` runs, with a check due and held in flight the
    /// way a slow network holds it, measured mid-check and after it.
    @Test func windowBecomingKeyAtTheBottomKeepsTheVisibleRowsStill() async throws {
        try serveCatalog()
        await hosted.browseAppeared()
        try await downloadUnevenPattern()

        let controller = NSHostingController(rootView: BackgroundSetsView(model: store.backgroundImages, onPick: nil))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 432),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 760, height: 432))
        let view = controller.view
        await pump(view)
        let scroll = try #require(scrollView(in: view), "no scroll view in Background Sets")
        await scrollToBottom(scroll, in: view)
        let before = Measure(scroll, gap: gapBelowViewport(scroll))
        #expect(before.origin > 0, "the content fits the window, so nothing scrolled")

        store.backgroundImages.refreshUses()
        await pump(view)
        let afterUses = Measure(scroll, gap: gapBelowViewport(scroll))

        _ = await f.clock.advance(by: .seconds(HostedBackgroundsModel.refreshInterval + 60))
        f.catalogFetcher.set(.notModified, for: catalogURL)
        f.catalogFetcher.hold(catalogURL)
        let requests = f.catalogFetcher.requests.count
        let check = Task { await hosted.windowBecameKey() }
        #expect(await f.catalogFetcher.waitForRequests(requests + 1), "no catalog check was due")
        #expect(hosted.isCheckingAny)
        await pump(view)
        let midCheck = Measure(scroll, gap: gapBelowViewport(scroll))
        f.catalogFetcher.release(catalogURL)
        await check.value
        await pump(view)
        let afterCheck = Measure(scroll, gap: gapBelowViewport(scroll))

        let log = "before \(before); uses \(afterUses); mid-check \(midCheck); after \(afterCheck)"
        for step in [afterUses, midCheck, afterCheck] {
            #expect(abs(step.gap - before.gap) < 1 && abs(step.origin - before.origin) < 1, "the visible rows moved: \(log)")
        }
        _ = window
    }

    @Test func reRenderAtTheBottomKeepsTheVisibleRowsStill() async throws {
        try serveCatalog()
        await hosted.browseAppeared()
        try await downloadUnevenPattern()

        let controller = NSHostingController(rootView: BackgroundSetsView(model: store.backgroundImages, onPick: nil))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 432),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 760, height: 432))
        let view = controller.view
        await pump(view)
        let scroll = try #require(scrollView(in: view), "no scroll view in Background Sets")
        await scrollToBottom(scroll, in: view)

        let originBefore = scroll.contentView.bounds.origin.y
        let documentBefore = scroll.documentView?.frame.height ?? 0
        let gapBefore = gapBelowViewport(scroll)
        #expect(originBefore > 0, "the content fits the window, so nothing scrolled")

        f.catalogFetcher.set(.notModified, for: catalogURL)
        await hosted.refresh(catalogURL)
        await pump(view)

        let originAfter = scroll.contentView.bounds.origin.y
        let documentAfter = scroll.documentView?.frame.height ?? 0
        let gapAfter = gapBelowViewport(scroll)
        let measure = "origin \(originBefore) -> \(originAfter), document \(documentBefore) -> \(documentAfter), gap \(gapBefore) -> \(gapAfter)"
        #expect(abs(gapAfter - gapBefore) < 1, "the visible rows moved: \(measure)")
        #expect(abs(documentAfter - documentBefore) < 1, "the content height changed: \(measure)")
    }
}
