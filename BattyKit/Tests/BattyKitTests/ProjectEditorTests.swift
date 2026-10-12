// ProjectEditorTests.swift

import AppKit
import BattyXPCCore
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import BattyKit

@MainActor
private final class EditorFixture {
    let base: URL
    let root: URL
    let projectsFile: URL
    let cacheFile: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-editor-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        projectsFile = base.appendingPathComponent("projects.json")
        cacheFile = base.appendingPathComponent("cache.json")
        for sub in ["", "src", "docs", "repo", "web/app"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Data("not a folder".utf8).write(to: base.appendingPathComponent("file.txt"))
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    var filePath: String { base.appendingPathComponent("file.txt").path }

    func store() -> ProjectStore { ProjectStore(fileURL: projectsFile) }

    func reloaded() -> ProjectStore { ProjectStore(fileURL: projectsFile) }

    /// Deliberately non-default everywhere: color, layout, kinds, Tabs,
    /// toggle, approval hash and date.
    func richProject(name: String = "Rich", approved: String? = nil) -> Project {
        var layout = ProjectLayout.preset(.mainLeftTwoRight, kinds: [.terminal, .gitStatus, .terminal])
        layout.root = layout.root.withPanes([
            .terminal(tabs: [
                ProjectTab(title: "build", workingDirectory: "src", startupCommand: "./build.sh"),
                ProjectTab(title: "shell", workingDirectory: ".", startupCommand: nil),
            ]),
            ProjectPane(kind: .gitStatus, repositoryPath: "repo"),
            .terminal(tabs: [ProjectTab(title: "claude", workingDirectory: "docs", startupCommand: "claude")]),
        ])
        return Project(
            name: name, rootPath: root.path, color: .violet, layout: layout,
            runStartupCommandsOnOpen: false, approvedCommandsHash: approved,
            lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func simpleProject(name: String) -> Project {
        Project(name: name, rootPath: root.path, color: .teal)
    }

    func model(
        store: ProjectStore,
        selecting id: UUID? = nil,
        defaultRoot: String? = nil,
        suggestion: String? = nil
    ) -> ProjectEditorViewModel {
        ProjectEditorViewModel(
            store: store,
            initialSelection: id,
            defaultRoot: { defaultRoot },
            suggestName: { _ in suggestion }
        )
    }
}

// MARK: - Geometry

@MainActor
struct ProjectLayoutEditingTests {
    @Test(arguments: PaneLayout.allCases)
    func presetTopologyFramesMatchTheHandWrittenThumbnailGeometry(layout: PaneLayout) {
        let derived = ProjectLayout.preset(layout).slotFrames
        let handWritten = layout.layoutPanes.map(\.frame)
        #expect(derived.count == handWritten.count)
        for (a, b) in zip(derived, handWritten) {
            #expect(abs(a.minX - b.minX) < 0.0001 && abs(a.minY - b.minY) < 0.0001)
            #expect(abs(a.width - b.width) < 0.0001 && abs(a.height - b.height) < 0.0001)
        }
    }

    @Test func nestedCustomTopologyGetsEqualSharesOfItsParent() {
        let leaf = ProjectLayoutNode.pane(.terminal())
        let node = ProjectLayoutNode.split(direction: .horizontal, children: [
            leaf,
            .split(direction: .vertical, children: [leaf, leaf, leaf]),
        ])
        let frames = node.slotFrames
        #expect(frames.count == 4)
        #expect(frames[0] == CGRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(abs(frames[2].minY - 1.0 / 3.0) < 0.0001)
        #expect(abs(frames[3].height - 1.0 / 3.0) < 0.0001)
        #expect(frames[3].minX == 0.5)
    }

    @Test func arrowNavigationFollowsGeometry() {
        let frames = ProjectLayout.preset(.mainTopTwoBottom).slotFrames
        #expect(ProjectLayoutGeometry.neighbor(of: 0, in: frames, toward: .down) == 1)
        #expect(ProjectLayoutGeometry.neighbor(of: 1, in: frames, toward: .right) == 2)
        #expect(ProjectLayoutGeometry.neighbor(of: 2, in: frames, toward: .left) == 1)
        #expect(ProjectLayoutGeometry.neighbor(of: 1, in: frames, toward: .up) == 0)
        #expect(ProjectLayoutGeometry.neighbor(of: 2, in: frames, toward: .up) == 0)
        #expect(ProjectLayoutGeometry.neighbor(of: 0, in: frames, toward: .up) == nil)
        #expect(ProjectLayoutGeometry.neighbor(of: 0, in: frames, toward: .left) == nil)
        #expect(ProjectLayoutGeometry.neighbor(of: 2, in: frames, toward: .right) == nil)
        #expect(ProjectLayoutGeometry.neighbor(of: 9, in: frames, toward: .left) == nil)
    }

    @Test func positionDescriptions() {
        let tops = ProjectLayout.preset(.mainTopTwoBottom).slotFrames.map(ProjectLayoutGeometry.positionDescription(of:))
        #expect(tops == ["Top", "Bottom left", "Bottom right"])
        #expect(ProjectLayoutGeometry.positionDescription(of: ProjectLayout.preset(.singlePane).slotFrames[0]) == "Whole window")
        let rows = ProjectLayout.preset(.threeRows).slotFrames.map(ProjectLayoutGeometry.positionDescription(of:))
        #expect(rows == ["Top", "Middle", "Bottom"])
        let columns = ProjectLayout.preset(.threeColumns).slotFrames.map(ProjectLayoutGeometry.positionDescription(of:))
        #expect(columns == ["Left", "Middle", "Right"])
    }

    @Test func withPanesKeepsStructureAndReplacesBySlot() {
        let layout = ProjectLayout.preset(.twoByTwoGrid)
        let replaced = layout.root.withPanes([.terminal(tabs: [ProjectTab(title: "one")]), ProjectPane(kind: .systemMetrics)])
        #expect(replaced.panes[0].tabs[0].title == "one")
        #expect(replaced.panes[1].kind == .systemMetrics)
        #expect(replaced.panes[2] == layout.root.panes[2])
        #expect(replaced.slotFrames == layout.root.slotFrames)
    }
}

// MARK: - View model: save, cancel, open

@MainActor
struct ProjectEditorSaveTests {
    @Test func saveWritesExactlyTheEditedProjectAndNothingBefore() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let target = fixture.richProject(name: "Rich", approved: "approved-hash")
        let neighbour = fixture.simpleProject(name: "Neighbour")
        try store.upsert(target)
        try store.upsert(neighbour)
        let before = try Data(contentsOf: fixture.projectsFile)

        let model = fixture.model(store: store, selecting: target.id)
        model.setName("Renamed")
        model.setColor(.cyan)
        model.setRunStartupCommandsOnOpen(true)
        model.selectSlot(0)
        model.setTabCommand(0, "./build.sh --fast")
        model.addTab()
        model.setTabTitle(2, "logs")
        model.selectSlot(1)
        model.setRepositoryPath("docs")

        #expect(model.isDirty)
        #expect(try Data(contentsOf: fixture.projectsFile) == before)
        #expect(fixture.reloaded().project(id: target.id) == target)

        let saved = try #require(model.save())

        var expected = target
        expected.name = "Renamed"
        expected.color = .cyan
        expected.runStartupCommandsOnOpen = true
        expected.layout.root = expected.layout.root.mappingPanes { slot, pane in
            var edited = pane
            if slot == 0 {
                edited.tabs[0].startupCommand = "./build.sh --fast"
                edited.tabs.append(ProjectTab(title: "logs"))
            }
            if slot == 1 { edited.repositoryPath = "docs" }
            return edited
        }
        #expect(saved == expected)
        let reloaded = fixture.reloaded()
        #expect(reloaded.project(id: target.id) == expected)
        #expect(reloaded.project(id: neighbour.id) == neighbour)
        #expect(reloaded.projects.map(\.id) == [target.id, neighbour.id])
        #expect(reloaded.project(id: target.id)?.approvedCommandsHash == "approved-hash")
        #expect(reloaded.project(id: target.id)?.lastOpenedAt == target.lastOpenedAt)
        #expect(!model.isDirty)
    }

    @Test func saveKeepsTheApprovalAndOpenDateWrittenAfterTheEditorLoaded() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let project = fixture.richProject(name: "Rich", approved: "old-hash")
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)

        var approvedElsewhere = project
        approvedElsewhere.approvedCommandsHash = "new-hash"
        approvedElsewhere.lastOpenedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try store.upsert(approvedElsewhere)

        model.setColor(.cyan)
        let saved = try #require(model.save())

        #expect(saved.approvedCommandsHash == "new-hash")
        #expect(saved.lastOpenedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(saved.color == .cyan)
        let reloaded = try #require(fixture.reloaded().project(id: project.id))
        #expect(reloaded.approvedCommandsHash == "new-hash")
        #expect(reloaded.lastOpenedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func cancelWritesNothingAndClosesTheWindow() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let project = fixture.richProject()
        try store.upsert(project)
        let before = try Data(contentsOf: fixture.projectsFile)

        let model = fixture.model(store: store, selecting: project.id)
        var closed = 0
        model.closeWindow = { closed += 1 }
        model.setName("Scratch")
        model.setTabCommand(0, "rm -rf nothing")
        #expect(model.isDirty)

        model.cancel()

        #expect(closed == 1)
        #expect(try Data(contentsOf: fixture.projectsFile) == before)
        #expect(fixture.reloaded().project(id: project.id) == project)
        #expect(model.draft?.name == "Rich")
    }

