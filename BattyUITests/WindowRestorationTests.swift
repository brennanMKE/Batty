// WindowRestorationTests.swift

import XCTest

/// Relaunch-shaped tests for #0238 — window-set restoration and per-window
/// sidebar state.
///
/// **Execution deferred to #0240.** The UI-automation infrastructure on the
/// Mac mini (Accessibility/Automation permission for the XCTRunner) must be
/// confirmed before these can run. The tests are written and compile-verified;
/// #0240 will execute them as part of the full regression pass.
///
/// NOTE: True relaunch persistence (re-present N windows at their frames)
/// requires system window restoration, which macOS only commits on a clean
/// quit (not `app.terminate()` / `SIGKILL`). These tests therefore focus on
/// the per-window sidebar-toggle behavior and that a fresh window gets a new
/// session — not on frame-level restoration, which is verified manually.
nonisolated final class WindowRestorationTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Per-window sidebar state

    /// The sidebar toggle (Cmd-B) affects only the key window, not all windows.
    ///
    /// `app.windows` is z-ordered (frontmost first) in this guest, so
    /// `app.windows.element(boundBy: 0)` is the frontmost window — but a
    /// `boundBy:` index is **not a stable reference to a particular window
    /// across a reorder** (e.g. a click). VM runs 2 and 3
    /// (`20260924-011854-16173`, `20260924-012449-21017`) showed
    /// `app.windows.element(boundBy: 1)`, clicked believing it was the
    /// just-opened Shift-Cmd-N window, actually resolve (via the
    /// "interrupting element" trace `xcodebuild` prints for an obstructed
    /// click) to the *original launch window* (SwiftUI's internal
    /// `...AppWindow-1`, vs. the new window's `...AppWindow-2`) both times —
    /// and after that click raised it to front, `boundBy:0` resolved to the
    /// same `AppWindow-1` too. (This also contradicts this class's and
    /// `#0238.md:62`'s earlier, unrelated claim that `app.windows` is
    /// creation-ordered — it is not that either.)
    ///
    /// Windows are told apart here by their own `identifier` instead,
    /// captured before the second window exists (so there is only one
    /// candidate and no ambiguity), and looked up per check with
    /// `app.windows.matching(NSPredicate(format: "identifier == %@", ...))` —
    /// an exact identifier match. A predicate rather than
    /// `matching(identifier:)` because SwiftUI's auto-generated window
    /// identifier exceeds the 128-character limit XCUITest enforces on
    /// string-identifier queries (observed in VM run `20261006-003321-25688`);
    /// the app assigns no identifier of its own to windows. The new-window
    /// lookup uses plain Swift iteration over `allElementsBoundByIndex`, not
    /// a `.any` descendants query. `BattyUITestHarness.sidebar(in:)`'s own fallback path *does* use
    /// `.descendants(matching: .any)`, but as an exact identifier match, not
    /// a `MATCHES` predicate — the SIGABRT gotcha in `docs/ui-testing-vm.md`'s
    /// "Known limits" is specifically about `MATCHES` evaluated against a
    /// non-string AX value, which does not apply to an exact-identifier
    /// match. Each sidebar element is resolved once, before Cmd-B is
    /// dispatched, while it still exists in its normal (expanded) state, so
    /// `sidebar(in:)`'s existence-based branching picks the specific
    /// `.outlines`/`.collectionViews` query rather than falling through to
    /// that broader fallback; the same live element reference is then polled
    /// after Cmd-B, since XCUIElement queries re-resolve on every property
    /// access.
    ///
    /// `MultiWindowTests.testNewWindowHasIndependentSidebar`'s `boundBy:1`
    /// click has the identical misdirection — filed as **#0438**, not fixed
    /// here. Its passing is not evidence that a `boundBy:` click is safe.
    ///
    /// Separately, **#0437** found that `WindowIDRegistrar`'s registration of
    /// a new window into `AppStateStore.nsWindowMap` is deferred one
    /// main-queue turn and never retried — if the view's `window` is still
    /// nil when that deferred block runs, the window may never be registered
    /// until some later, unrelated `updateNSView` call. `keyWindowRuntime()`
    /// (which `BattyShortcuts` and `RootWindowView`'s toggle handler both
    /// depend on) reads that map, not AX/window-server frontmost status. This
    /// test waits for the new window to become frontmost *by AX*
    /// (`boundBy:0`, once identified) before dispatching Cmd-B, but **that
    /// wait does not close the #0437 race** — a window can be AX-frontmost
    /// while still unregistered in `nsWindowMap`. If #0437 reproduces, Cmd-B
    /// can still be dropped entirely here; that would be a real product bug
    /// to fix in #0437, not something this test's wait papers over.
    @MainActor
    func testToggleSidebarAffectsOnlyKeyWindow() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Measure sidebar width and capture the original window's identity
        // before the second window exists — at this point `firstMatch` is
        // unambiguous, unlike any `boundBy:` index once a second window
        // appears (see class doc comment).
        let sidebar = BattyUITestHarness.sidebar(in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let expandedWidth = sidebar.frame.width
        XCTAssertGreaterThan(expandedWidth, 50, "Sidebar must start expanded (>50 pt)")

        let originalWindowIdentifier = app.windows.firstMatch.identifier
        XCTAssertFalse(originalWindowIdentifier.isEmpty, "Original window must have a stable identifier")

        // Open a second window.
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor({ app.windows.count >= 2 }, timeout: 10),
                      "Second window must appear")

        // Identify the new window by identity, not position: it is whichever
        // window's identifier differs from the one captured above. Plain
        // Swift iteration over already-materialized elements — no
        // NSPredicate, no `.any` descendants query.
        var newWindowIdentifier: String?
        XCTAssertTrue(waitFor({
            for element in app.windows.allElementsBoundByIndex {
                let candidate = element.identifier
                if !candidate.isEmpty && candidate != originalWindowIdentifier {
                    newWindowIdentifier = candidate
                    return true
                }
            }
            return false
        }, timeout: 10), "A window with an identifier different from the original must appear")
        guard let newWindowIdentifier else {
            XCTFail("New window identifier was never captured")
            return
        }

        let originalWindow = app.windows.matching(NSPredicate(format: "identifier == %@", originalWindowIdentifier)).firstMatch
        let newWindow = app.windows.matching(NSPredicate(format: "identifier == %@", newWindowIdentifier)).firstMatch

        // Resolve both windows' sidebar elements now, before Cmd-B, while
        // both still exist in their normal expanded state (see class doc
        // comment) — `newWinSidebar` is reused below as the post-toggle
        // "must collapse" check, and `origSidebar` as the "must remain
        // expanded" check, rather than re-resolving `sidebar(in:)` after the
        // toggle when the new window's sidebar may already be gone from the
        // AX tree.
        let newWinSidebar = BattyUITestHarness.sidebar(in: newWindow)
        XCTAssertTrue(newWinSidebar.waitForExistence(timeout: 10),
                      "New window sidebar must become accessible")
        let origSidebar = BattyUITestHarness.sidebar(in: originalWindow)

        // Wait for the new window to actually become frontmost/key — do not
        // force it with a click (see class doc comment: a click reordered
        // the wrong window in VM runs 2/3). This does not guard against
        // #0437 (see class doc comment); if that race reproduces, Cmd-B may
        // still be dropped below.
        XCTAssertTrue(
            waitFor({ app.windows.element(boundBy: 0).identifier == newWindowIdentifier }, timeout: 10),
            "New window must become frontmost/key before Cmd-B is dispatched"
        )

        // Toggle sidebar. The RootWindowView guard ensures only the key
        // (new) window's sidebar collapses.
        app.typeKey("b", modifierFlags: [.command])

        // Step 1: the new (key) window's sidebar must collapse. `!exists`,
        // not `!isHittable`: hittability depends on whether another window
        // currently occludes this one, which is unrelated to whether the
        // sidebar itself collapsed and was the source of false readings in
        // earlier rounds. Existence and width are both occlusion-independent
        // — either the collapsed NavigationSplitView column drops its
        // content out of the AX tree, or it shrinks; both are covered.
        XCTAssertTrue(
            waitFor({ !newWinSidebar.exists || newWinSidebar.frame.width < expandedWidth / 2 },
                    timeout: 5),
            "Key window's sidebar must collapse after Cmd-B"
        )

        // Step 2: the original (never-toggled) window's sidebar must remain expanded.
        XCTAssertTrue(
            waitFor({ origSidebar.exists && origSidebar.frame.width > expandedWidth / 2 },
                    timeout: 5),
            "Original window's sidebar must remain expanded after Cmd-B in the other window"
        )
    }

    /// Each new window opens with one fresh session.
    @MainActor
    func testNewWindowHasOneFreshSession() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Open a second window.
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor({ app.windows.count >= 2 }, timeout: 10))

        // Each window has its own "Session 1" row.
        let sessionRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session-row.'"))
        XCTAssertTrue(waitFor({ sessionRows.count >= 2 }, timeout: 5),
                      "Each window should show its own initial session row")
    }

}
