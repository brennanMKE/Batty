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
}
