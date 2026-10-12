// SessionProjectCaptureTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

private let noContent: @MainActor (PaneContentKind) -> (any PaneContentLifecycle)? = { _ in nil }
private let home = "/Users/test"
private let root = "/Users/test/proj"

@MainActor
private func tab(_ cwd: String? = nil, title: String? = nil) -> TabRuntime {
    TabRuntime(titleOverride: title, workingDirectory: cwd)
}

@MainActor
private func pane(_ kind: PaneContentKind = .terminal, tabs: [TabRuntime]? = nil, hidden: Bool = false) -> PaneRuntime {
    PaneRuntime(tabs: tabs, isHidden: hidden, kind: kind, contentFactory: noContent)
}

private func split(_ direction: SplitDirection, _ ratio: Double, _ left: SplitTreeNode, _ right: SplitTreeNode) -> SplitTreeNode {
    .split(id: UUID(), direction: direction, ratio: ratio, left: left, right: right)
}

private func split(_ direction: SplitDirection, _ left: SplitTreeNode, _ right: SplitTreeNode) -> SplitTreeNode {
    split(direction, 0.5, left, right)
}

@MainActor
private func session(_ node: SplitTreeNode, title: String = "Session 1", colorIndex: Int = 0) -> SessionRuntime {
    SessionRuntime(title: title, tree: SplitTree(root: node), colorIndex: colorIndex)
}

@MainActor
private func capture(_ node: SplitTreeNode, root requested: String? = nil, git: @escaping @MainActor (PaneRuntime) -> String? = { _ in nil }) -> SessionProjectCapture {
    SessionProjectCapture.capture(session: session(node), root: requested, homeDirectory: home, gitDirectory: git)
}

@MainActor
private func terminals(_ count: Int, cwd: String = root) -> [SplitTreeNode] {
    (0..<count).map { _ in .leaf(pane(tabs: [tab(cwd)])) }
}

@MainActor
struct SessionProjectCaptureTopologyTests {
    @Test(arguments: PaneLayout.allCases.filter { $0 != .twoByTwoGrid })
    func aSessionArrangedWithAPresetCapturesAsThatPreset(layout: PaneLayout) {
        let tree = SplitTree()
        layout.apply(to: tree)
        let session = SessionRuntime(title: "x", tree: tree)

        let captured = SessionProjectCapture.capture(session: session, homeDirectory: home)

        #expect(captured.layout.preset == layout)
        #expect(captured.layout.paneCount == layout.paneCount)
        #expect(captured.layout.root == ProjectLayout.preset(layout).root)
    }

    @Test func aHandBuiltRowMajorGridIsTheGridPreset() {
        let top = split(.horizontal, terminals(2)[0], terminals(2)[1])
        let bottom = split(.horizontal, terminals(2)[0], terminals(2)[1])
        let captured = capture(split(.vertical, top, bottom))

        #expect(captured.layout.preset == .twoByTwoGrid)
        #expect(captured.layout.root == ProjectLayout.preset(.twoByTwoGrid).root)
    }

    @Test func theGridThatPaneLayoutApplyBuildsIsTheGridPresetInRowMajorSlotOrder() {
        let tree = SplitTree()
        PaneLayout.twoByTwoGrid.apply(to: tree)
        let session = SessionRuntime(title: "x", tree: tree)
        for (index, pane) in tree.allPanes.enumerated() {
            pane.tabs[0].terminal.configuration.workingDirectory = "\(root)/p\(index)"
        }
        // allPanes is column-major here: top-left, bottom-left, top-right, bottom-right.
        let captured = SessionProjectCapture.capture(session: session, root: root, homeDirectory: home)

        #expect(captured.layout.preset == .twoByTwoGrid)
        #expect(captured.layout.root == ProjectLayout.preset(.twoByTwoGrid).root.withPanes(captured.layout.panes))
        #expect(captured.layout.panes.map { $0.tabs[0].workingDirectory } == ["p0", "p2", "p1", "p3"])
    }

