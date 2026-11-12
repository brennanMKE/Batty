// BackgroundImageUsesTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct BackgroundImageUsesTests {
    private let f: ProjectBackgroundFixture

    init() throws { f = try ProjectBackgroundFixture() }

    private func digest(_ path: String) throws -> String {
        try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
    }

    @Test func findsTheAppWideImage() async throws {
        let path = try await f.copy(in: f.appWideFolder)
        SettingsPreference.writeBackground(appWideBackgroundValue(path: path), defaults: f.testDefaults.defaults)
        #expect(f.appStore().backgroundImageUses()[try digest(path)] == [.appWide])
    }

    @Test func findsASavedProject() async throws {
        let path = try await f.copy()
        let project = f.project(name: "Harbor", background: projectBackgroundValue(path: path))
        let store = f.appStore()
        try store.projectStore.upsert(project)
        #expect(store.backgroundImageUses()[try digest(path)] == [.project(id: project.id, name: "Harbor", isShared: false)])
    }

    @Test func findsTheEditorDraft() async throws {
        let wide = try await f.copy(in: f.appWideFolder)
        let store = f.appStore()
        try store.projectStore.upsert(f.project(background: nil))
        let model = ProjectEditorViewModel(store: store.projectStore, directoryExists: { _ in true }, backgrounds: f.library)
        store.projectEditorModelOverride = { model }
        model.setBackgroundOverride(projectBackgroundValue(path: wide))
        #expect(store.backgroundImageUses()[try digest(wide)] == [.projectDraft])
    }

    @Test func matchesASessionAndAPaneByDigestAcrossFolders() async throws {
        let inProject = try await f.copy(in: f.projectFolder)
        let inPane = try await f.copy(in: f.paneFolder)
        let session = f.session()
        session.setBackgroundOverride(projectBackgroundValue(path: inProject))
        let pane = try #require(session.tree.allPanes.first)
        pane.setBackgroundOverride(secondBackgroundValue(path: inPane))
        let store = f.appStore(sessions: [session])
        let uses = store.backgroundImageUses()[try digest(inPane)] ?? []
        #expect(try digest(inPane) == digest(inProject))
        #expect(Set(uses) == [.session(id: session.id, title: "Website"), .pane(id: pane.id, sessionTitle: "Website")])
    }

    @Test func ignoresOtherDigests() async throws {
        let used = try await f.copy(in: f.paneFolder, width: 64)
        let other = try await f.copy(in: f.paneFolder, width: 72)
        let session = f.session()
        session.setBackgroundOverride(projectBackgroundValue(path: used))
        let uses = f.appStore(sessions: [session]).backgroundImageUses()
        #expect(uses[try digest(other)] == nil)
        #expect(uses.count == 1)
    }
    @Test func aProjectTabImageIsListedAsTheProject() async throws {
        let path = try await f.copy()
        let layout = ProjectLayout(root: .pane(.terminal(tabs: [ProjectTab(background: projectBackgroundValue(path: path)), ProjectTab(background: secondBackgroundValue(path: path))])))
        let project = f.project(name: "Harbor", background: projectBackgroundValue(path: path), layout: layout)
        let store = f.appStore()
        try store.projectStore.upsert(project)
        #expect(store.backgroundImageUses()[try digest(path)] == [.project(id: project.id, name: "Harbor", isShared: false)])
    }

    @Test func aRuntimeTabImageIsListedAsATab() async throws {
        let path = try await f.copy(in: f.paneFolder)
        let session = f.session()
        let tab = session.tree.allPanes[0].tabs[0]
        tab.setBackgroundOverride(projectBackgroundValue(path: path))
        let store = f.appStore(sessions: [session])
        #expect(store.backgroundImageUses()[try digest(path)] == [.tab(id: tab.id, sessionTitle: "Website")])
    }

    @Test func removeClearsTabValuesAndProjectTabPaths() async throws {
        let path = try await f.copy()
        let layout = ProjectLayout(root: .pane(.terminal(tabs: [ProjectTab(background: projectBackgroundValue(path: path))])))
        let project = f.project(background: nil, layout: layout)
        let session = f.session()
        let pane = session.tree.allPanes[0]
        pane.addTab()
        pane.setBackgroundOverride(secondBackgroundValue(path: path))
        pane.tabs[0].setBackgroundOverride(projectBackgroundValue(path: path))
        let store = f.appStore(sessions: [session])
        try store.projectStore.upsert(project)

        try store.clearBackgroundImageUses(digest: try digest(path))

        #expect(store.projectStore.project(id: project.id)?.layout.panes[0].tabs[0].background == projectBackgroundValue(path: nil))
        #expect(pane.tabs[0].backgroundOverride == projectBackgroundValue(path: nil), "the Pane's own removal keeps the Tab's value")
        #expect(pane.backgroundOverride == secondBackgroundValue(path: nil))
    }

    @Test func summaryCountsTabs() {
        #expect(BackgroundImageUse.summary(of: [.tab(id: UUID(), sessionTitle: "A")]) == "1 Tab")
        #expect(BackgroundImageUse.summary(of: [.tab(id: UUID(), sessionTitle: "A"), .tab(id: UUID(), sessionTitle: "B")]) == "2 Tabs")
        #expect(BackgroundImageUse.tab(id: UUID(), sessionTitle: "Website").localizedDescription == "A Tab in Website")
    }
}
