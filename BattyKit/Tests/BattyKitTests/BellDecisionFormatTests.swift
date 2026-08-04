// BellDecisionFormatTests.swift

import Foundation
import Testing
@testable import BattyKit

/// #0297: `BellDecisionRecord.outcome` and `BellDecisionFormat`. The
/// feature went through three designs before landing here (see
/// `BellDecisionHistory`'s type doc comment): an always-on `Logger` line
/// (hashed, then verbatim), then this — an in-memory ring buffer the user
/// exports themselves via Settings (`BellDecisionExportRow`). Nothing here
/// touches disk, `OSLog`, or `NSApplication` directly, so these are plain
/// value/pure-function tests.
///
/// `sessionTitle`/`tabLabel`/`message` are logged **verbatim** in the
/// export text, not hashed — round-1 review found hashing self-defeating
/// (no stable join key survives a relaunch), and the user's own redirect
/// to a manual-export design reaffirmed it: they review this themselves,
/// deliberately, so hashing would defeat the point exactly as review
/// argued. `formatIncludesTheRawSessionTitleTabLabelAndMessage` pins that
/// direction.
struct BellDecisionFormatTests {

    // MARK: - Outcome, every gate in priority order

    @Test func nilNotifierSuppressesRegardlessOfOtherGates() {
        let outcome = BellDecisionRecord.outcome(
            notifierPresent: false,
            sessionMuted: false,
            systemNotificationsEnabled: true,
            battyActive: false,
            entrySeenAtCreation: false
        )
        #expect(outcome == .suppressed(.nilNotifier))
    }

    @Test func sessionMutedSuppressesWhenNotifierIsPresent() {
        let outcome = BellDecisionRecord.outcome(
            notifierPresent: true,
            sessionMuted: true,
            systemNotificationsEnabled: true,
            battyActive: false,
            entrySeenAtCreation: false
        )
        #expect(outcome == .suppressed(.sessionMuted))
    }

    @Test func systemNotificationsDisabledSuppressesWhenNotMutedAndNotifierPresent() {
        let outcome = BellDecisionRecord.outcome(
            notifierPresent: true,
            sessionMuted: false,
            systemNotificationsEnabled: false,
            battyActive: false,
            entrySeenAtCreation: false
        )
        #expect(outcome == .suppressed(.systemNotificationsDisabled))
    }

    @Test func frontmostAndSeenSuppressesAsTheLastGate() {
        let outcome = BellDecisionRecord.outcome(
            notifierPresent: true,
            sessionMuted: false,
            systemNotificationsEnabled: true,
            battyActive: true,
            entrySeenAtCreation: true
        )
        #expect(outcome == .suppressed(.frontmostAndSeen))
    }

    @Test func submitsWhenEveryGatePasses() {
        let outcome = BellDecisionRecord.outcome(
            notifierPresent: true,
            sessionMuted: false,
            systemNotificationsEnabled: true,
            battyActive: true,
            entrySeenAtCreation: false
        )
        #expect(outcome == .submitted)
    }

    @Test func submitsWhenBattyIsNotFrontmostEvenIfTheEntryWasSeen() {
        // shouldPost's "not active -> always post" branch: an entry can be
        // seen (e.g. focused-tab bell) while Batty itself isn't frontmost
        // (another app is key) -- the notification should still fire.
        let outcome = BellDecisionRecord.outcome(
            notifierPresent: true,
            sessionMuted: false,
            systemNotificationsEnabled: true,
            battyActive: false,
            entrySeenAtCreation: true
        )
        #expect(outcome == .submitted)
    }

    // MARK: - format(_:): trigger kinds, identifiers, and verbatim content

    private static let fixedBellTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

