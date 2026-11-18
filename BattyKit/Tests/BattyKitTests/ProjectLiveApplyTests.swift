// ProjectLiveApplyTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

private let noContent: @MainActor (PaneContentKind) -> (any PaneContentLifecycle)? = { _ in nil }

@MainActor
struct ProjectLiveApplyTests {
    private let themes = Array(BattyThemeCatalog.allThemes.prefix(3))

    private func store(_ fixture: ProjectBackgroundFixture) -> AppStateStore {
        let defaults = fixture.testDefaults.defaults
        defaults.set(true, forKey: ThemePreference.migrationDoneKey)
        defaults.set(themes[1].name, forKey: ThemePreference.darkDefaultsKey)
        defaults.set(themes[2].name, forKey: ThemePreference.lightDefaultsKey)
        return fixture.appStore()
    }

    private func open(_ store: AppStateStore, _ project: Project) throws -> SessionRuntime {
        try store.openProject(id: project.id, mode: .openNew, contentFactory: noContent).session
    }

    private func save(_ store: AppStateStore, _ previous: Project, _ change: (inout Project) -> Void) throws -> Project {
        var saved = previous
        change(&saved)
        try store.projectStore.upsert(saved)
        store.applyProjectSave(previous: previous, saved: saved, isDark: true)
        return saved
    }

    private func uses(_ theme: GhosttyThemeDefinition, _ session: SessionRuntime) -> Bool {
        let tabs = session.tree.allPanes.filter { $0.kind == .terminal }.flatMap(\.tabs)
        let expected = theme.toTerminalTheme()
        return !tabs.isEmpty && tabs.allSatisfy { $0.terminal.controller.theme == expected }
    }

