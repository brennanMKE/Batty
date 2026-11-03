// OpacityPercentFieldTests.swift

import AppKit
import Testing
@testable import BattyKit

@MainActor
struct OpacityPercentFieldTests {
    // MARK: - Parsing and clamping

    @Test(arguments: [
        ("37", 0.37),
        ("150", 1.0),
        ("-5", 0.0),
        ("0", 0.0),
        ("100", 1.0),
        (" 37 ", 0.37),
        ("37%", 0.37),
        ("37.4", 0.37),
    ])
    func committedTextGivesTheStoredValue(text: String, expected: Double) {
        #expect(OpacityPercent.value(afterCommitting: text, current: 0.5) == expected)
    }

    @Test(arguments: ["", " ", "abc", "3x", "nan", "inf", "0x10", "%", "-", "1e2"])
    func nonNumericTextChangesNothing(text: String) {
        #expect(OpacityPercent.value(afterCommitting: text, current: 0.5) == 0.5)
    }

    @Test func percentShownIsWholeWithNoFloatingPointError() {
        #expect(OpacityPercent.text(for: 0.35) == "35")
        #expect(OpacityPercent.text(for: 0.29) == "29")
        #expect(OpacityPercent.text(for: 0.07) == "7")
    }

    @Test func everyPercentSurvivesARoundTrip() {
        for percent in 0...100 {
            let stored = OpacityPercent.value(afterCommitting: String(percent), current: percent == 50 ? 0 : 0.5)
            #expect(stored == Double(percent) / 100)
            #expect(OpacityPercent.text(for: stored) == String(percent))
        }
    }

    @Test func storedValueOutsideTheRangeShowsClamped() {
        #expect(OpacityPercent.text(for: 1.5) == "100")
        #expect(OpacityPercent.text(for: -1) == "0")
        #expect(OpacityPercent.text(for: .infinity) == "100")
        #expect(OpacityPercent.text(for: .nan) == "0")
    }

    @Test func committingTheShownPercentKeepsAValueOffTheWholePercent() {
        #expect(OpacityPercent.value(afterCommitting: "36", current: 0.355) == 0.355)
        #expect(OpacityPercent.value(afterCommitting: "100", current: 1.5) == 1.5)
    }

    // MARK: - The field, with a real field editor

    private final class Harness {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        let field: NSTextField
        let coordinator: OpacityPercentFieldCoordinator
        var commits: [Double] = []

        init(value: Double) {
            var record: (Double) -> Void = { _ in }
            coordinator = OpacityPercentFieldCoordinator(value: value) { record($0) }
            field = OpacityPercentFieldCoordinator.makeField(delegate: coordinator)
            field.frame = NSRect(x: 0, y: 0, width: 44, height: 22)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(field)
            record = { [unowned self] in commits.append($0) }
        }

        var editor: NSTextView { field.currentEditor() as! NSTextView }

        func beginEditing() {
            #expect(window.makeFirstResponder(field))
        }

        func type(_ text: String) {
            beginEditing()
            typeWithoutRefocusing(text)
        }

        func typeWithoutRefocusing(_ text: String) {
            editor.selectAll(nil)
            for character in text {
                editor.insertText(String(character), replacementRange: editor.selectedRange())
            }
        }

        func pressReturn() {
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }

        func loseFocus() {
            #expect(window.makeFirstResponder(nil))
        }

