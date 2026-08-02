// TerminalHostStoreOcclusionTests.swift

import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

/// Coverage for #0288: `TerminalHostStore` signalling surface occlusion to
/// libghostty via `AppTerminalView.setSurfaceVisible(_:)`.
///
/// `AppTerminalView` (the upstream `libghostty-spm` wrapper) exposes no
/// getter for the display-visible flag it forwards into
/// `ghostty_surface_set_occlusion` — `setSurfaceVisible(_:)` is write-only.
/// These tests therefore verify the state machine Batty owns: the per-window
/// occlusion bookkeeping in `TerminalHostStore`, and — the property that
/// matters most for correctness — that window-level occlusion never flips
/// `isHidden`/`frame`, which stay driven purely by Tab/Pane placement. That
/// separation is what lets a background window come back without un-hiding
/// tabs that were already hidden for unrelated (pane-hide, inactive-tab)
/// reasons. Whether `setSurfaceVisible` actually pauses/resumes rendering is
/// verified manually against a live process (see the issue's Verification
/// section) — not observable headlessly through this wrapper's API.
@MainActor
struct TerminalHostStoreOcclusionTests {

    // MARK: - Default state

    @Test func windowOcclusionDefaultsToVisibleForAnUnobservedWindow() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        #expect(store.isWindowOcclusionVisible(forWindowID: windowID))
    }

    // MARK: - setWindowOcclusionVisible bookkeeping

    @Test func setWindowOcclusionVisibleUpdatesTrackedState() {
        let store = TerminalHostStore()
        let windowID = WindowID()

        store.setWindowOcclusionVisible(false, forWindowID: windowID)
        #expect(store.isWindowOcclusionVisible(forWindowID: windowID) == false)

        store.setWindowOcclusionVisible(true, forWindowID: windowID)
        #expect(store.isWindowOcclusionVisible(forWindowID: windowID))
    }

    @Test func setWindowOcclusionVisibleScopedPerWindow() {
        let store = TerminalHostStore()
        let window1 = WindowID()
        let window2 = WindowID()

        store.setWindowOcclusionVisible(false, forWindowID: window1)

        #expect(store.isWindowOcclusionVisible(forWindowID: window1) == false)
        // A different window's occlusion is untouched — mirrors the
        // per-window scoping that already governs placements (Amendment 3,
        // `view-hierarchy.md` §4).
        #expect(store.isWindowOcclusionVisible(forWindowID: window2))
    }

    @Test func releaseHostClearsTrackedOcclusionState() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()

        _ = store.terminalView(for: tab, windowID: windowID)
        store.setWindowOcclusionVisible(false, forWindowID: windowID)
        #expect(store.isWindowOcclusionVisible(forWindowID: windowID) == false)

        store.releaseTerminalView(forTabID: tab.id)
        store.releaseHost(forWindowID: windowID)

        // `releaseHost` removes the `windowOcclusionVisible` entry along
        // with the host itself — dictionary hygiene, not a correctness
        // requirement a real window could ever exercise: `WindowID()`'s
        // default init always mints a fresh UUID, so no *other* window can
        // ever collide with a released one's id. What this confirms is that
        // a query against an already-released windowID (a stray diagnostic
        // read, or a test reusing the id on purpose, as here) reads the
        // documented default (`true`) rather than a stale tracked value
        // left behind by teardown.
        #expect(store.isWindowOcclusionVisible(forWindowID: windowID))
    }

    // MARK: - Occlusion is independent of isHidden/frame

    /// The central design invariant: window occlusion must NEVER flip
    /// `isHidden` or `frame` — those stay owned entirely by Tab/Pane
    /// placement (`setPlacement`/`updatePlacements`). If occlusion also
    /// detached/hid the view, a window coming back would need to
    /// re-establish placement from scratch instead of just resuming
    /// rendering, and a hidden background tab would incorrectly reappear
    /// when its (fully occluded) window regains focus.
    @Test func windowOcclusionDoesNotAffectIsHiddenOrFrameViaSetPlacement() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        let view = store.terminalView(for: tab, windowID: windowID)

        store.setPlacement(
            TerminalHostStore.Placement(frame: NSRect(x: 0, y: 0, width: 100, height: 100), isVisible: true),
            forTabID: tab.id
        )
        #expect(!view.isHidden)
        let frameBeforeOcclusion = view.frame

        store.setWindowOcclusionVisible(false, forWindowID: windowID)
        #expect(!view.isHidden)
        #expect(view.frame == frameBeforeOcclusion)

        store.setWindowOcclusionVisible(true, forWindowID: windowID)
        #expect(!view.isHidden)
        #expect(view.frame == frameBeforeOcclusion)
    }

    @Test func windowOcclusionDoesNotAffectIsHiddenViaUpdatePlacements() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        let view = store.terminalView(for: tab, windowID: windowID)

        store.updatePlacements([
            tab.id: TerminalHostStore.Placement(
                frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                isVisible: true
            )
        ], forWindowID: windowID)
        #expect(!view.isHidden)

        store.setWindowOcclusionVisible(false, forWindowID: windowID)
        #expect(!view.isHidden)

        // Re-applying placements while the window is occluded still keeps
        // the view attached and unhidden — occlusion is orthogonal.
        store.updatePlacements([
            tab.id: TerminalHostStore.Placement(
                frame: NSRect(x: 10, y: 10, width: 100, height: 100),
                isVisible: true
            )
        ], forWindowID: windowID)
        #expect(!view.isHidden)
        #expect(view.frame == NSRect(x: 10, y: 10, width: 100, height: 100))
    }

    /// A Tab already hidden by its own placement (inactive tab, hidden pane)
    /// stays hidden across a window occlusion cycle — the window coming back
    /// must not un-hide it.
    @Test func hiddenTabStaysHiddenAcrossWindowOcclusionCycle() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        let view = store.terminalView(for: tab, windowID: windowID)

        store.setPlacement(
            TerminalHostStore.Placement(frame: .zero, isVisible: false),
            forTabID: tab.id
        )
        #expect(view.isHidden)

        store.setWindowOcclusionVisible(false, forWindowID: windowID)
        store.setWindowOcclusionVisible(true, forWindowID: windowID)

        #expect(view.isHidden)
    }

    // MARK: - Window-scoped: one window's occlusion never touches another's views

    @Test func setWindowOcclusionVisibleDoesNotCrossBetweenWindows() {
        let store = TerminalHostStore()
        let window1 = WindowID()
        let window2 = WindowID()
        let tab1 = TabRuntime()
        let tab2 = TabRuntime()
        let view1 = store.terminalView(for: tab1, windowID: window1)
        let view2 = store.terminalView(for: tab2, windowID: window2)

        store.setPlacement(
            TerminalHostStore.Placement(frame: NSRect(x: 0, y: 0, width: 50, height: 50), isVisible: true),
            forTabID: tab1.id
        )
        store.setPlacement(
            TerminalHostStore.Placement(frame: NSRect(x: 0, y: 0, width: 50, height: 50), isVisible: true),
            forTabID: tab2.id
        )
        #expect(!view1.isHidden)
        #expect(!view2.isHidden)

        store.setWindowOcclusionVisible(false, forWindowID: window1)

        // Neither view's isHidden/frame changes — occlusion never touches
        // those — but critically window2's tracked occlusion state itself
        // is untouched by window1's transition.
        #expect(!view1.isHidden)
        #expect(!view2.isHidden)
        #expect(store.isWindowOcclusionVisible(forWindowID: window1) == false)
        #expect(store.isWindowOcclusionVisible(forWindowID: window2))
    }

    // MARK: - effectiveSurfaceVisible algebra

    /// The four combinations of the two inputs every occlusion call site
    /// (and the background ticker) derives its answer from. Extracted so a
    /// future change to one call site can't silently diverge from the
    /// others — see the type's doc comment.
    @Test func effectiveSurfaceVisibleTrueOnlyWhenBothPlacementAndWindowAreVisible() {
        #expect(TerminalHostStore.effectiveSurfaceVisible(placementVisible: true, windowVisible: true) == true)
        #expect(TerminalHostStore.effectiveSurfaceVisible(placementVisible: true, windowVisible: false) == false)
        #expect(TerminalHostStore.effectiveSurfaceVisible(placementVisible: false, windowVisible: true) == false)
        #expect(TerminalHostStore.effectiveSurfaceVisible(placementVisible: false, windowVisible: false) == false)
    }

    /// Regression test for the `placements`-drift hazard fixed by deriving
    /// visibility from `!view.isHidden` rather than the `placements` cache:
    /// a tab dropped entirely from a *subsequent* `updatePlacements` map
    /// (as opposed to explicitly re-placed with `isVisible: false`) hides
    /// its view immediately, but the `placements` dictionary entry for it
    /// is left untouched — stale at its last-applied `isVisible == true`.
    /// A later `setWindowOcclusionVisible(true, ...)` re-deriving from that
    /// stale entry would incorrectly resume the view; deriving from
    /// `!view.isHidden` (ground truth, always current) does not.
    @Test func windowOcclusionReturningDoesNotResumeATabDroppedFromAPlacementsMapWithoutAnExplicitHide() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        let view = store.terminalView(for: tab, windowID: windowID)

        store.updatePlacements([
            tab.id: TerminalHostStore.Placement(frame: NSRect(x: 0, y: 0, width: 10, height: 10), isVisible: true)
        ], forWindowID: windowID)
        #expect(!view.isHidden)

        // Drop the tab from the map entirely — the view is hidden, but the
        // `placements` cache entry is untouched and stays stale at true.
        store.updatePlacements([:], forWindowID: windowID)
        #expect(view.isHidden)
        #expect(
            store.placement(forTabID: tab.id)?.isVisible == true,
            "sanity check: the cached placement is intentionally stale here — this is what the fix must not trust"
        )

        store.setWindowOcclusionVisible(false, forWindowID: windowID)
        store.setWindowOcclusionVisible(true, forWindowID: windowID)

        // The tab must still be tracked as occluded — a stale `placements`
        // entry must never make window occlusion returning treat a
        // genuinely hidden view as visible.
        #expect(store.occludedTickTargets() == [tab.id])
    }

    // MARK: - Occluded-surface tick set (#0288)

    @Test func occludedTickTargetsIsEmptyByDefault() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        _ = store.terminalView(for: tab, windowID: windowID)

        #expect(store.occludedTickTargets().isEmpty)
    }

    /// Regression test for the round-3 review finding: a Tab whose
    /// libghostty surface hasn't attached yet (no real `NSWindow` in unit
    /// tests, or — in production — created directly into an already-occluded
    /// window) must still be tracked once it's occluded by placement. An
    /// earlier `hasLiveSurface` filter excluded these and went stale the
    /// moment a surface attached after the tick set was last computed;
    /// dropping the filter means occlusion alone decides tick-set membership.
    @Test func occludedTickTargetsIncludesAHiddenTabEvenWithoutALiveSurface() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        _ = store.terminalView(for: tab, windowID: windowID)

        store.setPlacement(
            TerminalHostStore.Placement(frame: .zero, isVisible: false),
            forTabID: tab.id
        )

        #expect(store.occludedTickTargets() == [tab.id])
    }

    @Test func occludedTickTargetsExcludesAVisibleTab() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        _ = store.terminalView(for: tab, windowID: windowID)

        store.setPlacement(
            TerminalHostStore.Placement(frame: NSRect(x: 0, y: 0, width: 10, height: 10), isVisible: true),
            forTabID: tab.id
        )

        #expect(store.occludedTickTargets().isEmpty)
    }

    /// A Tab that's visible by its own placement but sits in a fully
    /// occluded window must still be ticked — window occlusion, not just
    /// Tab/Pane hide, is exactly the case #0288's parked round exists for.
    @Test func occludedTickTargetsIncludesATabHiddenOnlyByWindowOcclusion() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        _ = store.terminalView(for: tab, windowID: windowID)
        store.setPlacement(
            TerminalHostStore.Placement(frame: NSRect(x: 0, y: 0, width: 10, height: 10), isVisible: true),
            forTabID: tab.id
        )
        #expect(store.occludedTickTargets().isEmpty)

        store.setWindowOcclusionVisible(false, forWindowID: windowID)

        #expect(store.occludedTickTargets() == [tab.id])
    }

    /// A Tab created while its window is already occluded is tracked from
    /// its very first placement update — the sequence the round-3 review
    /// flagged as reproducing the staleness bug (occlude the window, then
    /// mount a Tab into it, rather than the other order).
    @Test func occludedTickTargetsIncludesATabCreatedIntoAnAlreadyOccludedWindow() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        store.setWindowOcclusionVisible(false, forWindowID: windowID)

        let tab = TabRuntime()
        _ = store.terminalView(for: tab, windowID: windowID)
        store.setPlacement(
            TerminalHostStore.Placement(frame: NSRect(x: 0, y: 0, width: 10, height: 10), isVisible: true),
            forTabID: tab.id
        )

        #expect(store.occludedTickTargets() == [tab.id])
    }

    @Test func occludedTickTargetsUpdatesAsVisibilityChanges() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        _ = store.terminalView(for: tab, windowID: windowID)

        store.setPlacement(
            TerminalHostStore.Placement(frame: .zero, isVisible: false),
            forTabID: tab.id
        )
        #expect(store.occludedTickTargets() == [tab.id])

        store.setPlacement(
            TerminalHostStore.Placement(frame: NSRect(x: 0, y: 0, width: 10, height: 10), isVisible: true),
            forTabID: tab.id
        )
        #expect(store.occludedTickTargets().isEmpty)

        store.setPlacement(
            TerminalHostStore.Placement(frame: .zero, isVisible: false),
            forTabID: tab.id
        )
        #expect(store.occludedTickTargets() == [tab.id])
    }

    /// Only the tabs that are actually occluded end up tracked — a mixed
    /// window (one visible tab, one hidden tab) never ticks the visible one.
    @Test func occludedTickTargetsOnlyIncludesTheHiddenSiblingInAMixedWindow() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let visibleTab = TabRuntime()
        let hiddenTab = TabRuntime()
        _ = store.terminalView(for: visibleTab, windowID: windowID)
        _ = store.terminalView(for: hiddenTab, windowID: windowID)

        store.updatePlacements([
            visibleTab.id: TerminalHostStore.Placement(
                frame: NSRect(x: 0, y: 0, width: 10, height: 10), isVisible: true
            ),
            hiddenTab.id: TerminalHostStore.Placement(frame: .zero, isVisible: false)
        ], forWindowID: windowID)

        #expect(store.occludedTickTargets() == [hiddenTab.id])
    }

    /// Releasing a tracked tab's terminal view drops it from the tick set
    /// immediately — a closed Tab must never keep being ticked.
    @Test func occludedTickTargetsDropsATabWhenItsTerminalViewIsReleased() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let tab = TabRuntime()
        _ = store.terminalView(for: tab, windowID: windowID)
        store.setPlacement(
            TerminalHostStore.Placement(frame: .zero, isVisible: false),
            forTabID: tab.id
        )
        #expect(store.occludedTickTargets() == [tab.id])

        store.releaseTerminalView(forTabID: tab.id)

        #expect(store.occludedTickTargets().isEmpty)
    }

    /// `fireOccludedTickForTesting()` fires ``OccludedSurfaceTicker/onTick``
    /// for exactly the currently tracked targets, and for no one else.
    /// Production wiring resolves each id's real `TerminalController` and
    /// calls `tick()`, which has no effect observable from outside the
    /// package for a surfaceless controller — so this test replaces the
    /// handler via ``TerminalHostStore/setOccludedTickHandlerForTesting(_:)``
    /// to record which ids actually got ticked, rather than only checking
    /// that firing doesn't crash.
    @Test func fireOccludedTickForTestingTicksExactlyTheTrackedTargets() {
        let store = TerminalHostStore()
        let windowID = WindowID()
        let hiddenTab = TabRuntime()
        let visibleTab = TabRuntime()
        _ = store.terminalView(for: hiddenTab, windowID: windowID)
        _ = store.terminalView(for: visibleTab, windowID: windowID)
        store.updatePlacements([
            hiddenTab.id: TerminalHostStore.Placement(frame: .zero, isVisible: false),
            visibleTab.id: TerminalHostStore.Placement(
                frame: NSRect(x: 0, y: 0, width: 10, height: 10), isVisible: true
            )
        ], forWindowID: windowID)
        #expect(store.occludedTickTargets() == [hiddenTab.id])

        var ticked: [UUID] = []
        store.setOccludedTickHandlerForTesting { ticked.append($0) }

        store.fireOccludedTickForTesting()

        #expect(ticked == [hiddenTab.id])

        store.fireOccludedTickForTesting()

        #expect(ticked == [hiddenTab.id, hiddenTab.id])
    }

    // MARK: - setSurfaceVisible call sequence (#0288)

    /// Regression test for the round-3 review finding: mutating every
    /// `view.setSurfaceVisible(...)` call site into `_ = (...)` — deleting
    /// the entire fix while keeping the expression, and therefore keeping
    /// every other test in this file green — must make this test fail.
    /// `AppTerminalView.setSurfaceVisible(_:)` is `open`, so
    /// `RecordingTerminalView` overrides it and `TerminalHostStore.makeTerminalView`
    /// substitutes it in, letting the test assert the exact sequence of
    /// booleans reaching the view instead of only the derived
    /// `isHidden`/`windowOcclusionVisible` bookkeeping the rest of this file
    /// covers.
    @Test func setPlacementCallsSetSurfaceVisibleWithTheEffectiveVisibility() {
        let store = TerminalHostStore()
        store.makeTerminalView = { RecordingTerminalView(frame: .zero) }
        let windowID = WindowID()
        let tab = TabRuntime()
        guard let view = store.terminalView(for: tab, windowID: windowID) as? RecordingTerminalView else {
            Issue.record("expected RecordingTerminalView from the injected makeTerminalView seam")
            return
        }

        store.setPlacement(
            TerminalHostStore.Placement(frame: NSRect(x: 0, y: 0, width: 10, height: 10), isVisible: true),
            forTabID: tab.id
        )
        #expect(view.recordedVisibility == [true])

        store.setPlacement(
            TerminalHostStore.Placement(frame: .zero, isVisible: false),
            forTabID: tab.id
        )
        #expect(view.recordedVisibility == [true, false])
    }

    @Test func updatePlacementsCallsSetSurfaceVisibleWithTheEffectiveVisibility() {
        let store = TerminalHostStore()
        store.makeTerminalView = { RecordingTerminalView(frame: .zero) }
        let windowID = WindowID()
        let tab = TabRuntime()
        guard let view = store.terminalView(for: tab, windowID: windowID) as? RecordingTerminalView else {
            Issue.record("expected RecordingTerminalView from the injected makeTerminalView seam")
            return
        }

        store.updatePlacements([
            tab.id: TerminalHostStore.Placement(frame: NSRect(x: 0, y: 0, width: 10, height: 10), isVisible: true)
        ], forWindowID: windowID)
        #expect(view.recordedVisibility == [true])

        store.updatePlacements([:], forWindowID: windowID)
        #expect(view.recordedVisibility == [true, false])
    }

    /// The window-occlusion path drives the same `setSurfaceVisible` call —
    /// covering it separately guards against a fix that wires placement
    /// changes but not `setWindowOcclusionVisible`.
    @Test func setWindowOcclusionVisibleCallsSetSurfaceVisibleWithTheEffectiveVisibility() {
        let store = TerminalHostStore()
        store.makeTerminalView = { RecordingTerminalView(frame: .zero) }
        let windowID = WindowID()
        let tab = TabRuntime()
        guard let view = store.terminalView(for: tab, windowID: windowID) as? RecordingTerminalView else {
            Issue.record("expected RecordingTerminalView from the injected makeTerminalView seam")
            return
        }
        store.setPlacement(
            TerminalHostStore.Placement(frame: NSRect(x: 0, y: 0, width: 10, height: 10), isVisible: true),
            forTabID: tab.id
        )
        #expect(view.recordedVisibility == [true])

        store.setWindowOcclusionVisible(false, forWindowID: windowID)
        #expect(view.recordedVisibility == [true, false])

        store.setWindowOcclusionVisible(true, forWindowID: windowID)
        #expect(view.recordedVisibility == [true, false, true])
    }
}