    @Test func cancelOnANewProjectLeavesNoFile() throws {
        let fixture = try EditorFixture()
        let model = fixture.model(store: fixture.store(), defaultRoot: fixture.root.path, suggestion: "Fresh")
        model.requestNewProject()
        #expect(model.isNewDraft)
        model.cancel()
        #expect(!FileManager.default.fileExists(atPath: fixture.projectsFile.path))
    }

    @Test func saveAndOpenSavesThenClosesThenOpensThroughTheSeam() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let project = fixture.richProject()
        try store.upsert(project)

        let model = fixture.model(store: store, selecting: project.id)
        var events: [String] = []
        var storedNameWhenOpened: String?
        model.closeWindow = { events.append("close") }
        model.openProject = { id in
            events.append("open:\(id == project.id)")
            storedNameWhenOpened = store.project(id: id)?.name
        }
        model.setName("Opened")

        #expect(model.saveAndOpen())
        #expect(events == ["close", "open:true"])
        #expect(storedNameWhenOpened == "Opened")
        #expect(fixture.reloaded().project(id: project.id)?.name == "Opened")
    }

    @Test func saveAndOpenDoesNothingWhenTheDraftIsInvalid() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let project = fixture.richProject()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)
        var events: [String] = []
        model.closeWindow = { events.append("close") }
        model.openProject = { _ in events.append("open") }
        model.setName("   ")

        #expect(!model.canSaveAndOpen)
        #expect(!model.saveAndOpen())
        #expect(events.isEmpty)
        #expect(fixture.reloaded().project(id: project.id) == project)
        #expect(model.saveError != nil)
    }

    @Test func savingAnEditedCommandKeepsTheApprovalHashSoRevertingDoesNotReprompt() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        var project = fixture.richProject()
        project.runStartupCommandsOnOpen = true
        project.approvedCommandsHash = project.startupCommandsHash
        try store.upsert(project)
        let approved = project.startupCommandsHash
        #expect(ProjectStartupTrust.decide(project) == .runWithoutPrompt)

        let model = fixture.model(store: store, selecting: project.id)
        model.selectSlot(0)
        model.setTabCommand(0, "./other.sh")
        let edited = try #require(model.save())
        #expect(edited.approvedCommandsHash == approved)
        #expect(edited.startupCommandsHash != approved)
        #expect(ProjectStartupTrust.decide(edited) == .prompt)

        model.setTabCommand(0, "./build.sh")
        let reverted = try #require(model.save())
        #expect(reverted.approvedCommandsHash == approved)
        #expect(reverted.startupCommandsHash == approved)
        #expect(ProjectStartupTrust.decide(reverted) == .runWithoutPrompt)
    }

    @Test func aNameTakenElsewhereWhileEditingIsCaughtBeforeSaving() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let first = fixture.simpleProject(name: "Alpha")
        try store.upsert(first)
        let model = fixture.model(store: store, defaultRoot: fixture.root.path, suggestion: "Beta")
        model.requestNewProject()
        try store.upsert(fixture.simpleProject(name: "beta"))

        #expect(model.save() == nil)
        #expect(model.saveError != nil)
        #expect(store.projects.count == 2)
    }

    @Test func storeErrorsMapToMessages() {
        #expect(ProjectEditorViewModel.message(for: .emptyName).isEmpty == false)
        #expect(ProjectEditorViewModel.message(for: .duplicateName("X")).contains("X"))
        #expect(ProjectEditorViewModel.message(for: .noFileURL).isEmpty == false)
    }
}

