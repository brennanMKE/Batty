// PickerHintBarTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct PickerHintBarTests {
    private func model() -> ProjectPickerModel {
        let projects = [
            Project(name: "Alpha", rootPath: "/Users/test/a", color: .blue, layout: .preset(.singlePane)),
            Project(name: "Beta", rootPath: "/Users/test/b", color: .teal, layout: .preset(.singlePane)),
        ]
        return ProjectPickerModel(projects: projects, openProjectIDs: [], homeDirectory: "/Users/test")
    }

    @Test func escapeHintsHaveOnePhrasePerBehavior() {
        #expect(PickerEscapeHint.dismiss.title == "Esc to dismiss")
        #expect(PickerEscapeHint.clear.title == "Esc to clear")
    }

    @Test func projectPickerEscapeHintIsDismissWithNoFilter() {
        #expect(model().escapeHint == .dismiss)
    }

    @Test func projectPickerEscapeHintIsClearWhileFiltering() {
        var m = model()
        m.setQuery("al")
        #expect(m.escapeHint == .clear)
        #expect(m.escape() == .cleared)
        #expect(m.escapeHint == .dismiss)
    }

    @Test func projectPickerEscapeHintIsDismissForABlankFilter() {
        var m = model()
        m.setQuery("al")
        #expect(m.escapeHint == .clear)
        m.setQuery("   ")
        #expect(m.escapeHint == .dismiss)
    }
}