/// `AppTerminalView.setSurfaceVisible(_:)` (upstream `libghostty-spm`) is
/// write-only — no getter exists — so tests that need to assert the exact
/// call sequence reaching it substitute this recording subclass via
/// ``TerminalHostStore/makeTerminalView``. `setSurfaceVisible` is `open`,
/// which is what makes this possible without modifying the upstream package.
@MainActor
private final class RecordingTerminalView: AppTerminalView {
    private(set) var recordedVisibility: [Bool] = []

    override func setSurfaceVisible(_ visible: Bool) {
        recordedVisibility.append(visible)
        super.setSurfaceVisible(visible)
    }
}

/// Coverage for the `NSWindowDelegate` entry point that drives window-level
/// occlusion: `WindowDelegate.windowDidChangeOcclusionState(_:)` in
/// `RootWindowView.swift`.
@MainActor
struct WindowDelegateOcclusionTests {

    /// A freshly constructed, never-ordered-front `NSWindow` reports an
    /// occlusion state that does not include `.visible` — it has never been
    /// on screen. This exercises the real `NSWindow.occlusionState` API
    /// rather than a fake, so the assertion doubles as a check that the
    /// delegate reads the flag `WindowDidChangeOcclusionStateNotification`
    /// callers actually observe.
    @Test func windowDidChangeOcclusionStateReflectsAnOffScreenWindow() {
        let windowID = WindowID()
        let delegate = WindowDelegate(windowID: windowID, store: AppStateStore())
        let window = NSWindow()

        // Baseline: unobserved windows read as visible.
        #expect(TerminalHostStore.shared.isWindowOcclusionVisible(forWindowID: windowID))

        delegate.windowDidChangeOcclusionState(
            Notification(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        )

        #expect(
            TerminalHostStore.shared.isWindowOcclusionVisible(forWindowID: windowID)
                == window.occlusionState.contains(.visible)
        )
        #expect(TerminalHostStore.shared.isWindowOcclusionVisible(forWindowID: windowID) == false)

        // Clean up the shared singleton so this test doesn't leak state into
        // any other test that happens to reuse this windowID.
        TerminalHostStore.shared.setWindowOcclusionVisible(true, forWindowID: windowID)
    }

    /// A notification whose `object` isn't an `NSWindow` is ignored rather
    /// than crashing or writing bogus state.
    @Test func windowDidChangeOcclusionStateIgnoresNonWindowObject() {
        let windowID = WindowID()
        let delegate = WindowDelegate(windowID: windowID, store: AppStateStore())

        delegate.windowDidChangeOcclusionState(
            Notification(name: NSWindow.didChangeOcclusionStateNotification, object: "not a window")
        )

        #expect(TerminalHostStore.shared.isWindowOcclusionVisible(forWindowID: windowID))
    }
}