    @Test func columnMajorGridNotesFollowTheirPanesToTheirNewSlots() {
        let tree = SplitTree()
        PaneLayout.twoByTwoGrid.apply(to: tree)
        let session = SessionRuntime(title: "x", tree: tree)
        tree.allPanes[1].tabs[0].terminal.configuration.workingDirectory = "/elsewhere"
        let captured = SessionProjectCapture.capture(session: session, root: root, homeDirectory: home)

        #expect(captured.notes.keys.contains(.tabDirectory(slot: 2, tab: 0)))
        #expect(!captured.notes.keys.contains(.tabDirectory(slot: 1, tab: 0)))
    }

    @Test func aDifferentFourPaneNestIsStillCustom() {
        let leaf = terminals(4)
        let captured = capture(split(.horizontal, split(.vertical, leaf[0], leaf[1]), split(.vertical, leaf[2], split(.vertical, leaf[3], terminals(1)[0]))))
        let four = capture(split(.vertical, split(.horizontal, leaf[0], leaf[1]), split(.horizontal, leaf[2], split(.vertical, leaf[3], terminals(1)[0]))))

        #expect(captured.layout.preset == nil)
        #expect(four.layout.preset == nil)
        let mixed = capture(split(.horizontal, split(.vertical, terminals(1)[0], terminals(1)[0]), split(.horizontal, terminals(1)[0], terminals(1)[0])))
        #expect(mixed.layout.preset == nil)
    }

    @Test func aTreeThreeLevelsDeepIsCustomAndKeepsItsTopology() {
        let a = terminals(1)[0], b = terminals(1)[0], c = terminals(1)[0], d = terminals(1)[0]
        let captured = capture(split(.horizontal, split(.vertical, a, split(.horizontal, b, c)), d))

        #expect(captured.layout.preset == nil)
        let leaf = ProjectLayoutNode.pane(.terminal())
        #expect(captured.layout.root == .split(direction: .horizontal, children: [
            .split(direction: .vertical, children: [leaf, .split(direction: .horizontal, children: [leaf, leaf])]),
            leaf,
        ]))
    }

    @Test func sameDirectionNestingOnEitherSideIsOneNarySplit() {
        let a = terminals(3)
        let rightNested = capture(split(.horizontal, a[0], split(.horizontal, a[1], a[2])))
        let b = terminals(3)
        let leftNested = capture(split(.horizontal, split(.horizontal, b[0], b[1]), b[2]))

        #expect(rightNested.layout.preset == .threeColumns)
        #expect(leftNested.layout.preset == .threeColumns)
        #expect(rightNested.layout.root == leftNested.layout.root)
    }

    @Test func aHandResizedTreeCapturesNoRatio() throws {
        let resized = capture(split(.horizontal, 0.2, split(.vertical, 0.7, terminals(1)[0], terminals(1)[0]), terminals(1)[0]))
        let even = capture(split(.horizontal, 0.5, split(.vertical, 0.5, terminals(1)[0], terminals(1)[0]), terminals(1)[0]))

        #expect(resized.layout == even.layout)
        let json = try String(decoding: JSONEncoder().encode(resized.layout), as: UTF8.self)
        #expect(!json.localizedCaseInsensitiveContains("ratio"))
        #expect(!json.contains("0.2"))
        #expect(!json.contains("0.7"))
    }

    @Test func hiddenPanesAreCapturedAsOrdinarySlots() {
        let captured = capture(split(.horizontal, .leaf(pane(tabs: [tab(root)])), .leaf(pane(tabs: [tab(root + "/src")], hidden: true))))

        #expect(captured.layout.preset == .horizontalSplit)
        #expect(captured.layout.panes.map(\.kind) == [.terminal, .terminal])
        #expect(captured.layout.panes[1].tabs.map(\.workingDirectory) == ["src"])
    }

    @Test func eachPanesKindIsCapturedAndANonTerminalPlaceholderTabIsNot() {
        let tree = split(
            .vertical,
            .leaf(pane(tabs: [tab(root)])),
            split(
                .horizontal,
                .leaf(pane(.gitStatus, tabs: [tab("/elsewhere/placeholder")])),
                split(.horizontal, .leaf(pane(.processStatus)), split(.horizontal, .leaf(pane(.systemMetrics)), .leaf(pane(.lmStudioDashboard))))
            )
        )
        let captured = capture(tree, git: { _ in nil })

        #expect(captured.layout.panes.map(\.kind) == [.terminal, .gitStatus, .processStatus, .systemMetrics, .lmStudioDashboard])
        #expect(captured.layout.panes[1...].allSatisfy { $0.tabs.isEmpty })
        #expect(captured.notes.isEmpty, "a placeholder Tab's folder is never examined")
    }
}