// MARK: - View model: validation

@MainActor
struct ProjectEditorValidationTests {
    @Test func nameMustBeNonEmptyAndUniqueIgnoringCase() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        try store.upsert(fixture.simpleProject(name: "Alpha"))
        let other = fixture.simpleProject(name: "Other")
        try store.upsert(other)
        let model = fixture.model(store: store, selecting: other.id)

        model.setName("")
        #expect(model.validationIssues[.name] != nil)
        model.setName("   ")
        #expect(model.validationIssues[.name] != nil)
        model.setName("ALPHA")
        #expect(model.validationIssues[.name]?.contains("Alpha") == true)
        #expect(!model.canSave)
        model.setName("Other")
        #expect(model.validationIssues[.name] == nil)
        model.setName("Gamma")
        #expect(model.validationIssues.isEmpty)
    }

    @Test func rootMustExistAndBeADirectory() throws {
        let fixture = try EditorFixture()
        let project = fixture.simpleProject(name: "Alpha")
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)

        model.setRootPath("")
        #expect(model.validationIssues[.root] != nil)
        model.setRootPath("relative/path")
        #expect(model.validationIssues[.root] != nil)
        model.setRootPath(fixture.root.appendingPathComponent("missing").path)
        #expect(model.validationIssues[.root] != nil)
        model.setRootPath(fixture.filePath)
        #expect(model.validationIssues[.root] != nil)
        model.setRootPath(fixture.root.path)
        #expect(model.validationIssues[.root] == nil)
        model.setRootPath(fixture.root.path + "/src/..")
        #expect(model.validationIssues[.root] == nil)
        #expect(model.draft?.makeProject().rootPath == fixture.root.path)
    }

    @Test func pathsThatEscapeTheRootAreErrorsWhileMissingFoldersAreWarnings() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)
        model.selectSlot(0)

        model.setTabDirectory(0, "../outside")
        #expect(model.validationIssues[.tabDirectory(slot: 0, tab: 0)] != nil)
        model.setTabDirectory(0, "/etc")
        #expect(model.validationIssues[.tabDirectory(slot: 0, tab: 0)] != nil)
        model.setTabDirectory(0, "src/../../x")
        #expect(model.validationIssues[.tabDirectory(slot: 0, tab: 0)] != nil)
        #expect(!model.canSaveAndOpen)

        model.setTabDirectory(0, "not/created/yet")
        #expect(model.validationIssues[.tabDirectory(slot: 0, tab: 0)] == nil)
        #expect(model.validationWarnings[.tabDirectory(slot: 0, tab: 0)] != nil)
        #expect(model.isValid)

        model.setTabDirectory(0, fixture.root.path + "/web/app")
        #expect(model.validationIssues.isEmpty)
        #expect(model.validationWarnings.isEmpty)

        model.selectSlot(1)
        model.setRepositoryPath("../elsewhere")
        #expect(model.validationIssues[.repository(slot: 1)] != nil)
        model.setRepositoryPath("repo")
        #expect(model.validationIssues[.repository(slot: 1)] == nil)
    }

    @Test func commandsThatDeliveryWouldAlterAreRefused() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)
        model.selectSlot(0)

        model.setTabCommand(0, "echo \u{1B}[31mred")
        #expect(model.validationIssues[.tabCommand(slot: 0, tab: 0)] != nil)
        model.setTabCommand(0, "echo \u{202E}evil")
        #expect(model.validationIssues[.tabCommand(slot: 0, tab: 0)] != nil)
        model.setTabCommand(0, "echo hi")
        #expect(model.validationIssues[.tabCommand(slot: 0, tab: 0)] == nil)
        model.setTabCommand(0, "echo one\necho two")
        #expect(model.validationIssues[.tabCommand(slot: 0, tab: 0)] == nil)
        model.setTabCommand(0, "echo\twith tab")
        #expect(model.validationIssues[.tabCommand(slot: 0, tab: 0)] == nil)
    }

    @Test func invalidDraftCannotBeSaved() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let before = try Data(contentsOf: fixture.projectsFile)
        let model = fixture.model(store: store, selecting: project.id)
        model.setRootPath(fixture.root.appendingPathComponent("gone").path)

        #expect(!model.canSave)
        #expect(model.save() == nil)
        #expect(try Data(contentsOf: fixture.projectsFile) == before)
    }

    @Test func blankFieldsNormalizeOnSave() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)
        model.selectSlot(0)
        model.setTabTitle(0, "   ")
        model.setTabDirectory(0, "  ")
        model.setTabCommand(0, "  ")
        model.setName("  Padded  ")

        let saved = try #require(model.save())
        let tab = try #require(saved.layout.panes.first?.tabs.first)
        #expect(saved.name == "Padded")
        #expect(tab.title == nil)
        #expect(tab.workingDirectory == ".")
        #expect(tab.startupCommand == nil)
    }

    @Test func tildeInTheRootExpands() {
        #expect(ProjectDraft.normalizedRoot("~/Developer") == NSHomeDirectory() + "/Developer")
        #expect(ProjectDraft.normalizedRoot("  ") == "")
    }
}