    static func makeRecord(
        trigger: BellTriggerKind,
        sessionTitle: String = "My Session",
        tabLabel: String = "ssh prod-box",
        message: String? = "Build failed: 3 errors",
        outcome: BellDecisionRecord.Outcome = .submitted
    ) -> BellDecisionRecord {
        BellDecisionRecord(
            trigger: trigger,
            entryID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            windowID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            sessionID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            paneID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            tabID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            bellTimestamp: fixedBellTimestamp,
            sessionTitle: sessionTitle,
            tabLabel: tabLabel,
            // Matches AppStateStore.makeBellDecisionRecord's real
            // computation (entry.message?.isEmpty == false) rather than
            // just `message != nil`, so an empty-string message fixture
            // exercises the same hasMessage=false path production takes.
            hasMessage: message?.isEmpty == false,
            message: message,
            battyActive: true,
            entrySeenAtCreation: false,
            notifierPresent: true,
            sessionMuted: false,
            systemNotificationsEnabled: true,
            foregroundPid: 4242,
            ttyName: "/dev/ttys004",
            outcome: outcome
        )
    }

    @Test(arguments: [BellTriggerKind.bel, .oscNotification, .cliNotification])
    func formatLabelsTheTriggerKindDistinctly(trigger: BellTriggerKind) {
        let line = BellDecisionFormat.format(Self.makeRecord(trigger: trigger))
        #expect(line.contains("trigger=\(trigger.rawValue)"))
    }

    @Test func formatIncludesIdentifiersAndDecisionFactsVerbatim() {
        let line = BellDecisionFormat.format(Self.makeRecord(trigger: .bel))
        #expect(line.contains("entry=11111111-1111-1111-1111-111111111111"))
        #expect(line.contains("window=22222222-2222-2222-2222-222222222222"))
        #expect(line.contains("session=33333333-3333-3333-3333-333333333333"))
        #expect(line.contains("pane=44444444-4444-4444-4444-444444444444"))
        #expect(line.contains("tab=55555555-5555-5555-5555-555555555555"))
        #expect(line.contains("bellAt=\(Self.fixedBellTimestamp.ISO8601Format())"))
        #expect(line.contains("battyActive=true"))
        #expect(line.contains("notifierPresent=true"))
        #expect(line.contains("sessionMuted=false"))
        #expect(line.contains("systemNotificationsEnabled=true"))
        #expect(line.contains("foregroundPid=4242"))
        #expect(line.contains("tty=/dev/ttys004"))
        #expect(line.contains("outcome=submitted"))
    }

    @Test func formatLabelsEachSuppressionReasonDistinctly() {
        let reasons: [BellDecisionRecord.SuppressionReason] = [
            .nilNotifier, .sessionMuted, .systemNotificationsDisabled, .frontmostAndSeen
        ]
        for reason in reasons {
            let line = BellDecisionFormat.format(Self.makeRecord(trigger: .bel, outcome: .suppressed(reason)))
            #expect(line.contains("outcome=suppressed:\(reason.rawValue)"))
        }
    }

    /// The load-bearing privacy-direction assertion (see the type doc
    /// comment): #0297 exists so the user can trace an exported line back
    /// to which program is ringing the bell, and the only fields that
    /// answer that are the verbatim session title, tab label, and message.
    @Test func formatIncludesTheRawSessionTitleTabLabelAndMessage() {
        let sessionTitle = "Project Nightingale — client call notes"
        let tabLabel = "ssh alice@internal-box.corp.example"
        let message = "Password expired for user alice"
        let line = BellDecisionFormat.format(Self.makeRecord(
            trigger: .oscNotification,
            sessionTitle: sessionTitle,
            tabLabel: tabLabel,
            message: message
        ))
        #expect(line.contains(sessionTitle))
        #expect(line.contains(tabLabel))
        #expect(line.contains(message))
        #expect(line.contains("alice"))
    }

    @Test func formatAlsoIncludesStableDigestsAlongsideTheVerbatimText() {
        let line = BellDecisionFormat.format(Self.makeRecord(trigger: .bel, sessionTitle: "Session A", tabLabel: "Tab A", message: "boom"))
        #expect(line.contains("sessionTitleDigest=\(BellDecisionFormat.stableDigest("Session A"))"))
        #expect(line.contains("tabLabelDigest=\(BellDecisionFormat.stableDigest("Tab A"))"))
        #expect(line.contains("messageDigest=\(BellDecisionFormat.stableDigest("boom"))"))
    }

