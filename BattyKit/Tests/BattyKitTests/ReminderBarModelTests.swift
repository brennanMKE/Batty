// ReminderBarModelTests.swift

import Foundation
import Testing
@testable import BattyKit

/// The Quick Reminder bar's rules: rows, highlight, keys and what each
/// commit asks the store for. No path may drop the typed text.
@MainActor
struct ReminderBarModelTests {
    private let calendar = ReminderFixture.calendar()
    private let now = ReminderFixture.anchor
    private let tomorrow = ReminderTime(hour: 8, minute: 30)

    private func newBar(suggestion: String? = nil) -> ReminderBarModel {
        ReminderBarModel(editing: nil, suggestion: suggestion, tomorrow: tomorrow, now: now, calendar: calendar)
    }

    private func editBar(note: String? = "deploy") -> (ReminderBarModel, SessionReminder) {
        let reminder = SessionReminder(createdAt: now, target: .instant(now.addingTimeInterval(45 * 60)), note: note)
        return (ReminderBarModel(editing: reminder, suggestion: "Check on make", tomorrow: tomorrow, now: now, calendar: calendar), reminder)
    }

    private let timeRows: [ReminderBarRow] = [.after(5), .after(15), .after(30), .after(60), .tomorrow(ReminderTime(hour: 8, minute: 30)), .pick]

    @Test func aNewBarHighlightsFifteenMinutesWithSixTimeRows() {
        let bar = newBar()
        #expect(bar.rows == timeRows)
        #expect(bar.highlightedRow == .after(15))
        #expect(!bar.isEditing)
        #expect(bar.mode == .list)
    }

    @Test func theSuggestionIsCheckOnTheRunningCommand() {
        let session = SessionRuntime(title: "build")
        session.focusedTerminalPane?.activeTab?.runningCommandDisplayName = "sleep"
        #expect(ReminderBarModel.suggestion(for: session) == "Check on sleep")
        #expect(newBar(suggestion: "Check on sleep").text == "Check on sleep")
    }

    @Test func noRunningCommandMeansAnEmptyField() {
        let session = SessionRuntime(title: "idle")
        #expect(ReminderBarModel.suggestion(for: session) == nil)
        #expect(newBar().text.isEmpty)
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6])
    func everyTimeRowCommitsTheTypedText(digit: Int) throws {
        var bar = newBar(suggestion: "Check on make")
        bar.text = "  review PR 42 "
        let row = try #require(bar.row(forCommandDigit: digit))
        var commit = bar.commit(row: row, now: now, calendar: calendar)
        if row == .pick {
            #expect(commit == nil, "Pick opens the picker first")
            #expect(bar.mode == .picking)
            commit = bar.commit(row: .pick, now: now, calendar: calendar)
        }
        guard case .set(let spec, let note) = try #require(commit) else {
            Issue.record("expected .set"); return
        }
        #expect(note == "review PR 42")
        switch row {
        case .after(let minutes): #expect(spec == .after(minutes: minutes))
        case .tomorrow: #expect(spec == .tomorrow(hour: 8, minute: 30))
        case .pick: #expect(spec == .at(bar.pickedDate))
        default: Issue.record("unexpected row \(row)")
        }
    }

    @Test func anEditBarPrefillsTheTextAndHighlightsKeep() {
        let (bar, reminder) = editBar()
        #expect(bar.isEditing)
        #expect(bar.text == "deploy", "the suggestion never replaces the pending text")
        #expect(bar.highlightedRow == .keep(reminder.fireDate(calendar: calendar)!))
        #expect(bar.rows.first == .keep(now.addingTimeInterval(45 * 60)))
    }

    @Test func keepCommitsATextOnlyChange() {
        var (bar, _) = editBar()
        bar.text = "deploy v2"
        #expect(bar.commit(row: bar.highlightedRow, now: now, calendar: calendar) == .keep(note: "deploy v2"))
    }

    @Test func anEditBarEndsWithRemove() {
        var (bar, _) = editBar()
        #expect(bar.rows.last == .remove)
        #expect(Array(bar.rows.dropFirst().dropLast()) == timeRows)
        #expect(bar.commit(row: .remove, now: now, calendar: calendar) == .remove)
    }

    @Test func commandDigitsOneToSixMapToTheTimeRowsInBothModes() {
        let new = newBar()
        let (edit, _) = editBar()
        for digit in 1...6 {
            #expect(new.row(forCommandDigit: digit) == timeRows[digit - 1])
            #expect(edit.row(forCommandDigit: digit) == timeRows[digit - 1])
        }
        #expect(new.row(forCommandDigit: 0) == nil)
        #expect(new.row(forCommandDigit: 7) == nil)
    }

    @Test func arrowsWrapThroughTheRows() {
        var bar = newBar()
        bar.moveHighlight(-1)
        #expect(bar.highlightedRow == .after(5))
        bar.moveHighlight(-1)
        #expect(bar.highlightedRow == .pick)
        bar.moveHighlight(1)
        #expect(bar.highlightedRow == .after(5))
        var (edit, _) = editBar()
        edit.moveHighlight(-1)
        #expect(edit.highlightedRow == .remove)
    }

    @Test func pickOpensThePickerInsteadOfCommitting() {
        var bar = newBar()
        #expect(bar.commit(row: .pick, now: now, calendar: calendar) == nil)
        #expect(bar.mode == .picking)
        #expect(bar.pickedDateIsValid)
        #expect(bar.pickedDate == ReminderFixture.date(2026, 10, 14, 16, 0))
    }

    @Test func thePickedDateDefaultsToAnHourAheadRoundedUpToFiveMinutes() {
        let odd = ReminderFixture.date(2026, 10, 14, 15, 2).addingTimeInterval(17)
        #expect(ReminderBarModel.defaultPickedDate(now: odd, calendar: calendar) == ReminderFixture.date(2026, 10, 14, 16, 5))
    }

    @Test func aPickedTimeUnderAMinuteOrBeyondSevenDaysCannotCommit() {
        var bar = newBar()
        _ = bar.commit(row: .pick, now: now, calendar: calendar)
        bar.setPickedDate(now.addingTimeInterval(30))
        #expect(bar.commit(row: .pick, now: now, calendar: calendar) == nil)
        #expect(!bar.pickedDateIsValid)
        bar.setPickedDate(now.addingTimeInterval(7 * 86_400 + 60))
        #expect(bar.pickedDateIsValid, "a new date clears the error until the next commit")
        #expect(bar.commit(row: .pick, now: now, calendar: calendar) == nil)
        #expect(!bar.pickedDateIsValid)
        bar.setPickedDate(now.addingTimeInterval(2 * 86_400))
        #expect(bar.commit(row: .pick, now: now, calendar: calendar) == .set(.at(now.addingTimeInterval(2 * 86_400)), note: nil))
    }

    @Test func theTextIsCappedAtFiveHundred() {
        var bar = newBar()
        bar.text = String(repeating: "a", count: 620)
        #expect(bar.text.count == SessionReminder.maxNoteLength)
    }

    @Test func theCountShowsOnlyPastFourHundred() {
        var bar = newBar()
        bar.text = String(repeating: "a", count: 400)
        #expect(bar.countLabel == nil)
        bar.text = String(repeating: "a", count: 437)
        #expect(bar.countLabel == "437 / 500")
    }

    @Test func emptyTextCommitsNoNote() {
        var bar = newBar()
        bar.text = "   "
        #expect(bar.commit(row: .after(15), now: now, calendar: calendar) == .set(.after(minutes: 15), note: nil))
    }
}