// MARK: - View model: dirty, navigation, selection

@MainActor
struct ProjectEditorNavigationTests {
    @Test func dirtyTracksNormalizedChanges() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)

        #expect(!model.isDirty)
        model.setName("Rich ")
        #expect(!model.isDirty)
        model.setColor(.red)
        #expect(model.isDirty)
        model.setColor(.violet)
        #expect(!model.isDirty)
    }

    @Test func switchingProjectsWithUnsavedChangesAsksFirst() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let first = fixture.richProject(name: "First")
        let second = fixture.simpleProject(name: "Second")
        try store.upsert(first)
        try store.upsert(second)
        let model = fixture.model(store: store, selecting: first.id)
        model.setName("First edited")

        model.requestSelect(second.id)
        #expect(model.pendingNavigation == .select(second.id))
        #expect(model.selectedID == first.id)
        #expect(model.draft?.name == "First edited")

        model.resolveUnsaved(.cancel)
        #expect(model.pendingNavigation == nil)
        #expect(model.selectedID == first.id)
        #expect(model.draft?.name == "First edited")

        model.requestSelect(second.id)
        model.resolveUnsaved(.discard)
        #expect(model.selectedID == second.id)
        #expect(fixture.reloaded().project(id: first.id)?.name == "First")

        model.requestSelect(first.id)
        #expect(model.selectedID == first.id)
        model.setName("First saved")
        model.requestSelect(second.id)
        model.resolveUnsaved(.save)
        #expect(model.selectedID == second.id)
        #expect(fixture.reloaded().project(id: first.id)?.name == "First saved")
    }

    @Test func savingFromTheQuestionStaysPutWhenTheDraftIsInvalid() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let first = fixture.richProject(name: "First")
        let second = fixture.simpleProject(name: "Second")
        try store.upsert(first)
        try store.upsert(second)
        let model = fixture.model(store: store, selecting: first.id)
        model.setName("")

        model.requestSelect(second.id)
        model.resolveUnsaved(.save)

        #expect(model.pendingNavigation == nil)
        #expect(model.selectedID == first.id)
        #expect(model.draft?.name == "")
        #expect(fixture.reloaded().project(id: first.id)?.name == "First")
    }

    @Test func closingTheWindowWithUnsavedChangesAsksAndDiscardCloses() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let project = fixture.richProject()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)
        var closed = 0
        model.closeWindow = { closed += 1 }
        model.setColor(.red)

        #expect(!model.requestNavigation(.closeWindow))
        #expect(closed == 0)
        model.resolveUnsaved(.discard)
        #expect(closed == 1)
        #expect(fixture.reloaded().project(id: project.id) == project)

        let clean = fixture.model(store: store, selecting: project.id)
        clean.closeWindow = { closed += 1 }
        #expect(clean.requestNavigation(.closeWindow))
        #expect(closed == 2)
    }

    @Test func newProjectFromTheFocusedTabsFolder() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        try store.upsert(fixture.richProject())
        let sub = fixture.root.appendingPathComponent("web/app").path
        let model = fixture.model(store: store, defaultRoot: sub, suggestion: "app")

        model.requestNewProject()

        let draft = try #require(model.draft)
        #expect(model.isNewDraft)
        #expect(draft.rootPath == sub)
        #expect(draft.name == "app")
        #expect(draft.layout.preset == .singlePane)
        #expect(draft.layout.panes.count == 1)
        #expect(draft.layout.panes[0].kind == .terminal)
        #expect(draft.layout.panes[0].tabs == [ProjectTab()])
        #expect(draft.color == SessionColor.allCases[1])
        #expect(model.listEntries.last?.isUnsavedNew == true)
        #expect(fixture.reloaded().projects.count == 1)

        let saved = try #require(model.save())
        #expect(!model.isNewDraft)
        #expect(fixture.reloaded().project(id: saved.id)?.rootPath == sub)
    }

    @Test func newProjectsAreNamedUntitledWhenNoSuggestionIsFreeAndNumberedWhenTaken() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        try store.upsert(fixture.simpleProject(name: "app"))
        let model = fixture.model(store: store, defaultRoot: fixture.root.path, suggestion: "App")

        model.requestNewProject()
        #expect(model.draft?.name == "Untitled Project")
        _ = model.save()
        model.requestNewProject()
        #expect(model.draft?.name == "Untitled Project 2")
    }

    @Test func newProjectWithoutAFocusedTabFallsBackToHome() throws {
        let fixture = try EditorFixture()
        let model = fixture.model(store: fixture.store(), defaultRoot: nil, suggestion: nil)
        model.requestNewProject()
        #expect(model.draft?.rootPath == NSHomeDirectory())
    }

    @Test func choosingARootPrefillsOnlyAnEmptyOrUntitledName() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let model = ProjectEditorViewModel(
            store: store, defaultRoot: { fixture.root.path }, suggestName: { _ in nil })
        model.requestNewProject()
        #expect(model.draft?.name == "Untitled Project")

        let chosen = fixture.root.appendingPathComponent("src")
        let named = ProjectEditorViewModel(store: store, defaultRoot: { fixture.root.path }, suggestName: { _ in "Suggested" })
        named.requestNewProject()
        named.setName("Untitled Project")
        named.applyChosenRoot(chosen)
        #expect(named.draft?.name == "Suggested")
        #expect(named.draft?.rootPath == chosen.path)

        named.setName("")
        named.applyChosenRoot(fixture.root)
        #expect(named.draft?.name == "Suggested")

        named.setName("Untitled Project 3")
        named.applyChosenRoot(chosen)
        #expect(named.draft?.name == "Suggested")

        named.setName("My Own Name")
        named.applyChosenRoot(fixture.root)
        #expect(named.draft?.name == "My Own Name")
    }

    @Test func aNameSuggestedFromTheDefaultFolderYieldsToTheFolderChosenLater() throws {
        let fixture = try EditorFixture()
        let model = ProjectEditorViewModel(
            store: fixture.store(),
            defaultRoot: { fixture.root.path },
            suggestName: { URL(fileURLWithPath: $0).lastPathComponent }
        )
        model.requestNewProject()
        #expect(model.draft?.name == "root")

        model.applyChosenRoot(fixture.root.appendingPathComponent("docs"))
        #expect(model.draft?.name == "docs")
        model.applyChosenRoot(fixture.root.appendingPathComponent("src"))
        #expect(model.draft?.name == "src")

        model.setName("mine")
        model.applyChosenRoot(fixture.root.appendingPathComponent("docs"))
        #expect(model.draft?.name == "mine")
    }

    @Test func writingTheSameNameBackKeepsTheAutoSuggestedMark() throws {
        let fixture = try EditorFixture()
        let model = ProjectEditorViewModel(
            store: fixture.store(),
            defaultRoot: { fixture.root.path },
            suggestName: { URL(fileURLWithPath: $0).lastPathComponent }
        )
        model.requestNewProject()
        model.setName(try #require(model.draft?.name))
        model.applyChosenRoot(fixture.root.appendingPathComponent("docs"))
        #expect(model.draft?.name == "docs")
    }

    @Test func realResolverAndBasenameFallbackSuggestNames() throws {
        let fixture = try EditorFixture()
        #expect(ProjectEditorViewModel.suggestedName(forRoot: fixture.root.appendingPathComponent("docs").path) == "docs")
        try Data("{\"name\":\"widget\"}".utf8).write(to: fixture.root.appendingPathComponent("web/package.json"))
        #expect(ProjectEditorViewModel.suggestedName(forRoot: fixture.root.appendingPathComponent("web").path) == "widget")
    }

    @Test func deletingTheSelectedProjectNeedsConfirmationAndSelectsANeighbour() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let a = fixture.simpleProject(name: "A")
        let b = fixture.richProject(name: "B")
        let c = fixture.simpleProject(name: "C")
        for p in [a, b, c] { try store.upsert(p) }
        let model = fixture.model(store: store, selecting: b.id)

        model.requestDelete(b.id)
        #expect(model.pendingDeletion == b.id)
        #expect(store.projects.count == 3)
        model.cancelDeletion()
        #expect(store.projects.count == 3)

        model.requestDelete(b.id)
        model.confirmDeletion()
        #expect(fixture.reloaded().projects.map(\.id) == [a.id, c.id])
        #expect(model.selectedID == c.id)

        model.requestDelete(c.id)
        model.confirmDeletion()
        #expect(model.selectedID == a.id)
        model.requestDelete(a.id)
        model.confirmDeletion()
        #expect(model.draft == nil)
        #expect(fixture.reloaded().projects.isEmpty)
    }

    @Test func deletingAnUnsavedNewProjectJustDiscardsIt() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let a = fixture.simpleProject(name: "A")
        try store.upsert(a)
        let model = fixture.model(store: store, defaultRoot: fixture.root.path, suggestion: "Fresh")
        model.requestNewProject()
        let newID = try #require(model.selectedID)

        model.requestDelete(newID)

        #expect(model.pendingDeletion == nil)
        #expect(model.selectedID == a.id)
        #expect(store.projects.count == 1)
    }

    @Test func moveUpAndDownReorderTheStoredList() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let a = fixture.simpleProject(name: "A")
        let b = fixture.simpleProject(name: "B")
        let c = fixture.simpleProject(name: "C")
        for p in [a, b, c] { try store.upsert(p) }
        let model = fixture.model(store: store, selecting: a.id)

        #expect(!model.canMoveProject(a.id, by: -1))
        #expect(model.canMoveProject(a.id, by: 1))
        #expect(!model.canMoveProject(c.id, by: 1))
        model.moveProject(a.id, by: 1)
        #expect(fixture.reloaded().projects.map(\.id) == [b.id, a.id, c.id])
        model.moveProject(c.id, by: -1)
        #expect(fixture.reloaded().projects.map(\.id) == [b.id, c.id, a.id])
        model.moveProject(b.id, by: -1)
        #expect(fixture.reloaded().projects.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func savingAnUnchangedProjectDoesNotRewriteTheFile() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let project = fixture.richProject()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)
        try FileManager.default.removeItem(at: fixture.projectsFile)

        #expect(model.save() == project)
        #expect(!FileManager.default.fileExists(atPath: fixture.projectsFile.path))
    }

    @Test func reorderPersistsAndIgnoresTheUnsavedRow() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        let a = fixture.simpleProject(name: "A")
        let b = fixture.simpleProject(name: "B")
        let c = fixture.simpleProject(name: "C")
        for p in [a, b, c] { try store.upsert(p) }
        let model = fixture.model(store: store, selecting: a.id, defaultRoot: fixture.root.path, suggestion: "Fresh")

        model.moveProjects(from: IndexSet(integer: 2), to: 0)
        #expect(fixture.reloaded().projects.map(\.id) == [c.id, a.id, b.id])

        model.requestNewProject()
        model.moveProjects(from: IndexSet(integer: 0), to: 4)
        #expect(fixture.reloaded().projects.map(\.id) == [a.id, b.id, c.id])
        model.moveProjects(from: IndexSet(integer: 3), to: 0)
        #expect(fixture.reloaded().projects.map(\.id) == [a.id, b.id, c.id])
    }
}