@MainActor
struct SessionProjectCaptureTabTests {
    @Test func aTerminalPaneWithThreeTabsKeepsRootSubdirectoryAndOutsideRoot() {
        let node = SplitTreeNode.leaf(pane(tabs: [tab(root), tab(root + "/src/app"), tab("/Users/test/other")]))
        let captured = capture(node)

        #expect(captured.rootPath == root)
        #expect(captured.layout.panes[0].tabs.map(\.workingDirectory) == [".", "src/app", "."])
        #expect(captured.notes.keys.sorted { "\($0)" < "\($1)" } == [.tabDirectory(slot: 0, tab: 2)])
        #expect(captured.layout.panes[0].tabs.allSatisfy { $0.startupCommand == nil })
    }

    @Test func aTrailingSlashAndDotComponentsDoNotMatter() {
        let captured = capture(.leaf(pane(tabs: [tab(root + "/"), tab(root + "/./src/")])))
        #expect(captured.layout.panes[0].tabs.map(\.workingDirectory) == [".", "src"])
    }

    @Test func onlyAUserSetTitleIsCaptured() {
        let node = SplitTreeNode.leaf(pane(tabs: [tab(root, title: "build"), tab(root), tab(root, title: "  "), tab(root, title: " logs ")]))
        let captured = capture(node)
        #expect(captured.layout.panes[0].tabs.map(\.title) == ["build", nil, nil, "logs"])
    }

    @Test func aTabWithNoKnownFolderIsTheRoot() {
        let captured = capture(.leaf(pane(tabs: [tab(root), tab(nil)])))
        #expect(captured.layout.panes[0].tabs.map(\.workingDirectory) == [".", "."])
        #expect(captured.notes.isEmpty)
    }

    @Test func aGitStatusFolderIsStoredRelativeToTheRoot() {
        let git = pane(.gitStatus)
        let captured = capture(split(.horizontal, .leaf(pane(tabs: [tab(root)])), .leaf(git)), git: { _ in root + "/packages/core" })
        #expect(captured.layout.panes[1].repositoryPath == "packages/core")
        #expect(captured.notes.isEmpty)
    }

    @Test func aGitStatusFolderAtTheRootIsTheDefault() {
        let captured = capture(split(.horizontal, .leaf(pane(tabs: [tab(root)])), .leaf(pane(.gitStatus))), git: { _ in root })
        #expect(captured.layout.panes[1].repositoryPath == nil)
    }

    @Test func aGitStatusFolderOutsideTheRootFallsBackAndIsFlagged() {
        let captured = capture(split(.horizontal, .leaf(pane(tabs: [tab(root)])), .leaf(pane(.gitStatus))), git: { _ in "/Users/test/other-repo" })
        #expect(captured.layout.panes[1].repositoryPath == nil)
        #expect(captured.notes[.repository(slot: 1)] != nil)
    }

