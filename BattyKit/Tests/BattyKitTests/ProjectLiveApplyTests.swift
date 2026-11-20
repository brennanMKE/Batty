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

    @Test func layoutWaitsForTheNextOpen() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let project = fixture.project(background: nil)
        try store.projectStore.upsert(project)
        let session = try open(store, project)

        _ = try save(store, project) { $0.layout = .preset(.horizontalSplit) }

        #expect(session.tree.allPanes.count == 1)
    }

    // MARK: Pane and Tab backgrounds (#0702)

    private func level(_ imageOpacity: Double, _ terminalOpacity: Double, path: String? = nil) -> TerminalBackgroundSettings {
        TerminalBackgroundSettings(imagePath: path, fit: .contain, position: .topRight, imageOpacity: imageOpacity, terminalOpacity: terminalOpacity, opacityAffectsCells: true)
    }

    private func layout(pane: TerminalBackgroundSettings? = nil, tabs: [TerminalBackgroundSettings?], images: [ProjectTabImage?] = []) -> ProjectLayout {
        let projectTabs = tabs.enumerated().map { index, background in
            ProjectTab(background: background, image: images.indices.contains(index) ? images[index] : nil)
        }
        return ProjectLayout(root: .pane(ProjectPane(kind: .terminal, tabs: projectTabs, background: pane)))
    }

    private func setTab(_ project: inout Project, _ tab: Int, _ background: TerminalBackgroundSettings?, image: ProjectTabImage? = nil) {
        project.layout.root = project.layout.root.mappingPanes { _, pane in
            var pane = pane
            pane.tabs[tab].background = background
            pane.tabs[tab].image = background == nil ? nil : image
            return pane
        }
    }

    private func setPane(_ project: inout Project, _ background: TerminalBackgroundSettings?) {
        project.layout.root = project.layout.root.mappingPanes { _, pane in
            var pane = pane
            pane.background = background
            return pane
        }
    }

    /// The Project opened twice: once in the main Window, once in a second.
    private func openTwice(_ store: AppStateStore, _ project: Project) throws -> (SessionRuntime, SessionRuntime) {
        try store.projectStore.upsert(project)
        let first = try open(store, project)
        let window = store.openWindowRuntime(for: WindowID())
        let tree = try ProjectTreeBuilder.build(project: project, contentFactory: noContent, isSessionSelected: true)
        let second = window.addProjectSession(project, tree: tree, background: project.background)
        return (first, second)
    }

    private func tabs(_ session: SessionRuntime) -> [TabRuntime] { session.tree.allPanes[0].tabs }

    private func effective(_ tab: TabRuntime) -> TerminalBackgroundSettings? {
        tab.backgroundOverride ?? tab.paneBackgroundOverride ?? tab.sessionBackgroundOverride
    }

    @Test func savingATabBackgroundAppliesToThatTabInEveryOpenSession() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        var project = fixture.project(background: nil)
        project.layout = layout(tabs: [level(0.3, 0.8), nil])
        let (first, second) = try openTwice(store, project)

        _ = try save(store, project) { setTab(&$0, 0, level(0.6, 0.5)) }

        for session in [first, second] {
            #expect(tabs(session)[0].backgroundOverride == level(0.6, 0.5))
            #expect(tabs(session)[1].backgroundOverride == nil)
        }
    }

    @Test func savingAPaneBackgroundAppliesToThatPaneInEveryOpenSession() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        var project = fixture.project(background: nil)
        project.layout = layout(pane: level(0.2, 0.7), tabs: [nil, level(0.4, 0.9)])
        let (first, second) = try openTwice(store, project)

        _ = try save(store, project) { setPane(&$0, level(0.65, 0.55)) }

        for session in [first, second] {
            #expect(session.tree.allPanes[0].backgroundOverride == level(0.65, 0.55))
            #expect(effective(tabs(session)[0]) == level(0.65, 0.55))
            #expect(tabs(session)[1].backgroundOverride == level(0.4, 0.9))
        }
    }

    @Test func aTabTheUserOverrodeKeepsItsBackgroundAcrossAProjectSave() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        var project = fixture.project(background: nil)
        project.layout = layout(tabs: [level(0.3, 0.8), nil])
        let (first, second) = try openTwice(store, project)
        let user = level(0.15, 0.25)
        tabs(first)[0].setBackgroundOverride(user)

        let saved = try save(store, project) { setTab(&$0, 0, level(0.6, 0.5)) }
        #expect(tabs(first)[0].backgroundOverride == user)
        #expect(tabs(second)[0].backgroundOverride == level(0.6, 0.5))

        _ = try save(store, saved) { setTab(&$0, 0, level(0.7, 0.45)) }
        #expect(tabs(first)[0].backgroundOverride == user)
        #expect(tabs(second)[0].backgroundOverride == level(0.7, 0.45))
    }

    @Test func clearingATabBackgroundReturnsTheTabToTheSessionBackground() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        var project = fixture.project(background: projectBackgroundValue(path: nil))
        project.layout = layout(tabs: [level(0.3, 0.8)])
        let (first, second) = try openTwice(store, project)

        _ = try save(store, project) { setTab(&$0, 0, nil) }

        for session in [first, second] {
            #expect(tabs(session)[0].backgroundOverride == nil)
            #expect(effective(tabs(session)[0]) == projectBackgroundValue(path: nil))
        }
    }

    @Test func aProjectBackgroundSaveReachesFollowingTabsInEverySession() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        var project = fixture.project(background: projectBackgroundValue(path: nil))
        project.layout = layout(tabs: [nil, level(0.3, 0.8)])
        let (first, second) = try openTwice(store, project)

        _ = try save(store, project) { $0.background = secondBackgroundValue(path: nil) }

        for session in [first, second] {
            #expect(tabs(session)[0].sessionBackgroundOverride == secondBackgroundValue(path: nil))
            #expect(effective(tabs(session)[0]) == secondBackgroundValue(path: nil))
            #expect(tabs(session)[1].backgroundOverride == level(0.3, 0.8))
        }
    }

    @Test func aSecondSaveStillReachesATabTheFirstSaveUpdated() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        var project = fixture.project(background: nil)
        project.layout = layout(tabs: [level(0.3, 0.8)])
        let (first, _) = try openTwice(store, project)

        let saved = try save(store, project) { setTab(&$0, 0, level(0.6, 0.5)) }
        _ = try save(store, saved) { setTab(&$0, 0, level(0.7, 0.45)) }

        #expect(tabs(first)[0].backgroundOverride == level(0.7, 0.45))
    }

    @Test func addingABackgroundToATabSlotReachesTheFollowingTab() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        var project = fixture.project(background: nil)
        project.layout = layout(tabs: [nil, nil])
        let (first, second) = try openTwice(store, project)

        _ = try save(store, project) { setTab(&$0, 0, level(0.6, 0.5)) }

        for session in [first, second] {
            #expect(tabs(session)[0].backgroundOverride == level(0.6, 0.5))
            #expect(tabs(session)[1].backgroundOverride == nil)
        }
    }

    @Test func aSaveThatRemovesATabLeavesPaneAndTabBackgroundsForTheNextOpen() throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        var project = fixture.project(background: nil)
        project.layout = layout(tabs: [level(0.1, 0.8), level(0.2, 0.7), level(0.3, 0.6)])
        let (first, _) = try openTwice(store, project)

        let saved = try save(store, project) { $0.layout = layout(tabs: [level(0.1, 0.8), level(0.9, 0.4)]) }
        #expect(tabs(first).map(\.backgroundOverride) == [level(0.1, 0.8), level(0.2, 0.7), level(0.3, 0.6)])

        _ = try save(store, saved) { setTab(&$0, 0, level(0.5, 0.5)) }
        #expect(tabs(first).map(\.backgroundOverride) == [level(0.1, 0.8), level(0.2, 0.7), level(0.3, 0.6)])
    }

    @Test func aMissingTabImageIsMarkedAndRequested() async throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        var project = fixture.project(background: nil)
        project.layout = layout(tabs: [level(0.3, 0.8)])
        let (first, _) = try openTwice(store, project)
        let path = try await fixture.copy()
        let image = ProjectTabImage.custom(digest: try #require(TerminalBackgroundImageImporter.digest(ofPath: path)), name: "photo.png")
        try fixture.removeFolder(of: path)

        _ = try save(store, project) { setTab(&$0, 0, level(0.6, 0.5, path: path), image: image) }
        await store.tabImageRequest?.value

        #expect(tabs(first)[0].backgroundOverride == level(0.6, 0.5))
        #expect(first.projectBackgroundImageProblem == .missing)
        #expect(tabs(first)[0].pendingTabImage == image)
    }

    @Test func aTabWhoseImageArrivedStillTakesTheNextSave() async throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        let path = try await fixture.copy(in: fixture.paneFolder)
        let image = ProjectTabImage.custom(digest: try #require(TerminalBackgroundImageImporter.digest(ofPath: path)), name: "photo.png")
        var project = fixture.project(background: nil)
        project.layout = layout(tabs: [level(0.3, 0.8)], images: [image])
        try store.projectStore.upsert(project)
        let session = try open(store, project)
        #expect(tabs(session)[0].pendingTabImage == image)

        store.tabImageArrived(projectID: project.id, identity: image, path: path)
        #expect(tabs(session)[0].backgroundOverride == level(0.3, 0.8, path: path))

        _ = try save(store, project) { setTab(&$0, 0, level(0.6, 0.5)) }
        #expect(tabs(session)[0].backgroundOverride == level(0.6, 0.5))
    }

    @Test func updateProjectAdoptsTheSessionsValueAsTheTabsSeed() async throws {
        let fixture = try ProjectBackgroundFixture()
        let store = store(fixture)
        var project = fixture.project(background: nil)
        project.layout = layout(tabs: [level(0.3, 0.8)])
        let (first, _) = try openTwice(store, project)
        let sessionPath = try await fixture.copy(in: fixture.paneFolder)
        let projectPath = try await fixture.copy()
        #expect(sessionPath != projectPath)
        tabs(first)[0].setBackgroundOverride(level(0.6, 0.5, path: sessionPath))

        let adopted = try save(store, project) { setTab(&$0, 0, level(0.6, 0.5, path: projectPath)) }
        #expect(tabs(first)[0].backgroundOverride == level(0.6, 0.5, path: sessionPath))

        _ = try save(store, adopted) { setTab(&$0, 0, level(0.7, 0.45)) }
        #expect(tabs(first)[0].backgroundOverride == level(0.7, 0.45))
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