// MARK: - View model: layout, kinds, Tabs

@MainActor
struct ProjectEditorLayoutTests {
    @Test(arguments: PaneLayout.allCases)
    func everyPresetCanBeChosen(layout: PaneLayout) throws {
        let fixture = try EditorFixture()
        let project = fixture.simpleProject(name: "Plain")
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)

        #expect(model.changePreset(to: layout) == .applied)

        #expect(model.draft?.layout.preset == layout)
        #expect(model.slotCount == layout.paneCount)
        #expect(model.panes.allSatisfy { $0.kind == .terminal && $0.tabs.count == 1 })
        #expect(model.slotFrames.count == layout.paneCount)
    }

    @Test func changingThePresetKeepsSurvivingSlotsAndWarnsBeforeDroppingConfiguredOnes() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)
        let original = model.panes
        model.selectSlot(2)

        #expect(model.changePreset(to: .horizontalSplit) == .needsConfirmation(droppedSlots: [2]))
        #expect(model.panes == original)
        #expect(model.draft?.layout.preset == .mainLeftTwoRight)

        #expect(model.changePreset(to: .horizontalSplit, confirmDrop: true) == .applied)
        #expect(model.panes == Array(original.prefix(2)))
        #expect(model.draft?.layout.preset == .horizontalSplit)
        #expect(model.selectedSlot == 1)
    }

    @Test func growingTheLayoutKeepsEverySlotAndAddsDefaultTerminals() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)
        let original = model.panes

        #expect(model.changePreset(to: .twoByTwoGrid) == .applied)

        #expect(Array(model.panes.prefix(3)) == original)
        #expect(model.panes[3] == .terminal())
    }

    @Test func droppingOnlyUnconfiguredSlotsNeedsNoWarning() throws {
        let fixture = try EditorFixture()
        let project = Project(name: "Plain", rootPath: fixture.root.path, color: .red, layout: .preset(.threeColumns))
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)

        #expect(model.changePreset(to: .singlePane) == .applied)
        #expect(model.slotCount == 1)
    }

    @Test func aCustomTopologyShowsNoPresetAndCanBeReplacedByOne() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)

        let custom = ProjectLayout(root: .split(direction: .vertical, children: [
            .pane(.terminal(tabs: [ProjectTab(title: "kept", startupCommand: "make")])),
            .split(direction: .horizontal, children: [.pane(.terminal()), .pane(.terminal()), .pane(ProjectPane(kind: .processStatus))]),
        ]))
        model.applyLayout(custom)
        #expect(model.draft?.layout.preset == nil)
        #expect(model.slotCount == 4)
        #expect(model.draft?.layout.thumbnailPanes.count == 4)
        #expect(model.draft?.layout.thumbnailPanes.first?.isPrimary == true)

        #expect(model.changePreset(to: .horizontalSplit) == .needsConfirmation(droppedSlots: [3]))
        #expect(model.changePreset(to: .horizontalSplit, confirmDrop: true) == .applied)
        #expect(model.panes[0].tabs[0].title == "kept")
        #expect(model.draft?.layout.preset == .horizontalSplit)
    }

    @Test func switchingTerminalToGitStatusAndBackKeepsTheTabsUntilSave() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)
        model.selectSlot(0)
        let tabs = try #require(model.selectedPane?.tabs)

        model.setKind(.gitStatus)
        #expect(model.selectedPane?.kind == .gitStatus)
        #expect(model.selectedPane?.tabs.isEmpty == true)
        model.setRepositoryPath("repo")
        #expect(model.draft?.makeProject().startupCommands.map(\.command) == ["claude"])

        model.setKind(.terminal)
        #expect(model.selectedPane?.tabs == tabs)
        model.setKind(.gitStatus)
        #expect(model.selectedPane?.repositoryPath == "repo")

        let saved = try #require(model.save())
        #expect(saved.layout.panes[0].kind == .gitStatus)
        #expect(saved.layout.panes[0].tabs.isEmpty)
        #expect(saved.startupCommands.map(\.command) == ["claude"])
        model.setKind(.terminal)
        #expect(model.selectedPane?.tabs == [ProjectTab()])
    }

    @Test func everyKindIsOfferedAndLMStudioUsesItsDisplayName() {
        #expect(PaneContentKind.allCases.count == 5)
        #expect(PaneContentKind.lmStudioDashboard.displayName == "LM Studio Dashboard")
    }

    @Test func tabsAddAndRemoveButTheLastCannotGo() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)
        model.selectSlot(2)

        model.removeTab(at: 0)
        #expect(model.selectedPane?.tabs.count == 1)

        model.addTab()
        model.addTab()
        #expect(model.selectedPane?.tabs.count == 3)
        model.setTabTitle(1, "second")
        model.removeTab(at: 0)
        #expect(model.selectedPane?.tabs.count == 2)
        #expect(model.selectedPane?.tabs[0].title == "second")

        model.selectSlot(1)
        model.addTab()
        #expect(model.selectedPane?.tabs.isEmpty == true)
    }

    @Test func chosenFoldersMustLieInsideTheRoot() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)
        model.selectSlot(0)

        #expect(model.relativePath(of: fixture.root) == ".")
        #expect(model.relativePath(of: fixture.root.appendingPathComponent("web/app")) == "web/app")
        #expect(model.relativePath(of: fixture.base) == nil)
        #expect(model.relativePath(of: URL(fileURLWithPath: fixture.root.path + "-sibling")) == nil)

        #expect(model.applyChosenDirectory(fixture.root.appendingPathComponent("web/app"), tab: 1))
        #expect(model.selectedPane?.tabs[1].workingDirectory == "web/app")
        #expect(!model.applyChosenDirectory(fixture.base, tab: 1))
        #expect(model.selectedPane?.tabs[1].workingDirectory == "web/app")
        #expect(model.saveError != nil)

        model.selectSlot(1)
        #expect(model.applyChosenDirectory(fixture.root.appendingPathComponent("docs"), tab: nil))
        #expect(model.selectedPane?.repositoryPath == "docs")
    }

    @Test func tabSummariesFollowTheCardWording() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)

        #expect(model.tabSummaries(slot: 0) == [
            ProjectEditorTabSummary(title: "build", line: "$ ./build.sh"),
            ProjectEditorTabSummary(title: "shell", line: "shell in root/"),
        ])
        model.selectSlot(2)
        model.setTabTitle(0, "")
        model.setTabDirectory(0, "docs")
        model.setTabCommand(0, "")
        #expect(model.tabSummaries(slot: 2) == [ProjectEditorTabSummary(title: "Tab 1", line: "shell in root/docs")])
        #expect(model.tabSummaries(slot: 1).isEmpty)
    }

    @Test func arrowKeysMoveTheSelectionByGeometry() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)
        #expect(model.selectedSlot == 0)
        model.moveSelection(.right)
        #expect(model.selectedSlot == 1)
        model.moveSelection(.down)
        #expect(model.selectedSlot == 2)
        model.moveSelection(.down)
        #expect(model.selectedSlot == 2)
        model.moveSelection(.left)
        #expect(model.selectedSlot == 0)
        #expect(model.selectedPosition == "Left")
        model.moveSelection(.right)
        #expect(model.selectedPosition == "Top right")
    }
}

