// BackgroundImagesModelTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct BackgroundImagesModelTests {
    private let f: ProjectBackgroundFixture

    init() throws { f = try ProjectBackgroundFixture() }

    private func entry(_ model: BackgroundImagesModel, forPath path: String) async throws -> BackgroundImageEntry {
        await model.refresh()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        return try #require(model.entries.first { $0.digest == digest })
    }

    @Test func refreshPublishesEntriesAndUses() async throws {
        let path = try await f.copy(in: f.appWideFolder)
        SettingsPreference.writeBackground(appWideBackgroundValue(path: path), defaults: f.testDefaults.defaults)
        let store = f.appStore()
        let model = store.backgroundImages
        await model.refresh()
        #expect(model.entries.count == 1)
        #expect(model.uses[model.entries[0].digest] == [.appWide])
        #expect(!model.isScanning)
    }

    @Test func removingAnUnusedImageDeletesItAndReportsIt() async throws {
        let path = try await f.copy(in: f.paneFolder, named: "harbor.png")
        let store = f.appStore()
        let model = store.backgroundImages
        await model.remove(try await entry(model, forPath: path))
        #expect(model.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(model.message?.contains("Removed") == true)
    }

    @Test func removingAnAppWideImageClearsThePathKeepsTheOtherSettingsAndRefreshesTheGate() async throws {
        let path = try await f.copy(in: f.appWideFolder)
        SettingsPreference.writeBackground(appWideBackgroundValue(path: path), defaults: f.testDefaults.defaults)
        let store = f.appStore()
        let model = store.backgroundImages
        await model.remove(try await entry(model, forPath: path))
        #expect(store.backgroundGate.storedSettings() == appWideBackgroundValue(path: nil))
        #expect(store.backgroundGate.settings().imagePath == nil)
    }

    @Test func removingAProjectsImageKeepsItsOtherSettingsAndDoesNotStampModifiedAt() async throws {
        let path = try await f.copy()
        let store = f.appStore()
        let project = f.project(background: projectBackgroundValue(path: path))
        try store.projectStore.upsert(project)
        let stamped = store.projectStore.projects[0].modifiedAt
        let model = store.backgroundImages
        await model.remove(try await entry(model, forPath: path))
        #expect(store.projectStore.projects[0].background == projectBackgroundValue(path: nil))
        #expect(store.projectStore.projects[0].modifiedAt == stamped)
        #expect(ProjectStore(fileURL: f.projectsFile).projects[0].background == projectBackgroundValue(path: nil))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func removingASharedProjectsImageDoesNotPublish() async throws {
        let path = try await f.copy()
        let backend = SwitchableProjectSyncBackend()
        let store = f.appStore()
        store.projectSyncBackendFactory = { backend }
        var project = f.project(background: projectBackgroundValue(path: path))
        project.isShared = true
        try store.projectStore.upsert(project)
        let published = backend.published.count
        let model = store.backgroundImages
        await model.remove(try await entry(model, forPath: path))
        #expect(store.projectStore.projects[0].background?.imagePath == nil)
        #expect(backend.published.count == published)
    }

    @Test func removingClearsSessionAndPaneOverridesKeepingOpacity() async throws {
        let inProject = try await f.copy(in: f.projectFolder)
        let inPane = try await f.copy(in: f.paneFolder)
        let session = f.session()
        let pane = try #require(session.tree.allPanes.first)
        session.setBackgroundOverride(projectBackgroundValue(path: inProject))
        pane.setBackgroundOverride(secondBackgroundValue(path: inPane))
        let store = f.appStore(sessions: [session])
        let model = store.backgroundImages
        await model.remove(try await entry(model, forPath: inPane))
        #expect(session.backgroundOverride == projectBackgroundValue(path: nil))
        #expect(pane.backgroundOverride == secondBackgroundValue(path: nil))
        #expect(!backgroundLines(pane.tabs[0]).contains { $0.hasPrefix("background-image =") })
    }

    @Test func removingAlsoClearsASessionsProjectSeed() async throws {
        let path = try await f.copy()
        let session = f.session()
        session.projectBackgroundSeed = projectBackgroundValue(path: path)
        session.setBackgroundOverride(projectBackgroundValue(path: path))
        let store = f.appStore(sessions: [session])
        let model = store.backgroundImages
        await model.remove(try await entry(model, forPath: path))
        #expect(session.projectBackgroundSeed == projectBackgroundValue(path: nil))
        #expect(session.backgroundOverride == session.projectBackgroundSeed)
    }

    @Test func refusesWhileTheProjectsFileIsUnreadable() async throws {
        let path = try await f.copy(in: f.paneFolder)
        try Data("not json".utf8).write(to: f.projectsFile)
        let store = f.appStore()
        let model = store.backgroundImages
        await model.remove(try await entry(model, forPath: path))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(model.message != nil)
    }

    @Test func refusesWhileABackupExists() async throws {
        let path = try await f.copy(in: f.paneFolder)
        try f.saveProjectsFile()
        try Data("{}".utf8).write(to: f.backupFile)
        let store = f.appStore()
        let model = store.backgroundImages
        let plan = model.prepareRemoval(try await entry(model, forPath: path))
        #expect(plan.refusal != nil)
    }

    @Test func refusesWhenTheFileNamesTheImageForAnUnlistedProject() async throws {
        let path = try await f.copy()
        let store = f.appStore()
        try store.projectStore.upsert(f.project(name: "Here", background: nil))
        try ProjectStore(fileURL: f.projectsFile).upsert(f.project(name: "Elsewhere", background: projectBackgroundValue(path: path)))
        let model = store.backgroundImages
        await model.remove(try await entry(model, forPath: path))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(model.entries.count == 1)
    }

    @Test func allowsRemovalWhenTheProjectsFileIsAbsent() async throws {
        let path = try await f.copy(in: f.paneFolder)
        #expect(!FileManager.default.fileExists(atPath: f.projectsFile.path))
        let store = f.appStore()
        let model = store.backgroundImages
        #expect(model.prepareRemoval(try await entry(model, forPath: path)).refusal == nil)
    }

    @Test func aFailedProjectsWriteDeletesNothing() async throws {
        let path = try await f.copy()
        let session = f.session()
        session.setBackgroundOverride(projectBackgroundValue(path: path))
        let store = f.appStore(sessions: [session])
        try store.projectStore.upsert(f.project(background: projectBackgroundValue(path: path)))
        let model = store.backgroundImages
        let target = try await entry(model, forPath: path)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.base.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.base.path) }
        await model.remove(target)
        #expect(manager.fileExists(atPath: path))
        #expect(session.backgroundOverride == projectBackgroundValue(path: path))
        #expect(store.projectStore.projects[0].background == projectBackgroundValue(path: path))
    }

    @Test func removalPostsTheDidChangeNotification() async throws {
        let path = try await f.copy(in: f.paneFolder)
        let store = f.appStore()
        let model = store.backgroundImages
        let target = try await entry(model, forPath: path)
        var posts = 0
        let token = f.notificationCenter.addObserver(forName: .battyBackgroundImagesDidChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { posts += 1 }
        }
        defer { f.notificationCenter.removeObserver(token) }
        await model.remove(target)
        #expect(posts == 1)
    }

    @Test func removalPlanWarnsWhenASharedProjectUsesTheImage() async throws {
        let world = try SharedImageWorld()
        let path = try await world.fixture.copy()
        try world.store.upsert(world.project(path: path))
        let model = world.appStore.backgroundImages
        await model.refresh()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        let entry = try #require(model.entries.first { $0.digest == digest })
        #expect(model.prepareRemoval(entry).keepsOnOtherMacs)
    }

    @Test func removalPlanDoesNotWarnForALocalProject() async throws {
        let world = try SharedImageWorld()
        let path = try await world.fixture.copy()
        try world.store.upsert(world.project(path: path, shared: false))
        let model = world.appStore.backgroundImages
        await model.refresh()
        let entry = try #require(model.entries.first)
        #expect(!model.prepareRemoval(entry).keepsOnOtherMacs)
    }

    @Test func removalPlanDoesNotWarnWithTheFeatureOff() async throws {
        let path = try await f.copy()
        let store = f.appStore()
        var project = f.project(background: projectBackgroundValue(path: path))
        project.isShared = true
        try store.projectStore.upsert(project)
        await store.backgroundImages.refresh()
        let entry = try #require(store.backgroundImages.entries.first)
        #expect(!store.backgroundImages.prepareRemoval(entry).keepsOnOtherMacs)
    }

    @Test func removalLeavesTheSharedCopyAlone() async throws {
        let world = try SharedImageWorld()
        let path = try await world.fixture.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        let project = world.project(path: path)
        try world.store.upsert(project)
        await world.pass()
        let model = world.appStore.backgroundImages
        await model.refresh()
        await model.remove(try #require(model.entries.first))
        await world.pass()
        #expect(world.fake.deletes.isEmpty)
        #expect(world.fake.hasFile(digest: digest))
        #expect(world.store.project(id: project.id)?.sharedImage == nil)
        #expect(world.store.project(id: project.id)?.background == projectBackgroundValue(path: nil))
    }
}