    @Test func aRequestedRootMakesTabsRelativeToItInsteadOfTheAnchor() {
        let node = SplitTreeNode.leaf(pane(tabs: [tab(root), tab(root + "/src")]))
        let captured = capture(node, root: root + "/src")

        #expect(captured.rootPath == root + "/src")
        #expect(captured.layout.panes[0].tabs.map(\.workingDirectory) == [".", "."])
        #expect(captured.notes.keys.contains(.tabDirectory(slot: 0, tab: 0)), "the first Tab is outside the requested root")
        #expect(!captured.notes.keys.contains(.tabDirectory(slot: 0, tab: 1)))
    }

    @Test func symlinkedSpellingsOfOneFolderCompareEqual() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-capture-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("src"), withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(SessionProjectCapture.relativePath(of: real.appendingPathComponent("src").path, in: link.path) == "src")
        #expect(SessionProjectCapture.relativePath(of: link.path, in: real.path) == ".")
        #expect(SessionProjectCapture.relativePath(of: base.path, in: real.path) == nil)
    }
}

@MainActor
struct SessionProjectCaptureRootTests {
    @Test func theRootIsTheAnchorTabsFolder() {
        let captured = capture(split(.horizontal, .leaf(pane(tabs: [tab(root + "/a"), tab("/x/y")])), .leaf(pane(tabs: [tab("/q")]))))
        #expect(captured.rootPath == root + "/a")
        #expect(!captured.rootIsFallback)
    }

    @Test func aNonTerminalAnchorFallsBackToTheFirstTerminalTabWithAFolder() {
        let node = split(.horizontal, .leaf(pane(.systemMetrics, tabs: [tab("/placeholder")])), split(.horizontal, .leaf(pane(tabs: [tab(nil)])), .leaf(pane(tabs: [tab(nil), tab(root)]))))
        let captured = capture(node)

        #expect(captured.rootPath == root)
        #expect(captured.layout.panes.map(\.kind) == [.systemMetrics, .terminal, .terminal])
        #expect(captured.layout.panes[2].tabs.map(\.workingDirectory) == [".", "."])
    }

    @Test func aSessionWithNoKnownFolderUsesHomeAndSaysSo() {
        let captured = capture(.leaf(pane(tabs: [tab(nil)])))
        #expect(captured.rootPath == home)
        #expect(captured.rootIsFallback)

        let draft = captured.newDraft(name: "N", existingNames: [])
        #expect(draft.rootNeedsChoosing)
    }

    @Test func aSessionWithOnlyNonTerminalPanesUsesHome() {
        let captured = capture(.leaf(pane(.systemMetrics)))
        #expect(captured.rootIsFallback)
        #expect(captured.layout.panes.map(\.kind) == [.systemMetrics])
    }

    @Test func theColorIsTheSessionsCurrentColor() {
        let s = session(.leaf(pane(tabs: [tab(root)])), colorIndex: SessionColor.violet.rawValue)
        #expect(SessionProjectCapture.capture(session: s, homeDirectory: home).color == .violet)
    }

    @Test func capturingChangesNothingInTheSession() {
        let s = session(split(.horizontal, 0.3, .leaf(pane(tabs: [tab(root, title: "t")])), .leaf(pane(tabs: [tab(root + "/src")]))), title: "Keep", colorIndex: 4)
        let before = s.tree.allPanes.map(\.id)
        let first = SessionProjectCapture.capture(session: s, homeDirectory: home)
        let second = SessionProjectCapture.capture(session: s, homeDirectory: home)

        #expect(first == second)
        #expect(s.title == "Keep")
        #expect(s.colorIndex == 4)
        #expect(!s.colorOverride && !s.titleOverride)
        #expect(s.tree.allPanes.map(\.id) == before)
        if case .split(_, _, let ratio, _, _) = s.tree.root { #expect(ratio == 0.3) } else { Issue.record("tree changed shape") }
    }
}

@MainActor
struct SessionProjectCaptureNamingTests {
    @Test func aUserSetTitleIsTheName() {
        let s = session(.leaf(pane(tabs: [tab(root)])), title: "Website")
        let captured = SessionProjectCapture.capture(session: s, homeDirectory: home)
        #expect(SessionProjectCapture.suggestedName(session: s, capture: captured, nameForRoot: { _ in "Resolved" }) == "Website")
    }

