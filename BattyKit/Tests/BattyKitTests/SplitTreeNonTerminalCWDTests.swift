// SplitTreeNonTerminalCWDTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct SplitTreeNonTerminalCWDTests {

    private func cwd(of pane: PaneRuntime?) -> String? {
        pane?.tabs[0].terminal.configuration.workingDirectory
    }

    /// Created with `isSessionSelected: false` so the content is suspended: no
    /// watcher, scan or sampling task starts.
    @discardableResult
    private func addGitStatusPane(
        to tree: SplitTree,
        splitting target: PaneRuntime,
        directoryPath: String
    ) -> PaneRuntime {
        tree.splitPane(
            id: target.id,
            direction: .horizontal,
            kind: .gitStatus,
            contentFactory: { _ in GitStatusPaneContent(directoryPath: directoryPath) },
            isSessionSelected: false
        )!
    }

    @discardableResult
    private func addProcessStatusPane(
        to tree: SplitTree,
        splitting target: PaneRuntime,
        processTarget: ProcessStatusPaneContent.Target?
    ) -> PaneRuntime {
        let lookup: (UUID) -> TabRuntime? = { [weak tree] id in
            tree?.allPanes.flatMap(\.tabs).first { $0.id == id }
        }
        return tree.splitPane(
            id: target.id,
            direction: .horizontal,
            kind: .processStatus,
            contentFactory: { _ in ProcessStatusPaneContent(target: processTarget, tabLookup: lookup) },
            isSessionSelected: false
        )!
    }

    @discardableResult
    private func addInertPane(
        to tree: SplitTree,
        splitting target: PaneRuntime,
        kind: PaneContentKind
    ) -> PaneRuntime {
        tree.splitPane(
            id: target.id,
            direction: .horizontal,
            kind: kind,
            contentFactory: { _ in nil },
            isSessionSelected: false
        )!
    }

    // MARK: - Git Status source

    @Test func splitFromGitStatusInheritsItsDirectory() {
        let tree = SplitTree()
        let terminal = tree.focusedPane
        terminal.activeTab?.terminal.configuration.workingDirectory = "/Users/test/elsewhere"
        let git = addGitStatusPane(to: tree, splitting: terminal, directoryPath: "/Users/test/Developer/Repo")

        let newPane = tree.splitFocusedPane(direction: .vertical, inheritingFrom: git)

        #expect(newPane.kind == .terminal)
        #expect(cwd(of: newPane) == "/Users/test/Developer/Repo")
    }

    @Test func splitFromGitStatusFollowsChangeDirectory() {
        let tree = SplitTree()
        let git = addGitStatusPane(to: tree, splitting: tree.focusedPane, directoryPath: "/Users/test/Developer/Repo")
        (git.content as? GitStatusPaneContent)?.changeDirectory(to: "/Users/test/Developer/Other")

        let newPane = tree.splitFocusedPane(direction: .vertical, inheritingFrom: git)

        #expect(cwd(of: newPane) == "/Users/test/Developer/Other")
    }

    @Test func splitFromGitStatusPassesASubdirectoryThroughUnchanged() {
        let tree = SplitTree()
        let git = addGitStatusPane(to: tree, splitting: tree.focusedPane, directoryPath: "/Users/test/Developer/Repo/Sources/Deep")

        let newPane = tree.splitFocusedPane(direction: .vertical, inheritingFrom: git)

        #expect(cwd(of: newPane) == "/Users/test/Developer/Repo/Sources/Deep")
    }

    @Test func fullDimensionSplitFromGitStatusInheritsItsDirectory() {
        let tree = SplitTree()
        let git = addGitStatusPane(to: tree, splitting: tree.focusedPane, directoryPath: "/Users/test/Developer/Repo")

        let newPane = tree.splitFullDimension(direction: .horizontal, inheritingFrom: git)

        #expect(cwd(of: newPane) == "/Users/test/Developer/Repo")
    }

    @Test func splitPaneByIDFromGitStatusInheritsItsDirectory() {
        let tree = SplitTree()
        let git = addGitStatusPane(to: tree, splitting: tree.focusedPane, directoryPath: "/Users/test/Developer/Repo")

        let newPane = tree.splitPane(id: git.id, direction: .vertical, isSessionSelected: true)

        #expect(cwd(of: newPane) == "/Users/test/Developer/Repo")
    }

    // MARK: - Process Status source

    @Test func splitFromProcessStatusFollowingATabInheritsThatTabsDirectory() {
        let tree = SplitTree()
        let first = tree.focusedPane
        first.activeTab?.terminal.configuration.workingDirectory = "/Users/test/followed"
        let second = tree.splitFocusedPane(direction: .horizontal, inheritingFrom: first)
        second.activeTab?.terminal.configuration.workingDirectory = "/Users/test/recent"
        tree.focusedPaneID = first.id
        tree.focusedPaneID = second.id
        let process = addProcessStatusPane(
            to: tree,
            splitting: second,
            processTarget: .followingTab(first.activeTabID)
        )

        let newPane = tree.splitFocusedPane(direction: .vertical, inheritingFrom: process)

        #expect(cwd(of: newPane) == "/Users/test/followed")
    }

    @Test func splitFromPinnedProcessStatusFallsBackToTheMostRecentTerminal() {
        let tree = SplitTree()
        let first = tree.focusedPane
        first.activeTab?.terminal.configuration.workingDirectory = "/Users/test/first"
        let second = tree.splitFocusedPane(direction: .horizontal, inheritingFrom: first)
        second.activeTab?.terminal.configuration.workingDirectory = "/Users/test/second"
        tree.focusedPaneID = first.id
        tree.focusedPaneID = second.id
        let process = addProcessStatusPane(to: tree, splitting: second, processTarget: .pinned(1))

        let newPane = tree.splitFocusedPane(direction: .vertical, inheritingFrom: process)

        #expect(cwd(of: newPane) == "/Users/test/second")
    }

    @Test func splitFromProcessStatusFollowingAMissingTabFallsBackToTheMostRecentTerminal() {
        let tree = SplitTree()
        let first = tree.focusedPane
        first.activeTab?.terminal.configuration.workingDirectory = "/Users/test/first"
        let process = addProcessStatusPane(to: tree, splitting: first, processTarget: .followingTab(UUID()))

        let newPane = tree.splitFocusedPane(direction: .vertical, inheritingFrom: process)

        #expect(cwd(of: newPane) == "/Users/test/first")
    }

    // MARK: - Kinds with no directory of their own

    @Test(arguments: [PaneContentKind.systemMetrics, .lmStudioDashboard])
    func splitFromAKindWithoutADirectoryUsesTheMostRecentlyFocusedTerminal(kind: PaneContentKind) {
        let tree = SplitTree()
        let first = tree.focusedPane
        first.activeTab?.terminal.configuration.workingDirectory = "/Users/test/first"
        let second = tree.splitFocusedPane(direction: .horizontal, inheritingFrom: first)
        second.activeTab?.terminal.configuration.workingDirectory = "/Users/test/second"
        tree.focusedPaneID = first.id
        tree.focusedPaneID = second.id
        let status = addInertPane(to: tree, splitting: second, kind: kind)

        #expect(cwd(of: tree.splitFocusedPane(direction: .vertical, inheritingFrom: status)) == "/Users/test/second")

        tree.focusedPaneID = first.id
        tree.focusedPaneID = status.id
        #expect(cwd(of: tree.splitFocusedPane(direction: .vertical, inheritingFrom: status)) == "/Users/test/first")
    }

    @Test func unseededFocusHistoryFallsBackToTheFirstTerminalDepthFirst() {
        let tree = SplitTree()
        let only = tree.focusedPane
        only.activeTab?.terminal.configuration.workingDirectory = "/Users/test/only"
        #expect(tree.focusHistory.isEmpty)
        let status = addInertPane(to: tree, splitting: only, kind: .systemMetrics)
        #expect(!tree.focusHistory.contains(only.id))

        let newPane = tree.splitFocusedPane(direction: .vertical, inheritingFrom: status)

        #expect(cwd(of: newPane) == "/Users/test/only")
    }

    @Test func aHiddenTerminalStillCounts() {
        let tree = SplitTree()
        let only = tree.focusedPane
        only.activeTab?.terminal.configuration.workingDirectory = "/Users/test/hidden"
        let status = addInertPane(to: tree, splitting: only, kind: .lmStudioDashboard)
        only.isHidden = true

        let newPane = tree.splitFocusedPane(direction: .vertical, inheritingFrom: status)

        #expect(cwd(of: newPane) == "/Users/test/hidden")
    }

    @Test func aSessionWithOnlyNonTerminalPanesInheritsNothing() {
        let status = PaneRuntime(kind: .systemMetrics, isSessionSelected: false, contentFactory: { _ in nil })
        let tree = SplitTree(root: .leaf(status))

        let newPane = tree.splitFocusedPane(direction: .vertical, inheritingFrom: status)

        #expect(newPane.kind == .terminal)
        #expect(cwd(of: newPane) == nil)
    }

    // MARK: - Typed views from a non-terminal source

    @Test func gitStatusFromGitStatusMonitorsTheSourceDirectory() {
        let tree = SplitTree()
        let git = addGitStatusPane(to: tree, splitting: tree.focusedPane, directoryPath: "/Users/test/Developer/Repo")

        let second = tree.splitPane(id: git.id, direction: .vertical, kind: .gitStatus, isSessionSelected: false)

        #expect((second?.content as? GitStatusPaneContent)?.directoryPath == "/Users/test/Developer/Repo")
    }

    @Test func explicitPathWinsOverTheInheritedDirectory() {
        let tree = SplitTree()
        let git = addGitStatusPane(to: tree, splitting: tree.focusedPane, directoryPath: "/Users/test/Developer/Repo")

        let second = tree.splitPane(id: git.id, direction: .vertical, kind: .gitStatus, path: "/Users/test/explicit", isSessionSelected: false)

        #expect((second?.content as? GitStatusPaneContent)?.directoryPath == "/Users/test/explicit")
    }

    @Test func gitStatusFromSystemMetricsMonitorsTheMostRecentTerminalDirectory() {
        let tree = SplitTree()
        let only = tree.focusedPane
        only.activeTab?.terminal.configuration.workingDirectory = "/Users/test/Developer/Work"
        let status = addInertPane(to: tree, splitting: only, kind: .systemMetrics)

        let git = tree.splitPane(id: status.id, direction: .vertical, kind: .gitStatus, isSessionSelected: false)

        #expect((git?.content as? GitStatusPaneContent)?.directoryPath == "/Users/test/Developer/Work")
    }

    @Test func processStatusFromANonTerminalSourceFollowsTheResolvedTerminalTab() {
        let tree = SplitTree()
        let only = tree.focusedPane
        let status = addInertPane(to: tree, splitting: only, kind: .systemMetrics)

        let process = tree.splitPane(id: status.id, direction: .vertical, kind: .processStatus, isSessionSelected: false)

        #expect((process?.content as? ProcessStatusPaneContent)?.target == .followingTab(only.activeTabID))
    }

    @Test func processStatusFromProcessStatusFollowsTheSameTab() {
        let tree = SplitTree()
        let first = tree.focusedPane
        let second = tree.splitFocusedPane(direction: .horizontal, inheritingFrom: first)
        tree.focusedPaneID = first.id
        tree.focusedPaneID = second.id
        let process = addProcessStatusPane(to: tree, splitting: second, processTarget: .followingTab(first.activeTabID))

        let again = tree.splitPane(id: process.id, direction: .vertical, kind: .processStatus, isSessionSelected: false)

        #expect((again?.content as? ProcessStatusPaneContent)?.target == .followingTab(first.activeTabID))
    }

    @Test func processStatusFromANonTerminalSourceWithNoTerminalHasNoTarget() {
        let status = PaneRuntime(kind: .systemMetrics, isSessionSelected: false, contentFactory: { _ in nil })
        let tree = SplitTree(root: .leaf(status))

        let process = tree.splitPane(id: status.id, direction: .vertical, kind: .processStatus, isSessionSelected: false)

        let content = process?.content as? ProcessStatusPaneContent
        #expect(content != nil)
        #expect(content?.target == nil)
    }

    @Test func processStatusFromATerminalSourceStillFollowsItsActiveTab() {
        let tree = SplitTree()
        let source = tree.focusedPane

        let process = tree.splitPane(id: source.id, direction: .vertical, kind: .processStatus, isSessionSelected: false)

        #expect((process?.content as? ProcessStatusPaneContent)?.target == .followingTab(source.activeTabID))
    }

    @Test func processStatusWithPidStillPins() {
        let tree = SplitTree()
        let status = addInertPane(to: tree, splitting: tree.focusedPane, kind: .systemMetrics)

        let process = tree.splitPane(id: status.id, direction: .vertical, kind: .processStatus, processStatusPid: 4242, isSessionSelected: false)

        #expect((process?.content as? ProcessStatusPaneContent)?.target == .pinned(4242))
    }

    // MARK: - Process Status target carry-through

    @Test func processStatusFromAPinnedProcessStatusStaysPinned() {
        let tree = SplitTree()
        let source = addProcessStatusPane(to: tree, splitting: tree.focusedPane, processTarget: .pinned(7))

        let again = tree.splitPane(id: source.id, direction: .vertical, kind: .processStatus, isSessionSelected: false)

        #expect((again?.content as? ProcessStatusPaneContent)?.target == .pinned(7))
    }

    @Test func processStatusFromAFollowingNameProcessStatusKeepsTheName() {
        let tree = SplitTree()
        let source = addProcessStatusPane(to: tree, splitting: tree.focusedPane, processTarget: .followingName("x"))

        let again = tree.splitPane(id: source.id, direction: .vertical, kind: .processStatus, isSessionSelected: false)

        #expect((again?.content as? ProcessStatusPaneContent)?.target == .followingName("x"))
    }

    @Test func processStatusFromAFollowingTabProcessStatusStillFollowsThatTab() {
        let tree = SplitTree()
        let first = tree.focusedPane
        let second = tree.splitFocusedPane(direction: .horizontal, inheritingFrom: first)
        tree.focusedPaneID = first.id
        tree.focusedPaneID = second.id
        let source = addProcessStatusPane(to: tree, splitting: second, processTarget: .followingTab(first.activeTabID))

        let again = tree.splitPane(id: source.id, direction: .vertical, kind: .processStatus, isSessionSelected: false)

        #expect(first.activeTabID != second.activeTabID)
        #expect((again?.content as? ProcessStatusPaneContent)?.target == .followingTab(first.activeTabID))
    }

    @Test func processStatusPidOverridesTheSourcesCarriedTarget() {
        let tree = SplitTree()
        let source = addProcessStatusPane(to: tree, splitting: tree.focusedPane, processTarget: .followingName("x"))

        let again = tree.splitPane(id: source.id, direction: .vertical, kind: .processStatus, processStatusPid: 99, isSessionSelected: false)

        #expect((again?.content as? ProcessStatusPaneContent)?.target == .pinned(99))
    }

    @Test func terminalSplitFromAPinnedProcessStatusStillResolvesItsDirectoryThroughTheMostRecentTerminal() {
        let tree = SplitTree()
        let terminal = tree.focusedPane
        terminal.activeTab?.terminal.configuration.workingDirectory = "/Users/test/elsewhere"
        let source = addProcessStatusPane(to: tree, splitting: terminal, processTarget: .pinned(7))

        let newPane = tree.splitPane(id: source.id, direction: .vertical, isSessionSelected: false)

        #expect(cwd(of: newPane) == "/Users/test/elsewhere")
    }

    @Test func inheritedSourceCarriesAPinnedOrNamedTargetAlongsideTheFallbackTab() {
        let tree = SplitTree()
        let terminal = tree.focusedPane
        let pinned = addProcessStatusPane(to: tree, splitting: terminal, processTarget: .pinned(7))
        let named = addProcessStatusPane(to: tree, splitting: terminal, processTarget: .followingName("x"))
        let lookup: (UUID) -> TabRuntime? = { _ in nil }

        let fromPinned = SplitTree.inheritedSource(from: pinned, in: tree, tabLookup: lookup)
        let fromNamed = SplitTree.inheritedSource(from: named, in: tree, tabLookup: lookup)
        let fromTerminal = SplitTree.inheritedSource(from: terminal, in: tree, tabLookup: lookup)

        #expect(fromPinned.processTarget == .pinned(7))
        #expect(fromPinned.followedTabID == terminal.activeTabID)
        #expect(fromNamed.processTarget == .followingName("x"))
        #expect(fromTerminal.processTarget == nil)
    }

    // MARK: - Entry points

    @Test func windowRuntimeCreatePaneFromAGitStatusPaneInheritsItsDirectory() {
        let store = AppStateStore()
        let window = store.windows[0]
        let tree = window.selectedSession!.tree
        let git = addGitStatusPane(to: tree, splitting: tree.focusedPane, directoryPath: "/Users/test/Developer/Repo")
        #expect(tree.focusedPaneID == git.id)

        let newPane = window.createPane(kind: .terminal)

        #expect(cwd(of: newPane) == "/Users/test/Developer/Repo")
    }

    @Test func windowRuntimeCreatePaneFromAMetricsPaneUsesTheTerminalDirectory() {
        let store = AppStateStore()
        let window = store.windows[0]
        let tree = window.selectedSession!.tree
        tree.focusedPane.activeTab?.terminal.configuration.workingDirectory = "/Users/test/Developer/Work"
        addInertPane(to: tree, splitting: tree.focusedPane, kind: .systemMetrics)

        let newPane = window.createPane(kind: .terminal)

        #expect(cwd(of: newPane) == "/Users/test/Developer/Work")
    }

    @Test func appStateStoreSplitPaneFromAGitStatusPaneInheritsItsDirectory() {
        let store = AppStateStore()
        let tree = store.sessions[0].tree
        let git = addGitStatusPane(to: tree, splitting: tree.focusedPane, directoryPath: "/Users/test/Developer/Repo")

        let newPaneID = store.splitPane(id: git.id, direction: .horizontal)

        let newPane = tree.allPanes.first { $0.id == newPaneID }
        #expect(newPane?.kind == .terminal)
        #expect(cwd(of: newPane) == "/Users/test/Developer/Repo")
    }
}