@MainActor
struct ProjectEditorFolderAndIdentityTests {
    @Test func chosenFoldersResolveSymlinksOnBothSides() throws {
        let fixture = try EditorFixture()
        let link = fixture.base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        let project = Project(name: "Linked", rootPath: link.path, color: .red)
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)

        #expect(model.relativePath(of: fixture.root.appendingPathComponent("web/app")) == "web/app")
        #expect(model.relativePath(of: link.appendingPathComponent("docs")) == "docs")
        #expect(model.relativePath(of: fixture.root) == ".")
        #expect(model.relativePath(of: fixture.base) == nil)
    }

    @Test func removingAnEarlierTabKeepsTheOtherTabsIdentities() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)
        model.addTab()
        let before = model.selectedTabIDs
        #expect(before.count == 3)
        #expect(Set(before).count == 3)

        model.removeTab(at: 0)

        #expect(model.selectedTabIDs == Array(before.dropFirst()))
        model.addTab()
        #expect(Set(model.selectedTabIDs).count == 3)
        #expect(model.selectedTabIDs.prefix(2) == before.dropFirst())
    }

    @Test func aMissingRepositoryFolderIsWarnedAboutInGitStatusTerms() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = fixture.store()
        try store.upsert(project)
        let model = fixture.model(store: store, selecting: project.id)
        model.selectSlot(1)
        model.setRepositoryPath("nowhere")

        let warning = try #require(model.validationWarnings[.repository(slot: 1)])
        #expect(!warning.contains("Tab"))
        #expect(model.validationIssues.isEmpty)
    }
}