        /// Posted rather than caused: a borderless window can't become key.
        func windowResignsKey() {
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    @Test func typingAppliesNothingUntilReturn() {
        let harness = Harness(value: 0.5)
        harness.type("37")
        #expect(harness.commits.isEmpty)
        harness.pressReturn()
        #expect(harness.commits == [0.37])
        #expect(harness.editor.string == "37")
    }

    @Test func focusLossCommitsOnce() {
        let harness = Harness(value: 0.5)
        harness.type("37")
        harness.loseFocus()
        #expect(harness.commits == [0.37])
        #expect(harness.field.stringValue == "37")
    }

    @Test func returnThenFocusLossDoesNotCommitTwice() {
        let harness = Harness(value: 0.5)
        harness.type("37")
        harness.pressReturn()
        harness.loseFocus()
        #expect(harness.commits == [0.37])
        #expect(harness.field.stringValue == "37")
    }

    @Test func aboveRangeAtFullOpacityRedisplaysWithNoWrite() {
        let harness = Harness(value: 1)
        harness.type("150")
        harness.pressReturn()
        #expect(harness.commits.isEmpty)
        #expect(harness.editor.string == "100")
        harness.loseFocus()
        #expect(harness.field.stringValue == "100")
    }

    @Test func aboveRangeOnFocusLossRedisplaysWithNoWrite() {
        let harness = Harness(value: 1)
        harness.type("150")
        harness.loseFocus()
        #expect(harness.commits.isEmpty)
        #expect(harness.field.stringValue == "100")
    }

    @Test func nonNumericRevertsToTheLastValue() {
        let harness = Harness(value: 0.35)
        harness.type("abc")
        harness.loseFocus()
        #expect(harness.commits.isEmpty)
        #expect(harness.field.stringValue == "35")
    }

    @Test func focusingAndLeavingWithoutTypingWritesNothing() {
        let harness = Harness(value: 0.355)
        harness.beginEditing()
        harness.loseFocus()
        #expect(harness.commits.isEmpty)
    }

    @Test func newValueUpdatesAFieldThatIsNotBeingEdited() {
        let harness = Harness(value: 0.5)
        harness.coordinator.render(0.65, in: harness.field)
        #expect(harness.field.stringValue == "65")
    }

    @Test func newValueUpdatesAFocusedFieldWithoutEndingEditing() {
        let harness = Harness(value: 0.5)
        harness.beginEditing()
        harness.coordinator.render(0.65, in: harness.field)
        #expect(harness.field.currentEditor() != nil)
        #expect(harness.editor.string == "65")
        harness.loseFocus()
        #expect(harness.commits.isEmpty)
        #expect(harness.field.stringValue == "65")
    }

    @Test func newValueReplacesADraft() {
        let harness = Harness(value: 0.5)
        harness.type("37")
        harness.coordinator.render(0.65, in: harness.field)
        harness.loseFocus()
        #expect(harness.commits.isEmpty)
        #expect(harness.field.stringValue == "65")
    }

    @Test func committedValueAgreesWithTheUpdateThatFollows() {
        let harness = Harness(value: 0.5)
        harness.type("37")
        harness.pressReturn()
        harness.coordinator.render(0.37, in: harness.field)
        harness.type("37")
        harness.pressReturn()
        #expect(harness.commits == [0.37])
    }

    // MARK: - The window stops being key

    @Test func draftCommitsOnceWhenTheWindowResignsKeyAndEditingContinues() {
        let harness = Harness(value: 0.5)
        harness.type("37")
        harness.windowResignsKey()
        #expect(harness.commits == [0.37])
        #expect(harness.field.currentEditor() != nil)
        #expect(harness.editor.string == "37")
        harness.windowResignsKey()
        #expect(harness.commits == [0.37])
        harness.loseFocus()
        #expect(harness.commits == [0.37])
        #expect(harness.field.stringValue == "37")
    }

    @Test func resignWithNoDraftCommitsNothing() {
        let harness = Harness(value: 0.355)
        harness.beginEditing()
        harness.windowResignsKey()
        harness.type("36")
        harness.pressReturn()
        harness.windowResignsKey()
        #expect(harness.commits.isEmpty)
        #expect(harness.editor.string == "36")
    }

    @Test func aboveRangeOnResignRedisplaysWithNoWrite() {
        let harness = Harness(value: 1)
        harness.type("150")
        harness.windowResignsKey()
        #expect(harness.commits.isEmpty)
        #expect(harness.editor.string == "100")
    }

    @Test func nonNumericOnResignRevertsToTheLastValue() {
        let harness = Harness(value: 0.35)
        harness.type("abc")
        harness.windowResignsKey()
        #expect(harness.commits.isEmpty)
        #expect(harness.editor.string == "35")
    }

    @Test func anotherWindowResigningKeyCommitsNothing() {
        let harness = Harness(value: 0.5)
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        other.isReleasedWhenClosed = false
        harness.type("37")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        #expect(harness.commits.isEmpty)
        #expect(harness.editor.string == "37")
    }

    @Test func returnThenResignCommitsOnce() {
        let harness = Harness(value: 0.5)
        harness.type("37")
        harness.pressReturn()
        harness.windowResignsKey()
        #expect(harness.commits == [0.37])
    }

    @Test func aDraftTypedAfterAResignCommitsOnTheNextResign() {
        let harness = Harness(value: 0.5)
        harness.type("37")
        harness.windowResignsKey()
        harness.typeWithoutRefocusing("40")
        #expect(harness.commits == [0.37])
        harness.windowResignsKey()
        #expect(harness.commits == [0.37, 0.4])
    }

    @Test func aDraftReplacedByANewValueDoesNotCommitOnResign() {
        let harness = Harness(value: 0.5)
        harness.type("37")
        harness.coordinator.render(0.65, in: harness.field)
        harness.windowResignsKey()
        #expect(harness.commits.isEmpty)
        #expect(harness.editor.string == "65")
    }

    @Test func theWindowIsObservedOnlyWhileEditing() {
        let harness = Harness(value: 0.5)
        #expect(harness.coordinator.observedWindow == nil)
        harness.type("37")
        #expect(harness.coordinator.observedWindow === harness.window)
        harness.loseFocus()
        #expect(harness.coordinator.observedWindow == nil)
        #expect(harness.commits == [0.37])
    }

    @Test func aResignAfterFocusLossCommitsNothing() {
        let harness = Harness(value: 0.5)
        harness.type("37")
        harness.loseFocus()
        harness.windowResignsKey()
        #expect(harness.commits == [0.37])
        #expect(harness.field.stringValue == "37")
    }

    @Test func disablingAFieldNotBeingEditedAppliesAtOnce() {
        let harness = Harness(value: 0.5)
        harness.coordinator.setEnabled(false, on: harness.field)
        #expect(!harness.field.isEnabled)
        harness.coordinator.setEnabled(true, on: harness.field)
        #expect(harness.field.isEnabled)
    }

    /// The disable itself runs on a later main-queue turn, because it aborts
    /// editing. What matters here is that the update can't end editing.
    @Test func disablingAFocusedFieldLeavesEditingAloneDuringTheUpdate() {
        let harness = Harness(value: 0.5)
        harness.beginEditing()
        harness.coordinator.setEnabled(false, on: harness.field)
        #expect(harness.field.currentEditor() != nil)
        #expect(harness.field.isEnabled)
    }

    @Test func aSizeIsFixedWhateverTheText() {
        let harness = Harness(value: 1)
        let wide = harness.field.intrinsicContentSize.width
        harness.field.stringValue = "1000000000000000000000"
        #expect(harness.field.intrinsicContentSize.width == wide)
    }
}