    @Test func aDefaultTitleYieldsToTheResolvedRootName() {
        let s = session(.leaf(pane(tabs: [tab(root)])), title: "Session 3")
        let captured = SessionProjectCapture.capture(session: s, homeDirectory: home)
        #expect(SessionProjectCapture.suggestedName(session: s, capture: captured, nameForRoot: { $0 == root ? "Resolved" : nil }) == "Resolved")
    }

    @Test func aPlaceholderRootNeverProvidesAName() {
        let s = session(.leaf(pane(tabs: [tab(nil)])), title: "Session 1")
        let captured = SessionProjectCapture.capture(session: s, homeDirectory: home)
        #expect(SessionProjectCapture.suggestedName(session: s, capture: captured, nameForRoot: { _ in "Home" }) == ProjectEditorViewModel.untitledName)
    }

    @Test func aTakenNameGetsANumber() {
        #expect(SessionProjectCapture.uniqueName("Batty", among: ["Other"]) == "Batty")
        #expect(SessionProjectCapture.uniqueName("Batty", among: ["batty"]) == "Batty 2")
        #expect(SessionProjectCapture.uniqueName("Batty", among: ["Batty", " BATTY 2 "]) == "Batty 3")
    }

    @Test func aNewDraftHasTheRunToggleOffAndTheCaptureNotes() {
        let node = SplitTreeNode.leaf(pane(tabs: [tab(root), tab("/Users/test/other")]))
        let draft = capture(node).newDraft(name: "N", existingNames: [])
        #expect(!draft.runStartupCommandsOnOpen)
        #expect(draft.captureNotes.keys.contains(.tabDirectory(slot: 0, tab: 1)))
        #expect(!draft.rootNeedsChoosing)
        #expect(draft.makeProject().startupCommands.isEmpty)
    }
}

@MainActor
struct SessionProjectUpdateDraftTests {
    private func stored() -> Project {
        let layout = ProjectLayout(
            root: .split(direction: .horizontal, children: [
                .pane(.terminal(tabs: [ProjectTab(title: "old", workingDirectory: "docs", startupCommand: "make"), ProjectTab(workingDirectory: ".", startupCommand: "tail -f log")])),
                .pane(ProjectPane(kind: .gitStatus)),
            ])
        )
        return Project(name: "Stored", rootPath: root, color: .teal, layout: layout, runStartupCommandsOnOpen: true, approvedCommandsHash: "abc")
    }

    @Test func commandsStayWhereTheSlotAndTabStillLineUp() {
        let node = split(.horizontal, .leaf(pane(tabs: [tab(root + "/src"), tab(root), tab(root + "/new")])), .leaf(pane(tabs: [tab(root)])))
        let draft = capture(node, root: root).updateDraft(of: stored())
        let panes = draft.makeProject().layout.panes

        #expect(panes[0].tabs.map(\.workingDirectory) == ["src", ".", "new"])
        #expect(panes[0].tabs.map(\.startupCommand) == ["make", "tail -f log", nil])
        #expect(panes[0].tabs.map(\.title) == [nil, nil, nil], "titles come from the Session, not the old Project")
        #expect(panes[1].kind == .terminal, "the slot's kind follows the Session")
        #expect(panes[1].tabs.map(\.startupCommand) == [nil], "a slot whose kind changed keeps no commands")
    }

    @Test func nameRootColorToggleAndApprovalCarryOver() {
        let project = stored()
        let draft = capture(.leaf(pane(tabs: [tab(root)])), root: root).updateDraft(of: project)

        #expect(draft.id == project.id)
        #expect(draft.name == "Stored")
        #expect(draft.rootPath == root)
        #expect(draft.color == .teal)
        #expect(draft.runStartupCommandsOnOpen)
        #expect(draft.approvedCommandsHash == "abc")
        #expect(draft.layout.preset == .singlePane)
    }
}
