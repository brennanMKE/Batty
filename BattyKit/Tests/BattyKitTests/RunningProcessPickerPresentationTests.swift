// RunningProcessPickerPresentationTests.swift

import AppKit
import SwiftUI
import Testing
@testable import BattyKit

/// Pins what a `.popover`'s content reads on its first presentation when the
/// action that opens it also writes the data it shows. With two separate
/// `@State` values (a list and an `isPresented` flag) written in one action,
/// the first presentation is built from the list's previous value: the
/// "Pick a Running Process…" picker opened empty (#0626). Carrying the list in
/// the `.popover(item:)` value makes each open present exactly the list its own
/// action fetched.
///
/// The probes use the production anchor (`Menu` with `.menuStyle(.button)`).
/// A popover needs an on-screen anchor, so each window is ordered front, and is
/// closed only after its popover was dismissed by state: closing a window while
/// its popover is up crashes.
@MainActor
struct RunningProcessPickerPresentationTests {

    /// Plain (non-observed) sink the probes report into, and the handles the
    /// test drives them through, so the test never synthesizes clicks.
    final class Recorder {
        var appearedCounts: [Int] = []
        var disappearCount = 0
        var open: ((Int) -> Void)?
        var close: (() -> Void)?
    }

    private static func fixtures(_ count: Int) -> [ProcessInspector.RunningProcess] {
        (0..<count).map { ProcessInspector.RunningProcess(id: pid_t(1000 + $0), name: "fixture-\($0)") }
    }

    /// Stands in for `RunningProcessPickerView`: it is handed the list as a
    /// `let` when the popover content is built, and reports what it was given.
    private struct PickerContent: View {
        let processes: [ProcessInspector.RunningProcess]
        let recorder: Recorder

        var body: some View {
            Text("\(processes.count)")
                .onAppear { recorder.appearedCounts.append(processes.count) }
                .onDisappear { recorder.disappearCount += 1 }
        }
    }

    private struct SeparateStateProbe: View {
        let recorder: Recorder
        @State private var cache: [ProcessInspector.RunningProcess] = []
        @State private var show = false

        var body: some View {
            Menu("Choose") { Button("Pick") {} }
                .menuStyle(.button)
                .fixedSize()
                .popover(isPresented: $show) {
                    PickerContent(processes: cache, recorder: recorder)
                }
                .onAppear {
                    recorder.open = { count in
                        cache = RunningProcessPickerPresentationTests.fixtures(count)
                        show = true
                    }
                    recorder.close = { show = false }
                }
        }
    }

    private struct RequestProbe: View {
        let recorder: Recorder
        @State private var request: RunningProcessPickerRequest?

        var body: some View {
            Menu("Choose") { Button("Pick") {} }
                .menuStyle(.button)
                .fixedSize()
                .popover(item: $request) { request in
                    PickerContent(processes: request.processes, recorder: recorder)
                }
                .onAppear {
                    recorder.open = { count in
                        request = RunningProcessPickerRequest(
                            processes: RunningProcessPickerPresentationTests.fixtures(count)
                        )
                    }
                    recorder.close = { request = nil }
                }
        }
    }

    private func host<Content: View>(_ content: Content) -> NSWindow {
        _ = NSApplication.shared
        let size = CGSize(width: 320, height: 200)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFrontRegardless()
        return window
    }

    /// The turn-bounded main-queue hop of `PaneViewRenderTests.pump`: the
    /// condition is rechecked after every real turn; `maxTurns` is a hang-guard.
    /// A popover's dismissal lands only when its close animation completes,
    /// several thousand turns later on the host, hence the larger bound.
    private func pump(
        _ window: NSWindow,
        until condition: () -> Bool,
        maxTurns: Int = 50_000,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<maxTurns {
            if condition() { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            window.contentView?.layoutSubtreeIfNeeded()
        }
        if !condition() {
            Issue.record("Timed out after \(maxTurns) main-queue turns", sourceLocation: sourceLocation)
        }
    }

    /// Opens with `firstCount` items, dismisses, opens with `secondCount`, and
    /// returns the counts the popover content saw on each appearance.
    private func presentTwice<Content: View>(
        _ probe: Content,
        recorder: Recorder,
        firstCount: Int,
        secondCount: Int
    ) async -> [Int] {
        let window = host(probe)
        defer { window.close() }
        await pump(window, until: { recorder.open != nil })
        guard let open = recorder.open, let close = recorder.close else { return [] }

        open(firstCount)
        await pump(window, until: { recorder.appearedCounts.count == 1 })
        close()
        await pump(window, until: { recorder.disappearCount == 1 })

        open(secondCount)
        await pump(window, until: { recorder.appearedCounts.count == 2 })
        close()
        await pump(window, until: { recorder.disappearCount == 2 })
        return recorder.appearedCounts
    }

    @Test func separateCacheAndIsPresentedShowsAnEmptyListOnFirstOpen() async {
        let recorder = Recorder()
        let counts = await presentTwice(
            SeparateStateProbe(recorder: recorder),
            recorder: recorder,
            firstCount: 3,
            secondCount: 6
        )
        #expect(counts == [0, 6], "the action wrote 3 items; the first presentation read the previous, empty list")
    }

    @Test func requestCarriesItsListToTheFirstOpen() async {
        let recorder = Recorder()
        let counts = await presentTwice(
            RequestProbe(recorder: recorder),
            recorder: recorder,
            firstCount: 3,
            secondCount: 5
        )
        #expect(counts == [3, 5])
    }
}