@MainActor
struct ProjectEditorMenuTargetTests {
    private func editorStandIn() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.identifier = NSUserInterfaceItemIdentifier(ProjectEditorWindowController.windowIdentifier)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func onlyTheProjectEditorWindowIsClassifiedAsTheEditor() {
        let editor = editorStandIn()
        let otherTitled = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: true)
        otherTitled.isReleasedWhenClosed = false
        otherTitled.identifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        let openPanel = NSOpenPanel()

        #expect(AppStateStore.isProjectEditorWindow(editor))
        #expect(!AppStateStore.isProjectEditorWindow(otherTitled))
        #expect(!AppStateStore.isProjectEditorWindow(panel))
        #expect(!AppStateStore.isProjectEditorWindow(openPanel))
        #expect(!AppStateStore.isProjectEditorWindow(nil))
    }

    @Test func aSheetIsJudgedByTheWindowItHangsFrom() {
        let editor = editorStandIn()
        let content = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                               styleMask: [.titled], backing: .buffered, defer: true)
        content.isReleasedWhenClosed = false
        let overEditor = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                                 styleMask: [.titled], backing: .buffered, defer: true)
        overEditor.isReleasedWhenClosed = false
        let overContent = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                                  styleMask: [.titled], backing: .buffered, defer: true)
        overContent.isReleasedWhenClosed = false

        editor.beginSheet(overEditor)
        content.beginSheet(overContent)
        defer {
            editor.endSheet(overEditor)
            content.endSheet(overContent)
        }

        #expect(overEditor.sheetParent === editor)
        #expect(AppStateStore.isProjectEditorWindow(overEditor))
        #expect(!AppStateStore.isProjectEditorWindow(overContent))
    }

    @Test func menuTargetAndTerminalTargetAreNilOnlyWhileTheEditorIsKey() {
        let store = AppStateStore()
        let content = store.windows[0]
        #expect(store.menuTargetWindow(projectEditorIsKey: false)?.id == content.id)
        #expect(store.menuTargetWindow(projectEditorIsKey: true) == nil)

        let tab = store.focusedTerminalTab(projectEditorIsKey: false)
        #expect(tab != nil)
        #expect(tab?.id == content.selectedSession?.focusedTerminalPane?.activeTab?.id)
        #expect(store.focusedTerminalTab(projectEditorIsKey: true) == nil)
    }

    @Test func enablementResolutionIgnoresTheEditorKeyState() {
        let store = AppStateStore()
        let content = store.windows[0]
        #expect(store.keyWindowOrFirstRegistered()?.id == content.id)
        #expect(store.menuTargetWindow(projectEditorIsKey: true) == nil)
        #expect(store.keyWindowOrFirstRegistered()?.id == content.id)
        #expect(store.keyWindowOrFirstRegistered()?.id == store.defaultTargetWindow()?.id)
    }

    @Test func xpcAndCLIResolutionIsUnaffected() {
        let store = AppStateStore()
        #expect(store.defaultTargetWindow()?.id == store.windows[0].id)
    }
}