    @Test func formatEscapesQuotesAndNewlinesSoTheLineStaysOneLine() {
        let message = "line one\nline two \"quoted\" \\ backslash"
        let line = BellDecisionFormat.format(Self.makeRecord(trigger: .cliNotification, message: message))
        #expect(!line.contains("line one\nline two"), "an unescaped newline would split the decision across two export lines")
        #expect(line.contains("line one\\nline two \\\"quoted\\\" \\\\ backslash"))
    }

    @Test func formatTruncatesAPathologicallyLongMessage() {
        let message = String(repeating: "a", count: BellDecisionFormat.maxFieldLength * 4)
        let line = BellDecisionFormat.format(Self.makeRecord(trigger: .oscNotification, message: message))
        #expect(!line.contains(message), "the full 4x-oversized message must not appear verbatim")
        #expect(line.contains("…"), "truncation must be visible in the line, not silent")
    }

    /// Round-2 review's nit 3: `quotedField` used to check
    /// `escaped.count >= maxLength` *after* appending, so a field whose
    /// escaped length landed exactly on the boundary got a false `…` even
    /// though nothing was dropped. A field of exactly `maxFieldLength`
    /// plain (non-escaping) characters is the direct reproduction.
    @Test func quotedFieldDoesNotFalselyMarkTruncationAtExactlyTheBoundary() {
        let exactlyAtBound = String(repeating: "a", count: BellDecisionFormat.maxFieldLength)
        let quoted = BellDecisionFormat.quotedField(exactlyAtBound)
        #expect(!quoted.contains("…"), "nothing was truncated -- every character fit exactly")
        #expect(quoted == "\"\(exactlyAtBound)\"")
    }

    @Test func quotedFieldMarksTruncationForOneCharacterOverTheBoundary() {
        let oneOver = String(repeating: "a", count: BellDecisionFormat.maxFieldLength + 1)
        let quoted = BellDecisionFormat.quotedField(oneOver)
        #expect(quoted.contains("…"), "one character didn't fit -- the marker must appear")
    }

    // MARK: - truncateForRetention(_:): the record-construction-time bound (round-2 review B2)

    @Test func truncateForRetentionLeavesShortTextUnchanged() {
        #expect(BellDecisionFormat.truncateForRetention("short") == "short")
    }

    @Test func truncateForRetentionLeavesTextExactlyAtTheBoundUnchanged() {
        let exactlyAtBound = String(repeating: "a", count: BellDecisionFormat.maxFieldLength)
        #expect(BellDecisionFormat.truncateForRetention(exactlyAtBound) == exactlyAtBound)
    }

    @Test func truncateForRetentionCutsTextOverTheBoundToExactlyMaxLength() {
        let overBound = String(repeating: "a", count: BellDecisionFormat.maxFieldLength * 3)
        let truncated = BellDecisionFormat.truncateForRetention(overBound)
        #expect(truncated.count == BellDecisionFormat.maxFieldLength)
    }

    @Test func truncateForRetentionIsLosslessWithRespectToQuotedFieldsOutput() {
        // The claim the fix depends on: truncating raw text to maxLength
        // *before* quoting shows the same visible characters quoting the
        // untruncated text directly would have shown -- not the identical
        // formatted string, since quoting an already-exactly-maxLength
        // string (nothing left to cut) correctly omits the "…" marker
        // quoting the longer original correctly includes (quotedFieldDoesNot
        // FalselyMarkTruncationAtExactlyTheBoundary pins that half). Losing
        // the marker is an acceptable, expected side effect of moving
        // truncation earlier; losing *content* would not be.
        let overBound = String(repeating: "x", count: BellDecisionFormat.maxFieldLength * 3)
        let truncatedThenQuoted = BellDecisionFormat.quotedField(BellDecisionFormat.truncateForRetention(overBound))
        let quotedDirectly = BellDecisionFormat.quotedField(overBound)
        #expect(Self.visibleContent(of: truncatedThenQuoted) == Self.visibleContent(of: quotedDirectly))
    }