    @Test func savingABackgroundAppliesItToEveryOpenSessionOfThatProjectAndNoOther() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: projectBackgroundValue(path: nil))
        let other = fixture.project(name: "Other", background: projectBackgroundValue(path: nil))
        try store.projectStore.upsert(project)
        try store.projectStore.upsert(other)
        let first = try open(store, project)
        let secondWindow = store.openWindowRuntime(for: WindowID())
        let tree = try ProjectTreeBuilder.build(project: project, contentFactory: noContent, isSessionSelected: true)
        let second = secondWindow.addProjectSession(project, tree: tree, background: projectBackgroundValue(path: nil))
        let untouched = try open(store, other)

        _ = try save(store, project) { $0.background = secondBackgroundValue(path: nil) }

        #expect(first.backgroundOverride == secondBackgroundValue(path: nil))
        #expect(first.tree.allPanes[0].sessionBackgroundOverride == secondBackgroundValue(path: nil))
        #expect(second.backgroundOverride == secondBackgroundValue(path: nil))
        #expect(untouched.backgroundOverride == projectBackgroundValue(path: nil))
    }

    @Test func savingNewOpacitiesReachTheOpenSession() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: projectBackgroundValue(path: nil))
        try store.projectStore.upsert(project)
        let session = try open(store, project)
        let changed = TerminalBackgroundSettings(imagePath: nil, fit: .contain, position: .topRight, imageOpacity: 0.15, terminalOpacity: 0.3, opacityAffectsCells: true)

        _ = try save(store, project) { $0.background = changed }

        #expect(session.backgroundOverride?.imageOpacity == 0.15)
        #expect(session.backgroundOverride?.terminalOpacity == 0.3)
    }

    @Test func removingTheProjectBackgroundReturnsTheSessionToTheAppWideValue() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: projectBackgroundValue(path: nil))
        try store.projectStore.upsert(project)
        let session = try open(store, project)

        _ = try save(store, project) { $0.background = nil }

        #expect(session.backgroundOverride == nil)
        #expect(session.tree.allPanes[0].sessionBackgroundOverride == nil)
    }

    @Test func aSavedBackgroundWithAMissingImageMarksTheRowProblem() async throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: nil)
        try store.projectStore.upsert(project)
        let session = try open(store, project)
        let path = try await fixture.copy()
        try fixture.removeFolder(of: path)

        _ = try save(store, project) { $0.background = projectBackgroundValue(path: path) }

        #expect(session.projectBackgroundImageProblem == .missing)
        #expect(session.backgroundOverride == projectBackgroundValue(path: nil))
    }

    @Test func savingAColorRecolorsTheSessionInEveryWindow() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: nil)
        try store.projectStore.upsert(project)
        let first = try open(store, project)
        let secondWindow = store.openWindowRuntime(for: WindowID())
        let tree = try ProjectTreeBuilder.build(project: project, contentFactory: noContent, isSessionSelected: true)
        let second = secondWindow.addProjectSession(project, tree: tree)

        _ = try save(store, project) { $0.color = .red }

        #expect(first.colorIndex == SessionColor.red.rawValue && first.colorOverride)
        #expect(second.colorIndex == SessionColor.red.rawValue && second.colorOverride)
    }

    @Test func aCustomHexColorAppliesItsNearestPaletteColor() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: nil)
        try store.projectStore.upsert(project)
        let session = try open(store, project)
        let hex = SessionColor.red.hexString
        let custom = Project(id: project.id, name: project.name, rootPath: project.rootPath, color: .teal, layout: project.layout, customColorHex: hex)

        try store.projectStore.upsert(custom)
        store.applyProjectSave(previous: project, saved: custom, isDark: true)

        #expect(session.colorIndex == custom.color.rawValue)
        #expect(custom.color == SessionColor.red)
    }

    @Test func savingAThemeSetsTheSessionThemeAndReThemesItsTerminals() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: nil)
        try store.projectStore.upsert(project)
        let session = try open(store, project)
        store.applyActiveSessionTheme(for: session, isDark: true)
        #expect(uses(themes[1], session))

        _ = try save(store, project) { $0.theme = .both(themes[0].name) }

        #expect(session.themeOverride == .both(themes[0].name))
        #expect(uses(themes[0], session))
    }

    @Test func clearingTheProjectThemeReturnsTheSessionToTheGlobalTheme() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        var project = fixture.project(background: nil)
        project.theme = .both(themes[0].name)
        try store.projectStore.upsert(project)
        let session = try open(store, project)
        store.applyActiveSessionTheme(for: session, isDark: true)
        #expect(uses(themes[0], session))

        _ = try save(store, project) { $0.theme = nil }

        #expect(session.themeOverride == nil)
        #expect(uses(themes[1], session))
    }

    @Test func renamingTheProjectRenamesItsOpenSession() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: nil)
        try store.projectStore.upsert(project)
        let session = try open(store, project)

        _ = try save(store, project) { $0.name = "Renamed" }

        #expect(session.title == "Renamed")
        #expect(session.titleOverride)
    }

    @Test func aSaveKeepsSidebarOverridesOfFieldsItDidNotChange() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: projectBackgroundValue(path: nil))
        try store.projectStore.upsert(project)
        let session = try open(store, project)
        store.windows[0].setSessionColor(id: session.id, to: SessionColor.amber.rawValue)
        session.themeOverride = .both(themes[2].name)
        session.setBackgroundOverride(secondBackgroundValue(path: nil))
        session.title = "Sidebar Name"

        _ = try save(store, project) { $0.symbol = .map }

        #expect(session.projectSymbol == .map)
        #expect(session.colorIndex == SessionColor.amber.rawValue)
        #expect(session.themeOverride == .both(themes[2].name))
        #expect(session.backgroundOverride == secondBackgroundValue(path: nil))
        #expect(session.title == "Sidebar Name")
    }

    @Test func aSaveOverwritesASidebarOverrideOfAFieldItChanged() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: nil)
        try store.projectStore.upsert(project)
        let session = try open(store, project)
        store.windows[0].setSessionColor(id: session.id, to: SessionColor.amber.rawValue)

        _ = try save(store, project) { $0.color = .green }

        #expect(session.colorIndex == SessionColor.green.rawValue)
    }

    @Test func layoutAndPaneBackgroundsWaitForTheNextOpen() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: nil)
        try store.projectStore.upsert(project)
        let session = try open(store, project)
        let pane = session.tree.allPanes[0]
        #expect(pane.backgroundOverride == nil)

        _ = try save(store, project) { $0.layout = .preset(.horizontalSplit) }

        #expect(session.tree.allPanes.count == 1)
        #expect(pane.backgroundOverride == nil)
    }

    @Test func anEditorSaveWiredLikeTheControllerAppliesToTheOpenSession() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: nil)
        try store.projectStore.upsert(project)
        let session = try open(store, project)
        let model = ProjectEditorViewModel(store: store.projectStore, initialSelection: project.id)
        model.projectSaved = { store.applyProjectSave(previous: $0, saved: $1) }

        model.setColor(.pink)
        _ = model.save()

        #expect(session.colorIndex == SessionColor.pink.rawValue)
    }

    @Test func revertingAnEditAppliesNothing() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: nil)
        try store.projectStore.upsert(project)
        let session = try open(store, project)
        let model = ProjectEditorViewModel(store: store.projectStore, initialSelection: project.id)
        var calls = 0
        model.projectSaved = { _, _ in calls += 1 }

        model.setColor(.pink)
        model.revert()

        #expect(calls == 0)
        #expect(session.colorIndex == SessionColor.teal.rawValue)
    }

    @Test func anUnchangedSaveDoesNotCallTheSeam() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: nil)
        try store.projectStore.upsert(project)
        let model = ProjectEditorViewModel(store: store.projectStore, initialSelection: project.id)
        var calls = 0
        model.projectSaved = { _, _ in calls += 1 }

        _ = model.save()

        #expect(calls == 0)
    }

    @Test func editProjectOpensTheEditorOnTheBackingProject() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: nil)
        try store.projectStore.upsert(project)
        let session = try open(store, project)
        var opened: [UUID] = []

        let result = SaveSessionAsProject.editProject(session: session, store: store) { _, id in opened.append(id) }

        #expect(result)
        #expect(opened == [project.id])
    }

    @Test func editProjectDoesNothingForAPlainSession() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        var opened: [UUID] = []

        let result = SaveSessionAsProject.editProject(session: fixture.session(), store: store) { _, id in opened.append(id) }

        #expect(!result)
        #expect(opened.isEmpty)
    }

    @Test func editProjectDoesNothingWhenTheProjectWasDeleted() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: nil)
        try store.projectStore.upsert(project)
        let session = try open(store, project)
        try store.projectStore.delete(id: project.id)
        var opened: [UUID] = []

        let result = SaveSessionAsProject.editProject(session: session, store: store) { _, id in opened.append(id) }

        #expect(!result)
        #expect(opened.isEmpty)
    }

    @Test func rowValueCarriesTheTintOnlyWhenGiven() throws {
        let fixture = try ProjectBackgroundFixture()
        let session = fixture.session()

        let tinted = SessionSidebarView.rowAccessibilityValue(for: session, isSelected: true, iconName: "circle.fill", tint: "teal")
        let plain = SessionSidebarView.rowAccessibilityValue(for: session, isSelected: true, iconName: "circle.fill")

        #expect(tinted == "selected, tint teal, icon circle.fill")
        #expect(plain == "selected, icon circle.fill")
    }
}