// MARK: - Window, flag and view

@MainActor
struct ProjectEditorWindowTests {
    @Test func theEntryPointFollowsTheFlag() {
        #expect(ProjectEditorWindowController.isAvailable(featureFlags: FeatureFlags(projects: true)))
        #expect(!ProjectEditorWindowController.isAvailable(featureFlags: FeatureFlags(projects: false)))
    }

    @Test func withTheFlagOffNoWindowModelOrStoreIsCreated() throws {
        let fixture = try EditorFixture()
        let store = AppStateStore(nameCache: SessionNameCache(fileURL: fixture.cacheFile), featureFlags: FeatureFlags(projects: false), projectsFileURL: fixture.projectsFile)
        let controller = ProjectEditorWindowController()

        #expect(!controller.prepare(store: store))
        #expect(!controller.show(store: store))
        #expect(!controller.prepare(store: store, selecting: UUID()))
        #expect(controller.window == nil)
        #expect(controller.model == nil)
        #expect(store.projectStore == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.projectsFile.path))
        #expect(!NSApplication.shared.windows.contains { $0.identifier?.rawValue == ProjectEditorWindowController.windowIdentifier })
    }

    @Test func withTheFlagOnTheWindowIsCreatedOnDemandAndIsNotAContentWindow() throws {
        let fixture = try EditorFixture()
        let project = fixture.richProject()
        let store = AppStateStore(nameCache: SessionNameCache(fileURL: fixture.cacheFile), featureFlags: FeatureFlags(projects: true), projectsFileURL: fixture.projectsFile)
        try #require(store.projectStore).upsert(project)
        let other = fixture.simpleProject(name: "Other")
        try #require(store.projectStore).upsert(other)
        let controller = ProjectEditorWindowController()
        defer { controller.window?.close() }

        #expect(controller.prepare(store: store, selecting: other.id))
        let window = try #require(controller.window)
        #expect(window.identifier?.rawValue == ProjectEditorWindowController.windowIdentifier)
        #expect(controller.model?.selectedID == other.id)
        #expect(store.registeredContentWindowCount == 0)
        #expect(!store.keyWindowIsContentWindow())

        #expect(controller.prepare(store: store, selecting: project.id))
        #expect(controller.window === window)
        #expect(controller.model?.selectedID == project.id)

        window.close()
        #expect(controller.window == nil)
        #expect(controller.model == nil)
    }

    @Test func aDraftHandedToTheEditorOpensAsAnUnsavedProject() throws {
        let fixture = try EditorFixture()
        let store = AppStateStore(nameCache: SessionNameCache(fileURL: fixture.cacheFile), featureFlags: FeatureFlags(projects: true), projectsFileURL: fixture.projectsFile)
        try #require(store.projectStore).upsert(fixture.richProject())
        let controller = ProjectEditorWindowController()
        defer { controller.window?.close() }
        let draft = ProjectDraft(name: "Captured", rootPath: fixture.root.path, color: .brown, layout: .preset(.threeRows))

        #expect(controller.prepare(store: store, newDraft: draft))

        #expect(controller.model?.draft == draft)
        #expect(controller.model?.isNewDraft == true)
        #expect(controller.model?.isDirty == true)
        #expect(controller.model?.requestNavigation(.closeWindow) == false)
        #expect(controller.model?.pendingNavigation == .closeWindow)
        #expect(controller.window?.delegate?.windowShouldClose?(try #require(controller.window)) == false)
        #expect(store.projectStore?.projects.count == 1)
    }

    @Test func saveAndOpenGoesThroughTheTrustCheckNotStraightToOpen() throws {
        let fixture = try EditorFixture()
        let store = AppStateStore(nameCache: SessionNameCache(fileURL: fixture.cacheFile), featureFlags: FeatureFlags(projects: true), projectsFileURL: fixture.projectsFile)
        var project = fixture.richProject()
        project.runStartupCommandsOnOpen = true
        project.approvedCommandsHash = nil
        try #require(store.projectStore).upsert(project)
        let controller = ProjectEditorWindowController()
        defer { controller.window?.close() }
        #expect(controller.prepare(store: store, selecting: project.id))
        let model = try #require(controller.model)
        let window = try #require(store.defaultTargetWindow())
        let sessionsBefore = window.sessions.count
        model.setColor(.cyan)

        #expect(model.saveAndOpen())

        #expect(controller.window == nil)
        #expect(window.pendingStartupTrusts.count == 1)
        #expect(window.pendingStartupTrusts.first?.projectID == project.id)
        #expect(window.sessions.count == sessionsBefore)
        #expect(store.projectStore?.project(id: project.id)?.color == .cyan)
    }

    @Test func theEditorViewLaysOutForEveryKindAndACustomLayout() throws {
        let fixture = try EditorFixture()
        let store = fixture.store()
        var project = fixture.richProject()
        project.layout = ProjectLayout(root: .split(direction: .horizontal, children: [
            .pane(.terminal(tabs: [ProjectTab(title: "a", startupCommand: "ls"), ProjectTab()])),
            .split(direction: .vertical, children: [
                .pane(ProjectPane(kind: .gitStatus, repositoryPath: "repo")),
                .pane(ProjectPane(kind: .processStatus)),
                .pane(ProjectPane(kind: .systemMetrics)),
                .pane(ProjectPane(kind: .lmStudioDashboard)),
            ]),
        ]))
        try store.upsert(project)
        try store.upsert(fixture.simpleProject(name: "Second"))
        let model = fixture.model(store: store, selecting: project.id)

        let host = NSHostingView(rootView: ProjectEditorView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 1120, height: 740)
        host.layoutSubtreeIfNeeded()
        for slot in 0..<model.slotCount {
            model.selectSlot(slot)
            host.layoutSubtreeIfNeeded()
        }
        model.requestNewProject()
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }
}
