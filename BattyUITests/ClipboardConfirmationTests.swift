// ClipboardConfirmationTests.swift

import XCTest

/// OSC 52 clipboard reads: the default Setting (Never) denies silently, and
/// with Ask the dialog survives a burst of reads and remembers Deny.
nonisolated final class ClipboardConfirmationTests: XCTestCase {

    private static let readBurst = "printf '\\033]52;c;?\\a'; sleep 0.2; printf '\\033]52;c;?\\a'; sleep 0.2; printf '\\033]52;c;?\\a'; exec sleep 600"
    private static let singleRead = "printf '\\033]52;c;?\\a'; exec sleep 600"
    private static let askArguments = ["-co.sstools.Batty.clipboardRead", "ask"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    @MainActor
    private func splitRunning(_ body: String, named name: String, beside paneID: UUID, scratch: URL) throws {
        let script = try BattyCLI.makeScript(in: scratch, named: name, body: body)
        BattyCLI.runExpectingSuccess(["pane", "split", "-h", "--pane", paneID.uuidString, "--command", script])
    }

    @MainActor
    func testDefaultNeverShowsNoClipboardDialog() throws {
        let scratch = try BattyCLI.makeScratchDirectory()
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }
        let session = try XCTUnwrap(initial.selectedSession)

        try splitRunning(Self.readBurst, named: "read.sh", beside: session.focusedPaneID, scratch: scratch)

        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 3),
                       "With the default Setting a clipboard read must not show a dialog")
    }

    @MainActor
    func testAskDialogStaysUpThroughABurst() throws {
        let scratch = try BattyCLI.makeScratchDirectory()
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self, extraArguments: Self.askArguments)
        defer { app.terminate() }
        let session = try XCTUnwrap(initial.selectedSession)

        try splitRunning(Self.readBurst, named: "read.sh", beside: session.focusedPaneID, scratch: scratch)

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Ask must show the clipboard dialog")
        let message = sheet.staticTexts.matching(NSPredicate(format: "value CONTAINS 'read the clipboard' OR label CONTAINS 'read the clipboard'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        let text = message.label.isEmpty ? ((message.value as? String) ?? "") : message.label
        XCTAssertTrue(text.contains("Pane"), "the dialog must name the Pane, saw \(text)")

        XCTAssertFalse(waitFor({ !sheet.exists }, timeout: 2), "a burst of reads must not dismiss the dialog")

        sheet.buttons["Allow"].click()
        XCTAssertTrue(waitFor({ !app.sheets.firstMatch.exists }, timeout: 5))
    }

    @MainActor
    func testAskDenyIsRememberedForTheSession() throws {
        let scratch = try BattyCLI.makeScratchDirectory()
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self, extraArguments: Self.askArguments)
        defer { app.terminate() }
        let session = try XCTUnwrap(initial.selectedSession)

        try splitRunning(Self.singleRead, named: "read1.sh", beside: session.focusedPaneID, scratch: scratch)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        sheet.buttons["Deny"].click()
        XCTAssertTrue(waitFor({ !app.sheets.firstMatch.exists }, timeout: 5))

        try splitRunning(Self.singleRead, named: "read2.sh", beside: session.focusedPaneID, scratch: scratch)
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 3),
                       "Deny must be remembered for this Session")
    }
}
