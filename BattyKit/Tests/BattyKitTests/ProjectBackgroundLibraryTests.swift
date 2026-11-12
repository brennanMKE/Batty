// ProjectBackgroundLibraryTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct ProjectBackgroundLibraryTests {
    private func reclaim(_ fixture: ProjectBackgroundFixture, _ store: ProjectStore, inUse: Set<String> = []) async throws {
        let task = try #require(fixture.library.reclaim(store: store, inUse: inUse))
        await task.value
    }

    @Test func directoryIsBesideTheProjectsFileAndOutsideTerminalBackgrounds() {
        let file = URL(fileURLWithPath: "/tmp/variant/projects.json")
        #expect(ProjectBackgroundLibrary.directory(forProjectsFile: file).path == "/tmp/variant/ProjectBackgrounds")
        let fallback = ProjectBackgroundLibrary.directory(forProjectsFile: nil)
        #expect(fallback.lastPathComponent == "ProjectBackgrounds")
        #expect(!fallback.path.contains("TerminalBackgrounds"))
    }

    @Test func initTouchesNoFiles() throws {
        let fixture = try ProjectBackgroundFixture()
        _ = fixture.library
        #expect(!FileManager.default.fileExists(atPath: fixture.projectFolder.path))
    }

    @Test func reclaimRemovesADeletedProjectsImage() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy()
        try fixture.age(folderOf: path)
        let store = ProjectStore(fileURL: fixture.projectsFile)
        let project = fixture.project(background: projectBackgroundValue(path: path))
        try store.upsert(project)
        try store.delete(id: project.id)
        try await reclaim(fixture, store)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func reclaimRemovesAReplacedImage() async throws {
        let fixture = try ProjectBackgroundFixture()
        let old = try await fixture.copy()
        let new = try await fixture.copy(width: 128)
        try fixture.age(folderOf: old)
        try fixture.age(folderOf: new)
        let store = ProjectStore(fileURL: fixture.projectsFile)
        var project = fixture.project(background: projectBackgroundValue(path: old))
        try store.upsert(project)
        project.background = projectBackgroundValue(path: new)
        try store.upsert(project)
        try await reclaim(fixture, store)
        #expect(!FileManager.default.fileExists(atPath: old))
        #expect(FileManager.default.fileExists(atPath: new))
    }

    @Test func reclaimKeepsEverySavedProjectsImage() async throws {
        let fixture = try ProjectBackgroundFixture()
        let first = try await fixture.copy()
        let second = try await fixture.copy(width: 128)
        try fixture.age(folderOf: first)
        try fixture.age(folderOf: second)
        let store = ProjectStore(fileURL: fixture.projectsFile)
        try store.upsert(fixture.project(name: "One", background: projectBackgroundValue(path: first)))
        try store.upsert(fixture.project(name: "Two", background: secondBackgroundValue(path: second)))
        try await reclaim(fixture, store)
        #expect(FileManager.default.fileExists(atPath: first))
        #expect(FileManager.default.fileExists(atPath: second))
    }

    @Test func reclaimKeepsAnOpenSessionsAndPanesImage() async throws {
        let fixture = try ProjectBackgroundFixture()
        let forSession = try await fixture.copy()
        let forPane = try await fixture.copy(width: 128)
        let unused = try await fixture.copy(width: 64)
        for path in [forSession, forPane, unused] { try fixture.age(folderOf: path) }
        let session = fixture.session()
        session.setBackgroundOverride(projectBackgroundValue(path: forSession))
        session.tree.allPanes[0].setBackgroundOverride(secondBackgroundValue(path: forPane))
        try fixture.saveProjectsFile()
        let store = fixture.appStore(sessions: [session])

        store.projectEditorDidClose()
        let task = try #require(store.projectBackgroundReclaim)
        await task.value

        #expect(FileManager.default.fileExists(atPath: forSession))
        #expect(FileManager.default.fileExists(atPath: forPane))
        #expect(!FileManager.default.fileExists(atPath: unused))
    }

    @Test func reclaimSkipsWhileTheFileIsNotFullyLoaded() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy()
        try fixture.age(folderOf: path)
        try Data(#"{"version":1,"projects":[{"unusable":true}]}"#.utf8).write(to: fixture.projectsFile)
        let store = ProjectStore(fileURL: fixture.projectsFile)
        #expect(fixture.library.reclaim(store: store, inUse: []) == nil)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func reclaimSkipsWhileABackupExists() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy()
        try fixture.age(folderOf: path)
        try fixture.saveProjectsFile()
        try Data("{}".utf8).write(to: fixture.backupFile)
        #expect(fixture.library.reclaim(store: ProjectStore(fileURL: fixture.projectsFile), inUse: []) == nil)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func reclaimSkipsWhenTheFileCannotBeRead() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy()
        try fixture.age(folderOf: path)
        try FileManager.default.createDirectory(at: fixture.projectsFile, withIntermediateDirectories: true)
        let store = ProjectStore(fileURL: fixture.projectsFile)
        #expect(fixture.library.reclaim(store: store, inUse: []) == nil)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func reclaimSkipsWhileTheStoreHasNotReadTheFile() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy()
        try fixture.age(folderOf: path)
        try ProjectStore(fileURL: fixture.projectsFile).upsert(fixture.project(background: nil))
        let gate = ProjectFileReadGate()
        gate.failure = ProjectFileReadGate.cocoaReadError(posix: .EIO)
        let store = ProjectStore(fileURL: fixture.projectsFile, readFile: { try gate.read($0) })
        gate.failure = nil
        #expect(fixture.library.reclaim(store: store, inUse: []) == nil)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func reclaimRunsAfterTheStoreHeals() async throws {
        let fixture = try ProjectBackgroundFixture()
        let unused = try await fixture.copy()
        let stored = try await fixture.copy(width: 128)
        try fixture.age(folderOf: unused)
        try fixture.age(folderOf: stored)
        try ProjectStore(fileURL: fixture.projectsFile).upsert(fixture.project(background: projectBackgroundValue(path: stored)))
        let gate = ProjectFileReadGate()
        gate.failure = ProjectFileReadGate.cocoaReadError(posix: .EIO)
        let store = ProjectStore(fileURL: fixture.projectsFile, readFile: { try gate.read($0) })
        gate.failure = nil
        store.retryLoadIfNeeded()
        try await reclaim(fixture, store)
        #expect(!FileManager.default.fileExists(atPath: unused))
        #expect(FileManager.default.fileExists(atPath: stored))
    }

    @Test func reclaimSkipsWhenTheFileIsAbsent() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy()
        try fixture.age(folderOf: path)
        let store = ProjectStore(fileURL: fixture.projectsFile)
        #expect(fixture.library.reclaim(store: store, inUse: []) == nil)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    /// The store loaded a good file, and something changed the file afterward.
    @Test(arguments: [
        "not json",
        #"{"version":1,"projects":[{"unusable":true}]}"#,
        #"{"version":2,"projects":[]}"#,
    ])
    func reclaimSkipsWhenTheFileBecameUntrustworthy(contents: String) async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy()
        try fixture.age(folderOf: path)
        try fixture.saveProjectsFile()
        let store = ProjectStore(fileURL: fixture.projectsFile)
        try Data(contents.utf8).write(to: fixture.projectsFile)
        #expect(fixture.library.reclaim(store: store, inUse: []) == nil)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func reclaimKeepsAnImageOnlyTheFileNames() async throws {
        let fixture = try ProjectBackgroundFixture()
        let named = try await fixture.copy()
        let unused = try await fixture.copy(width: 128)
        for path in [named, unused] { try fixture.age(folderOf: path) }
        let store = ProjectStore(fileURL: fixture.projectsFile)
        try ProjectStore(fileURL: fixture.projectsFile).upsert(fixture.project(background: projectBackgroundValue(path: named)))
        #expect(store.projects.isEmpty)
        try await reclaim(fixture, store)
        #expect(FileManager.default.fileExists(atPath: named))
        #expect(!FileManager.default.fileExists(atPath: unused))
    }

    @Test func reclaimKeepsAnImageOnlyTheListNames() async throws {
        let fixture = try ProjectBackgroundFixture()
        let named = try await fixture.copy()
        let unused = try await fixture.copy(width: 128)
        for path in [named, unused] { try fixture.age(folderOf: path) }
        let store = ProjectStore(fileURL: fixture.projectsFile)
        let other = ProjectStore(fileURL: fixture.projectsFile)
        try store.upsert(fixture.project(background: projectBackgroundValue(path: named)))
        try other.upsert(fixture.project(name: "Other", background: nil))
        try await reclaim(fixture, store)
        #expect(FileManager.default.fileExists(atPath: named))
        #expect(!FileManager.default.fileExists(atPath: unused))
    }

    @Test func reclaimKeepsAFolderAPendingProjectNames() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy()
        try fixture.age(folderOf: path)
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        let store = ProjectStore(fileURL: fixture.projectsFile, sharedImagesEnabled: true)
        var project = fixture.project(background: projectBackgroundValue(path: nil))
        project.isShared = true
        project.sharedImage = .named(digest: digest, name: "photo")
        try store.upsert(project)
        try await reclaim(fixture, store)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func reclaimKeepsAFolderTheFileNamesForAPendingProject() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy()
        try fixture.age(folderOf: path)
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        let store = ProjectStore(fileURL: fixture.projectsFile, sharedImagesEnabled: true)
        try store.upsert(fixture.project(name: "Mine", background: nil))
        var other = fixture.project(name: "Other Copy", background: projectBackgroundValue(path: nil))
        other.isShared = true
        other.sharedImage = .named(digest: digest, name: "photo")
        try ProjectStore(fileURL: fixture.projectsFile, sharedImagesEnabled: true).upsert(other)
        #expect(store.project(id: other.id) == nil)
        try await reclaim(fixture, store)
        #expect(FileManager.default.fileExists(atPath: path))
    }
    private func tabProject(_ fixture: ProjectBackgroundFixture, name: String = "Tabbed", path: String) -> Project {
        fixture.project(name: name, background: nil, layout: ProjectLayout(root: .pane(.terminal(tabs: [ProjectTab(), ProjectTab(background: secondBackgroundValue(path: path))]))))
    }

    @Test func reclaimKeepsATabOnlyImage() async throws {
        let fixture = try ProjectBackgroundFixture()
        let named = try await fixture.copy()
        let unused = try await fixture.copy(width: 128)
        for path in [named, unused] { try fixture.age(folderOf: path) }
        let store = ProjectStore(fileURL: fixture.projectsFile)
        try store.upsert(tabProject(fixture, path: named))
        try await reclaim(fixture, store)
        #expect(FileManager.default.fileExists(atPath: named))
        #expect(!FileManager.default.fileExists(atPath: unused))
    }

    @Test func reclaimKeepsATabImageOnlyTheFileNames() async throws {
        let fixture = try ProjectBackgroundFixture()
        let named = try await fixture.copy()
        let unused = try await fixture.copy(width: 128)
        for path in [named, unused] { try fixture.age(folderOf: path) }
        let store = ProjectStore(fileURL: fixture.projectsFile)
        try ProjectStore(fileURL: fixture.projectsFile).upsert(tabProject(fixture, path: named))
        #expect(store.projects.isEmpty)
        try await reclaim(fixture, store)
        #expect(FileManager.default.fileExists(atPath: named))
        #expect(!FileManager.default.fileExists(atPath: unused))
    }

    @Test func reclaimKeepsAnOpenTabsImage() async throws {
        let fixture = try ProjectBackgroundFixture()
        let forTab = try await fixture.copy()
        let unused = try await fixture.copy(width: 64)
        for path in [forTab, unused] { try fixture.age(folderOf: path) }
        let session = fixture.session()
        let pane = session.tree.allPanes[0]
        pane.addTab()
        pane.tabs[0].setBackgroundOverride(projectBackgroundValue(path: forTab))
        try fixture.saveProjectsFile()
        let store = fixture.appStore(sessions: [session])

        store.projectEditorDidClose()
        let task = try #require(store.projectBackgroundReclaim)
        await task.value

        #expect(FileManager.default.fileExists(atPath: forTab))
        #expect(!FileManager.default.fileExists(atPath: unused))
    }
    private func cachedCopy(_ fixture: ProjectBackgroundFixture, width: Int = 96) throws -> String {
        let bytes = try BackgroundTestImage.encoded(width: width, height: 64)
        let digest = BackgroundTestImage.digest(of: bytes)
        #expect(TerminalBackgroundImageImporter.storeVerified(bytes: bytes, digest: digest, name: "Cached", into: fixture.downloadedFolder) == .usable)
        return try #require(TerminalBackgroundImageImporter.existingCopy(digest: digest, in: fixture.downloadedFolder))
    }

    @Test func reclaimNeverTouchesTheDownloadedFolder() async throws {
        let fixture = try ProjectBackgroundFixture()
        let cached = try cachedCopy(fixture)
        try fixture.age(folderOf: cached)
        let store = ProjectStore(fileURL: fixture.projectsFile)
        try store.upsert(fixture.project(background: nil))
        try await reclaim(fixture, store)
        #expect(FileManager.default.fileExists(atPath: cached))
    }

    @Test func reclaimKeepsAFolderATabDigestNames() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy()
        let unused = try await fixture.copy(width: 128)
        for each in [path, unused] { try fixture.age(folderOf: each) }
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        let store = ProjectStore(fileURL: fixture.projectsFile)
        let tab = ProjectTab(background: projectBackgroundValue(path: nil), image: .custom(digest: digest, name: "Pending"))
        try store.upsert(fixture.project(background: nil, layout: ProjectLayout(root: .pane(.terminal(tabs: [tab])))))
        try await reclaim(fixture, store)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: unused))
    }

    @Test func checkedAcceptsACachedTabPath() throws {
        let fixture = try ProjectBackgroundFixture()
        let cached = try cachedCopy(fixture)
        #expect(fixture.library.checked(projectBackgroundValue(path: cached)).problem == nil)
        let live = ProjectBackgroundLibrary(directory: fixture.projectFolder, adoptableFrom: [], downloadedDirectory: fixture.downloadedFolder)
        #expect(live.imageState(ofPath: cached) == .usable)
        #expect(ProjectBackgroundLibrary(directory: fixture.projectFolder, adoptableFrom: []).imageState(ofPath: cached) != .usable)
    }

    @Test func adoptLeavesACachedPathInPlace() throws {
        let fixture = try ProjectBackgroundFixture()
        let cached = try cachedCopy(fixture)
        #expect(fixture.library.adopt(path: cached) == cached)
        #expect(!FileManager.default.fileExists(atPath: fixture.projectFolder.path))
    }
}
