// AtlasOwnershipExperimentTests.swift

import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

/// #0287's hard gate, run in-process instead of against a live Beta build.
///
/// The issue is gated on settling whether libghostty's glyph atlas
/// (`font.SharedGridSet`) is owned per `ghostty_app_t` (one per
/// `TerminalController`) or per `ghostty_surface_t`. The source trace
/// inferred per-App ownership; the live measurement in
/// `issues/0285/investigation-live.md` §H2 found the 1040K/272K atlas
/// region count scales exactly 3x with *layer* (surface) count, which is
/// consistent with per-surface ownership but was confounded by the
/// measured instance using one App per Tab — app count and surface count
/// moved together, so that data alone can't separate the two hypotheses.
///
/// This harness separates them directly: it creates three real surfaces
/// (via the sandbox-safe in-memory I/O backend — no PTY) on the *same*
/// `TerminalController`/`ghostty_app_t`, sampling this process's own
/// `IOAccelerator` 1040K-region count between each. If a surface added to
/// an already-live App still grows the atlas count, ownership is
/// per-surface (the #0287 refactor would not collapse atlases). If it
/// stays flat, ownership is per-App (the refactor would help).
///
/// **Measured result (3 consecutive runs, byte-for-byte identical):**
/// baseline 0, +2 for the first surface (App + surface both new), then
/// **+3 and +3** for the second and third surfaces added to the *same*
/// already-live controller. Atlas count keeps growing per surface even
/// with the App held constant — this refutes #0287's premise that
/// consolidating Tabs onto a shared `TerminalController` would collapse
/// glyph-atlas memory. It matches the live measurement's 93-regions/31-layers
/// = exactly 3x ratio (`investigation-live.md` §H2), now with the app/surface
/// confound removed. The assertions below encode this as a regression check:
/// if a future libghostty upgrade ever starts sharing atlases per-App, this
/// test will start failing — that would be worth celebrating, and grounds to
/// re-open #0287's refactor, not a bug to silence.
@MainActor
struct AtlasOwnershipExperimentTests {
    /// Counts this process's own `IOAccelerator (graphics)` regions of
    /// exactly 1040K — the grayscale glyph-atlas signature identified in
    /// `investigation-live.md` §H2 (1024x1024x1B + one 16K Metal descriptor
    /// page). Shells out to `/usr/bin/vmmap` against `getpid()`, mirroring
    /// `tools/memsample.sh`'s read-only census approach but self-targeted.
    private func atlas1040KRegionCount() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier)]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return -1 }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        return text
            .split(separator: "\n")
            .filter { $0.contains("IOAccelerator") && $0.contains("[ 1040K") }
            .count
    }

    /// Builds a real, attached, in-memory-backed surface on `controller` and
    /// pumps the main run loop briefly so the async-scheduled first tick
    /// (`TerminalSurfaceCoordinator.scheduleTickIfNeeded` dispatches via
    /// `DispatchQueue.main.async`) actually runs and reaches
    /// `surface.draw()` before the caller samples region counts. Mirrors the
    /// production spawn order in `TerminalHostStore.terminalView(for:windowID:)`:
    /// configuration and controller are set before the view has a window, so
    /// the real surface creation happens in `viewDidMoveToWindow`, not the
    /// property setters.
    /// `AppTerminalView.surface` is package-internal, so attachment success
    /// is observed the same way production code observes it: through
    /// `TerminalSurfaceLifecycleDelegate.terminalDidAttachSurface`, which
    /// `TerminalViewState` (the public, published-property state container)
    /// already implements — `viewState.surface` goes non-nil exactly when
    /// the delegate callback fires.
    private func attachSurface(controller: TerminalController) -> (window: NSWindow, view: AppTerminalView, state: TerminalViewState) {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let view = AppTerminalView(frame: frame)
        let state = TerminalViewState(controller: controller)
        view.delegate = state
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(InMemoryTerminalSession(write: { _ in }, resize: { _ in }))
        )
        view.controller = controller

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = view

        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (window, view, state)
    }

    @Test func secondSurfaceOnSameControllerAtlasDelta() throws {
        let baseline = atlas1040KRegionCount()
        try #require(baseline >= 0, "vmmap failed to run against this process")

        let controller = TerminalController()

        let (windowA, viewA, stateA) = attachSurface(controller: controller)
        try #require(stateA.surface != nil, "surface A did not attach — rebuildIfReady did not fire")
        let afterA = atlas1040KRegionCount()

        let (windowB, viewB, stateB) = attachSurface(controller: controller)
        try #require(stateB.surface != nil, "surface B did not attach — rebuildIfReady did not fire")
        let afterB = atlas1040KRegionCount()

        let (windowC, viewC, stateC) = attachSurface(controller: controller)
        try #require(stateC.surface != nil, "surface C did not attach — rebuildIfReady did not fire")
        let afterC = atlas1040KRegionCount()

        let deltaB = afterB - afterA
        let deltaC = afterC - afterB

        // The load-bearing assertions: a surface added to an *already-live*
        // App (controller held constant across A -> B -> C) still grows the
        // atlas region count. Per-App sharing would predict deltaB == 0 and
        // deltaC == 0. See the type doc comment for the measured numbers and
        // what a future failure here would mean.
        #expect(deltaB > 0, "surface B shared a controller with A; atlas count should still grow if ownership is per-surface (measured +3)")
        #expect(deltaC > 0, "surface C shared a controller with A/B; atlas count should still grow if ownership is per-surface (measured +3)")

        windowA.contentView = nil
        windowB.contentView = nil
        windowC.contentView = nil
        _ = viewA
        _ = viewB
        _ = viewC
    }
}