    /// Strips the surrounding quotes `quotedField` always adds and a
    /// trailing truncation marker if present, leaving just the characters
    /// a reader would actually see as the field's content.
    private static func visibleContent(of quoted: String) -> String {
        var s = quoted
        if s.hasPrefix("\"") { s.removeFirst() }
        if s.hasSuffix("\"") { s.removeLast() }
        if s.hasSuffix("…") { s.removeLast() }
        return s
    }

    @Test func formatOmitsTheMessageFieldWhenThereIsNoMessage() {
        let line = BellDecisionFormat.format(Self.makeRecord(trigger: .bel, message: nil))
        #expect(line.contains("hasMessage=false"))
        #expect(line.contains("message=nil"))
        #expect(line.contains("messageDigest=nil"))
    }

    @Test func formatOmitsTheMessageFieldWhenTheMessageIsEmpty() {
        // hasMessage tracks entry.message?.isEmpty == false; an empty string
        // must display the same as no message at all, not an empty pair of
        // quotes and a digest of "".
        let line = BellDecisionFormat.format(Self.makeRecord(trigger: .bel, message: ""))
        #expect(line.contains("hasMessage=false"))
        #expect(line.contains("message=nil"))
        #expect(line.contains("messageDigest=nil"))
    }

    // MARK: - stableDigest: pure, deterministic, distinguishing

    @Test func stableDigestIsDeterministicAcrossCalls() {
        #expect(BellDecisionFormat.stableDigest("hello") == BellDecisionFormat.stableDigest("hello"))
    }

    @Test func stableDigestDiffersForDifferentInput() {
        #expect(BellDecisionFormat.stableDigest("hello") != BellDecisionFormat.stableDigest("hello2"))
    }

    @Test func stableDigestNeverReturnsTheInputVerbatim() {
        let text = "sensitive tab title"
        #expect(BellDecisionFormat.stableDigest(text) != text)
    }

    // MARK: - exportText(_:): ordering and empty-input behavior

    @Test func exportTextStartsWithASelfDescribingHeaderLine() {
        let text = BellDecisionFormat.exportText([Self.makeRecord(trigger: .bel)])
        let firstLine = text.components(separatedBy: "\n").first ?? ""
        #expect(firstLine.hasPrefix("#"), "the header must be a comment line, not mistaken for a decision record")
        #expect(firstLine.contains("1 record"))
    }

    @Test func exportTextOrdersNewestFirstAfterTheHeader() {
        let older = Self.makeRecord(trigger: .bel, sessionTitle: "older")
        let newer = Self.makeRecord(trigger: .oscNotification, sessionTitle: "newer")
        let text = BellDecisionFormat.exportText([older, newer])
        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == 3, "header + 2 records")
        #expect(lines[1].contains("newer"))
        #expect(lines[2].contains("older"))
    }

    @Test func exportTextIsEmptyForNoRecords() {
        // No header either -- Copy/Save are already disabled on an empty
        // buffer, so there is nothing to describe.
        #expect(BellDecisionFormat.exportText([]).isEmpty)
    }

    @Test func exportTextRoundTripsEveryFieldOfARecord() {
        let record = Self.makeRecord(trigger: .cliNotification, sessionTitle: "roundtrip-session", tabLabel: "roundtrip-tab", message: "roundtrip-message")
        let text = BellDecisionFormat.exportText([record])
        let recordLine = text.components(separatedBy: "\n").last ?? ""
        #expect(recordLine == BellDecisionFormat.format(record), "the last line of a single-record export must be exactly that record's formatted line")
        #expect(text.contains("roundtrip-session"))
        #expect(text.contains("roundtrip-tab"))
        #expect(text.contains("roundtrip-message"))
    }
}
