// MultiWindowCLITests.swift

import XCTest

/// Multi-window behaviors that need the window a Session lives in, which only
/// `batty list --json` reports (#0240): per-window Session lists and
/// selection, a Bell Feed jump that crosses windows, and closing one window.
///
/// Windows are told apart by their accessibility identifier, never by a
/// `boundBy:` index (see `WindowRestorationTests`).
nonisolated final class MultiWindowCLITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Helpers

    /// One window's slice of `list --json`.
    private struct WindowListing {
        let selectedSessionID: UUID?
        let sessionIDs: [UUID]
    }

    private func windowListings() -> [WindowListing]? {
        let result = BattyCLI.run(["list", "--json"])
        guard result.status == 0,
              let object = CLITopology.jsonObject(in: result.output),
              let windows = object["windows"] as? [[String: Any]]
        else { return nil }
        return windows.map { window in
            let sessions = window["sessions"] as? [[String: Any]] ?? []
            return WindowListing(
                selectedSessionID: (window["selectedSessionID"] as? String).flatMap(UUID.init(uuidString:)),
                sessionIDs: sessions.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) }
            )
        }
    }

    private func waitForWindowListings(_ predicate: @escaping ([WindowListing]) -> Bool) -> [WindowListing]? {
        var match: [WindowListing]?
        BattyUITestHarness.waitFor({
            guard let listings = self.windowListings(), predicate(listings) else { return false }
            match = listings
            return true
        }, timeout: 15)
        return match
    }

    /// Opens a second window and returns the identifiers of the original and
    /// the new one. The original is captured while it is the only window.
    @MainActor
    private func openSecondWindow(in app: XCUIApplication) throws -> (original: String, added: String) {
        let original = app.windows.firstMatch.identifier
        XCTAssertFalse(original.isEmpty, "the first window needs a stable identifier")
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor({ app.windows.count >= 2 }, timeout: 10), "Shift-Cmd-N opened no second window")
        var added: String?
        XCTAssertTrue(waitFor({
            for element in app.windows.allElementsBoundByIndex {
                let candidate = element.identifier
                if !candidate.isEmpty && candidate != original {
                    added = candidate
                    return true
                }
            }
            return false
        }, timeout: 10), "no window with a new identifier appeared")
        let addedIdentifier = try XCTUnwrap(added)
        XCTAssertTrue(
            waitFor({ app.windows.element(boundBy: 0).identifier == addedIdentifier }, timeout: 10),
            "the new window must become frontmost before keys are sent"
        )
        return (original, addedIdentifier)
    }

    // MARK: - Per-window Session lists and selection

    @MainActor
    func testWindowsKeepIndependentSessionListsAndSelection() throws {
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }
        let first = try XCTUnwrap(initial.selectedSession)

        _ = try openSecondWindow(in: app)

        let two = try XCTUnwrap(
            waitForWindowListings { $0.count == 2 && $0.allSatisfy { $0.sessionIDs.count == 1 } },
            "list --json should report two windows with one Session each"
        )
        let ids = two.flatMap(\.sessionIDs)
        XCTAssertEqual(Set(ids).count, 2, "the two windows must own distinct Sessions")
        XCTAssertTrue(ids.contains(first.id), "the original Session must stay in the list")
        for window in two {
            XCTAssertEqual(window.selectedSessionID, window.sessionIDs.first, "each window selects its own only Session")
        }

        // Cmd-N goes to the key window (the new one): its list grows and
        // selection moves; the other window's list and selection do not.
        app.typeKey("n", modifierFlags: [.command])
        let grown = try XCTUnwrap(
            waitForWindowListings { $0.count == 2 && $0.contains { $0.sessionIDs.count == 2 } },
            "Cmd-N should add a Session to exactly one window"
        )
        XCTAssertEqual(grown.map(\.sessionIDs.count).sorted(), [1, 2])
        let big = try XCTUnwrap(grown.first { $0.sessionIDs.count == 2 })
        let small = try XCTUnwrap(grown.first { $0.sessionIDs.count == 1 })
        XCTAssertFalse(big.sessionIDs.contains(first.id), "Cmd-N must route to the key (new) window, not the original")
        XCTAssertEqual(big.selectedSessionID, big.sessionIDs.last, "the new Session is selected in its own window")
        XCTAssertNotEqual(big.selectedSessionID, small.selectedSessionID)
        XCTAssertTrue(two.contains { $0.sessionIDs == small.sessionIDs && $0.selectedSessionID == small.selectedSessionID },
                      "the other window's Session and selection must be unchanged")
    }

    // MARK: - Cross-window Bell Feed jump

    @MainActor
    func testBellFeedEntryJumpsToSessionInAnotherWindow() throws {
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }
        let first = try XCTUnwrap(initial.selectedSession)

        // Window A: two Sessions, the second selected, so the first is unseen.
        app.typeKey("n", modifierFlags: [.command])
        let windowA = try XCTUnwrap(
            waitForWindowListings { $0.count == 1 && $0[0].sessionIDs.count == 2 },
            "Cmd-N should give the first window a second Session"
        )[0]
        XCTAssertNotEqual(windowA.selectedSessionID, first.id)

        // Window B: opens with one fresh Session and becomes key.
        let identifiers = try openSecondWindow(in: app)
        let both = try XCTUnwrap(waitForWindowListings { $0.count == 2 && $0.contains { $0.sessionIDs.count == 1 } })
        let windowB = try XCTUnwrap(both.first { $0.sessionIDs.count == 1 })

        let topology = try XCTUnwrap(BattyCLI.topology())
        let target = try XCTUnwrap(topology.session(first.id))
        let tab = try XCTUnwrap(target.pane(target.focusedPaneID)?.activeTabID)
        BattyCLI.runExpectingSuccess(["notify", "--title", "cross window", "--tab", tab.uuidString])

        // Open the Bell Feed from window B's toolbar, the window that does
        // not own the entry's Session.
        let newWindow = BattyUITestHarness.window(withIdentifier: identifiers.added, in: app)
        let bell = newWindow.toolbars.buttons["Bell Feed"].firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 10), "window B has no Bell Feed toolbar button")
        bell.click()
        XCTAssertTrue(
            waitFor({ app.popovers.firstMatch.exists || BattyScreen.element("bell-feed.list", in: app).exists }, timeout: 10),
            "the Bell Feed did not open"
        )
        XCTAssertTrue(waitFor({ BattyScreen.bellEntryIDs(in: app).count == 1 }, timeout: 10),
                      "notify to a Session in another window added no entry")

        let windowAElement = BattyUITestHarness.window(withIdentifier: identifiers.original, in: app)
        func unseenBadge() -> String? {
            let row = windowAElement.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-row.\(first.name)"))
                .firstMatch
            guard row.exists, let value = (try? row.snapshot())?.value as? String,
                  let range = value.range(of: #"\d+(?= unseen)"#, options: .regularExpression)
            else { return nil }
            return String(value[range])
        }
        XCTAssertTrue(waitFor({ unseenBadge() == "1" }, timeout: 10),
                      "the target Session's row in window A should show 1 unseen before the jump: \(String(describing: unseenBadge()))")

        let entry = try XCTUnwrap(BattyScreen.elements(withPrefix: "bell-feed-entry.", in: app).first)
        entry.click()

        XCTAssertTrue(
            waitFor({ app.windows.element(boundBy: 0).identifier == identifiers.original }, timeout: 10),
            "the jump must bring the owning window (A) to the front"
        )

        let jumped = waitForWindowListings { listings in
            listings.contains { $0.sessionIDs.contains(first.id) && $0.selectedSessionID == first.id }
        }
        XCTAssertNotNil(jumped, "clicking the entry did not select the Session in the window that owns it")
        if let jumped {
            let other = jumped.first { !$0.sessionIDs.contains(first.id) }
            XCTAssertEqual(other?.selectedSessionID, windowB.selectedSessionID, "the jump must not change the other window's selection")
        }
        XCTAssertTrue(waitFor({ unseenBadge() == nil }, timeout: 10),
                      "navigating to the Session should clear its unseen badge: \(String(describing: unseenBadge()))")
    }

    // MARK: - Window close

    @MainActor
    func testClosingOneWindowLeavesTheOtherIntact() throws {
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }
        let first = try XCTUnwrap(initial.selectedSession)

        let identifiers = try openSecondWindow(in: app)
        XCTAssertNotNil(waitForWindowListings { $0.count == 2 })

        let newWindow = BattyUITestHarness.window(withIdentifier: identifiers.added, in: app)
        let close = newWindow.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the new window has no close button")
        close.click()

        // A running-process confirmation may appear; accept it if it does.
        let confirm = newWindow.sheets.buttons["Close"].firstMatch
        if confirm.waitForExistence(timeout: 2) { confirm.click() }

        XCTAssertTrue(waitFor({ app.windows.count == 1 }, timeout: 10), "the window did not close (\(app.windows.count) left)")
        XCTAssertEqual(app.windows.firstMatch.identifier, identifiers.original, "the remaining window should be the original")
        let remaining = try XCTUnwrap(waitForWindowListings { $0.count == 1 }, "list --json should report one window after the close")
        XCTAssertEqual(remaining[0].sessionIDs, [first.id], "the surviving window keeps its Session")
        XCTAssertEqual(remaining[0].selectedSessionID, first.id)

        let survivingPane = try XCTUnwrap(BattyCLI.topology()?.session(first.id)?.focusedPaneID)
        XCTAssertTrue(BattyScreen.terminalPane(survivingPane, in: app).waitForExistence(timeout: 10),
                      "the surviving window's terminal Pane should still be on screen")
        XCTAssertEqual(app.state, .runningForeground, "closing a window must not quit the app")
    }
}
