// SplitTreeCWDTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct SplitTreeCWDTests {

    @Test func splitInheritsFocusedPaneCWD() {
        let tree = SplitTree()
        let source = tree.focusedPane
        source.activeTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"

        let newPane = tree.splitFocusedPane(
            direction: .horizontal,
            inheritingFrom: source
        )

        #expect(
            newPane.tabs[0].terminal.configuration.workingDirectory
                == "/Users/test/Developer/Batty"
        )
    }

    @Test func splitWithoutSourceHasNoCWD() {
        let tree = SplitTree()
        tree.focusedPane.activeTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"

        let newPane = tree.splitFocusedPane(direction: .horizontal)

        #expect(newPane.tabs[0].terminal.configuration.workingDirectory == nil)
    }

    @Test func splitFallsBackToConfigurationWorkingDirectory() {
        let tree = SplitTree()
        let sourcePane = tree.focusedPane
        sourcePane.activeTab.terminal.configuration.workingDirectory = "/tmp/fallback"

        let newPane = tree.splitFocusedPane(
            direction: .vertical,
            inheritingFrom: sourcePane
        )

        #expect(newPane.tabs[0].terminal.configuration.workingDirectory == "/tmp/fallback")
    }
}
