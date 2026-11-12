// ProjectStoreTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

@MainActor
struct ProjectStoreTests {
    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-projects-\(UUID().uuidString)")
            .appendingPathComponent("projects.json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static let stamp = Date(timeIntervalSince1970: 1_750_000_000)

    private func project(_ name: String, id: UUID = UUID(), isShared: Bool = false) -> Project {
        Project(id: id, name: name, rootPath: "/tmp/\(name)", isShared: isShared, modifiedAt: Self.stamp)
    }

    private func store(_ url: URL, backend: (any ProjectSyncBackend)? = nil) -> ProjectStore {
        ProjectStore(fileURL: url, clock: { Self.stamp }, backend: backend, home: "/Users/test")
    }

    @Test func upsertDeleteAndReorderPersistThroughAFreshStore() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = store(url)
        let a = project("Alpha"), b = project("Beta"), c = project("Gamma")
        try store.upsert(a); try store.upsert(b); try store.upsert(c)
        #expect(ProjectStore(fileURL: url).projects == [a, b, c])

        var renamed = b
        renamed.name = "Beta Two"
        try store.upsert(renamed)
        try store.reorder([c.id, a.id])
        #expect(ProjectStore(fileURL: url).projects.map(\.name) == ["Gamma", "Alpha", "Beta Two"])

        try store.delete(id: a.id)
        #expect(ProjectStore(fileURL: url).projects.map(\.name) == ["Gamma", "Beta Two"])
        #expect(throws: ProjectStoreError.unknownProject(a.id)) { try store.delete(id: a.id) }
    }

    @Test func fileHasVersionAndProjectsTopLevel() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        try ProjectStore(fileURL: url).upsert(project("Alpha"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(object?["version"] as? Int == 1)
        #expect((object?["projects"] as? [Any])?.count == 1)
    }

    @Test func lookupByNameIsCaseInsensitive() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = store(url)
        let a = project("My App")
        try store.upsert(a)
        #expect(store.project(named: "my app")?.id == a.id)
        #expect(store.project(named: "MY APP ")?.id == a.id)
        #expect(store.project(named: "My") == nil)
        #expect(store.project(id: a.id) == a)
    }

    @Test func duplicateNamesAreRejectedCaseInsensitivelyAndChangeNothing() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = ProjectStore(fileURL: url)
        try store.upsert(project("Alpha"))
        #expect(throws: ProjectStoreError.duplicateName("ALPHA")) { try store.upsert(project("ALPHA")) }
        #expect(throws: ProjectStoreError.emptyName) { try store.upsert(project("  ")) }
        #expect(store.projects.count == 1)
        #expect(ProjectStore(fileURL: url).projects.count == 1)
    }

    @Test func upsertingTheSameProjectKeepsItsOwnNameAndPosition() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = ProjectStore(fileURL: url)
        let a = project("Alpha"), b = project("Beta")
        try store.upsert(a); try store.upsert(b)
        var edited = a
        edited.name = "alpha"
        try store.upsert(edited)
        #expect(store.projects.map(\.name) == ["alpha", "Beta"])
    }

    @Test func corruptFileLoadsEmptyIsNotOverwrittenUntilSaveThenKeptAsBak() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: url)
        let store = ProjectStore(fileURL: url)
        #expect(store.projects.isEmpty)
        #expect(try Data(contentsOf: url) == garbage)

        try store.upsert(project("Alpha"))
        let bak = url.deletingLastPathComponent().appendingPathComponent("projects.json.bak")
        #expect(try Data(contentsOf: bak) == garbage)
        #expect(ProjectStore(fileURL: url).projects.map(\.name) == ["Alpha"])
    }

    @Test func oneBadProjectDoesNotDropTheOthersAndOriginalIsBackedUp() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let good = project("Good")
        let goodJSON = String(decoding: try ProjectsFile.encoder.encode(good), as: UTF8.self)
        let bad = #"{"id":"22222222-2222-2222-2222-222222222222","name":"Bad","rootPath":"/tmp/bad","layout":{"root":{"type":"pane","pane":{"kind":"hologram"}}}}"#
        let original = Data(#"{"version":1,"projects":[\#(bad),\#(goodJSON)]}"#.utf8)
        try original.write(to: url)

        let store = ProjectStore(fileURL: url)
        #expect(store.projects == [good])
        try store.upsert(project("Other"))
        let bak = url.deletingLastPathComponent().appendingPathComponent("projects.json.bak")
        #expect(try Data(contentsOf: bak) == original)
    }

    @Test func newerVersionFileIsPreservedAsBakOnFirstSave() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let good = project("Good")
        let goodJSON = String(decoding: try ProjectsFile.encoder.encode(good), as: UTF8.self)
        let original = Data(#"{"version":2,"future":true,"projects":[\#(goodJSON)]}"#.utf8)
        try original.write(to: url)
        let store = ProjectStore(fileURL: url)
        #expect(store.projects == [good])
        try store.upsert(project("Other"))
        let bak = url.deletingLastPathComponent().appendingPathComponent("projects.json.bak")
        #expect(try Data(contentsOf: bak) == original)
    }

    @Test func duplicateNameAndIdEntriesAreDroppedAndOriginalBackedUp() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = project("Alpha")
        let sameName = project("ALPHA")
        let sameID = Project(id: first.id, name: "Different", rootPath: "/tmp/d")
        func json(_ p: Project) throws -> String { String(decoding: try ProjectsFile.encoder.encode(p), as: UTF8.self) }
        let original = Data(#"{"version":1,"projects":[\#(try json(first)),\#(try json(sameName)),\#(try json(sameID))]}"#.utf8)
        try original.write(to: url)
        let store = ProjectStore(fileURL: url)
        #expect(store.projects == [first])
        try store.upsert(project("Beta"))
        let bak = url.deletingLastPathComponent().appendingPathComponent("projects.json.bak")
        #expect(try Data(contentsOf: bak) == original)
    }

    @Test func cleanLoadWritesNoBackup() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = ProjectStore(fileURL: url)
        try store.upsert(project("Alpha"))
        try store.upsert(project("Beta"))
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("projects.json.bak").path))
    }

    @Test func writesTempSiblingThenReplacesAndLeavesNoTempBehind() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let fm = RecordingFileManager()
        let store = ProjectStore(fileURL: url, fileManager: fm)
        try store.upsert(project("Alpha"))
        #expect(fm.calls == ["move"])
        try store.upsert(project("Beta"))
        #expect(fm.calls == ["move", "replace"])
        let dir = url.deletingLastPathComponent()
        #expect(fm.sources.allSatisfy { $0.deletingLastPathComponent() == dir && $0 != url })
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["projects.json"])
    }

    @Test func failedReplaceLeavesOriginalIntactCleansTempAndRollsBack() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let fm = RecordingFileManager()
        let store = ProjectStore(fileURL: url, fileManager: fm)
        try store.upsert(project("Alpha"))
        let before = try Data(contentsOf: url)

        fm.failReplace = true
        #expect(throws: (any Error).self) { try store.upsert(project("Beta")) }
        #expect(try Data(contentsOf: url) == before)
        #expect(store.projects.map(\.name) == ["Alpha"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["projects.json"])
    }

    @Test func canonicalURLIsPerVariant() throws {
        let beta = try ProjectStore.canonicalFileURL(bundleIdentifier: "co.sstools.Batty.beta")
        let prod = try ProjectStore.canonicalFileURL(bundleIdentifier: "co.sstools.Batty")
        #expect(beta.pathComponents.suffix(2) == ["Batty Beta", "projects.json"])
        #expect(prod.pathComponents.suffix(2) == ["Batty", "projects.json"])
    }

    @Test func neverReadingTheProjectStoreBuildsNothingAndTouchesNoFile() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let defaults = UserDefaults(suiteName: "ProjectStoreTests-\(UUID().uuidString)")!
        let app = AppStateStore(preferences: defaults, projectsFileURL: url)
        _ = app.addSession(title: "S")
        #expect(!app.projectStoreIsConstructed)
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    @Test func withoutTheEntitlementTheStoreHasNoSyncState() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let defaults = UserDefaults(suiteName: "ProjectStoreTests-\(UUID().uuidString)")!
        let app = AppStateStore(preferences: defaults, projectsFileURL: url)
        #expect(!ProjectSyncEntitlement.isPresent(), "unit-test builds are signed without the iCloud entitlement")
        #expect(app.projectStore.syncTask == nil)
    }

    @Test func theDefaultFactoryNeverBuildsTheICloudBackendInATestProcess() {
        #expect(ProjectSyncEntitlement.isTestProcess())
        var made = 0
        let make: () -> any ProjectSyncBackend = { made += 1; return LocalOnlyProjectSyncBackend() }
        #expect(AppStateStore.defaultProjectSyncBackend(isTestProcess: true, hasEntitlement: true, make: make) == nil)
        #expect(AppStateStore.defaultProjectSyncBackend(isTestProcess: false, hasEntitlement: false, make: make) == nil)
        #expect(made == 0)
        #expect(AppStateStore.defaultProjectSyncBackend(isTestProcess: false, hasEntitlement: true, make: make) != nil)
        #expect(made == 1)

        let url = makeTempURL()
        defer { cleanup(url) }
        let defaults = UserDefaults(suiteName: "ProjectStoreTests-\(UUID().uuidString)")!
        let app = AppStateStore(preferences: defaults, projectsFileURL: url)
        #expect(app.projectSyncBackendFactory() == nil)
    }

    @Test func theStoreBuildsTheBackendFromTheFactoryOnce() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let defaults = UserDefaults(suiteName: "ProjectStoreTests-\(UUID().uuidString)")!
        let app = AppStateStore(preferences: defaults, projectsFileURL: url)
        var built = 0
        app.projectSyncBackendFactory = { built += 1; return LocalOnlyProjectSyncBackend() }
        #expect(app.projectStore.syncTask != nil)
        _ = app.projectStore
        #expect(built == 1)
    }

    @Test func aMalformedLastOpenedAtOnDiskKeepsEveryProject() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let layout = #""layout":{"root":{"type":"pane","pane":{"kind":"terminal"}}}"#
        let json = """
        {"version":1,"projects":[
         {"id":"11111111-1111-1111-1111-111111111111","name":"Bad","rootPath":"/tmp/a","lastOpenedAt":"yesterday",\(layout)},
         {"id":"22222222-2222-2222-2222-222222222222","name":"Good","rootPath":"/tmp/b","lastOpenedAt":"2023-11-14T22:13:20Z",\(layout)}
        ]}
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)

        let store = ProjectStore(fileURL: url)

        #expect(store.projects.map(\.name) == ["Bad", "Good"])
        #expect(store.projects[0].lastOpenedAt == nil)
        #expect(store.projects[1].lastOpenedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test(arguments: [
        #"{"version":1,"projects":[{"id":"11111111-1111-1111-1111-111111111111","name":"Keep","rootPath":"/tmp/a","layout":{"root":{"type":"pane","pane":{"kind":"terminal"}}}},{"id":"22222222-2222-2222-2222-222222222222","name":"Dropped","rootPath":"relative","layout":{"root":{"type":"pane","pane":{"kind":"terminal"}}}}]}"#,
        #"{"version":99,"projects":[{"id":"11111111-1111-1111-1111-111111111111","name":"Keep","rootPath":"/tmp/a","layout":{"root":{"type":"pane","pane":{"kind":"terminal"}}}}]}"#,
    ])
    func recordOpenOnAFileNotFullyLoadedUpdatesMemoryOnly(json: String) throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(json.utf8)
        try original.write(to: url)
        let store = ProjectStore(fileURL: url)
        let keep = try #require(store.projects.first)
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        try store.recordOpen(id: keep.id, at: date)

        #expect(store.project(id: keep.id)?.lastOpenedAt == date)
        #expect(try Data(contentsOf: url) == original, "the file is byte-for-byte untouched")
        let backup = url.deletingLastPathComponent().appendingPathComponent(ProjectStore.backupFileName)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func recordOpenWritesTheDateToMemoryAndDiskAndRejectsAnUnknownId() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = ProjectStore(fileURL: url)
        let a = project("A"), b = project("B")
        try store.upsert(a)
        try store.upsert(b)
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)

        try store.recordOpen(id: b.id, at: date)

        #expect(store.project(id: b.id)?.lastOpenedAt == date)
        #expect(store.project(id: a.id)?.lastOpenedAt == nil)
        #expect(store.projects.map(\.name) == ["A", "B"], "store order is untouched")
        #expect(ProjectStore(fileURL: url).project(id: b.id)?.lastOpenedAt == date)
        let unknown = UUID()
        #expect(throws: ProjectStoreError.unknownProject(unknown)) {
            try store.recordOpen(id: unknown, at: date)
        }
    }

    @Test func buildsTheStoreLazilyOnInjectedPath() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let defaults = UserDefaults(suiteName: "ProjectStoreTests-\(UUID().uuidString)")!
        let app = AppStateStore(preferences: defaults, projectsFileURL: url)
        #expect(!app.projectStoreIsConstructed)
        let store = app.projectStore
        #expect(app.projectStoreIsConstructed)
        #expect(store.url == url)
        #expect(app.projectStore === store)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

private final class RecordingFileManager: FileManager, @unchecked Sendable {
    nonisolated(unsafe) var calls: [String] = []
    nonisolated(unsafe) var sources: [URL] = []
    nonisolated(unsafe) var failReplace = false

    nonisolated override init() { super.init() }

    nonisolated override func replaceItem(at originalItemURL: URL, withItemAt newItemURL: URL, backupItemName: String?, options: FileManager.ItemReplacementOptions = [], resultingItemURL resultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        calls.append("replace")
        sources.append(newItemURL)
        if failReplace { throw CocoaError(.fileWriteUnknown) }
        try super.replaceItem(at: originalItemURL, withItemAt: newItemURL, backupItemName: backupItemName, options: options, resultingItemURL: resultingURL)
    }

    nonisolated override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        calls.append("move")
        sources.append(srcURL)
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

@MainActor
struct ProjectStoreSharedImageTests {
    private static let stamp = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-projects-\(UUID().uuidString)")
            .appendingPathComponent("projects.json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static let digestA = String(repeating: "a", count: 64)
    private static let digestB = String(repeating: "b", count: 64)
    private static func path(_ digest: String, name: String = "Harbor") -> String { "/images/\(digest)/\(name).png" }
    private static func background(_ path: String?) -> TerminalBackgroundSettings { projectBackgroundValue(path: path) }

    private func imageStore(_ url: URL, backend: (any ProjectSyncBackend)? = LocalOnlyProjectSyncBackend(isAvailable: true), enabled: Bool = true) -> ProjectStore {
        ProjectStore(fileURL: url, clock: { Self.stamp }, backend: backend, home: "/Users/test", sharedImagesEnabled: enabled)
    }

    private func sharedProject(path: String?, sharedImage: ProjectSharedImage? = nil) -> Project {
        Project(name: "Shared", rootPath: "/tmp/shared", isShared: true, background: Self.background(path), sharedImage: sharedImage)
    }

    @Test func forSaveNamesAPickedImage() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let store = imageStore(url)
        var project = sharedProject(path: Self.path(Self.digestA))
        try store.upsert(project)
        #expect(store.projects[0].sharedImage == .named(digest: Self.digestA, name: "Harbor"))
        project.background = Self.background(Self.path(Self.digestB, name: "New"))
        try store.upsert(project)
        #expect(store.projects[0].sharedImage == .named(digest: Self.digestB, name: "New"))
    }

    @Test func forSaveKeepsPendingOnAnUnrelatedEdit() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let store = imageStore(url)
        let pending = ProjectSharedImage.named(digest: Self.digestB, name: "Pending")
        let project = sharedProject(path: Self.path(Self.digestA))
        try store.upsert(project)
        var edited = store.projects[0]
        edited.sharedImage = pending
        try store.upsert(edited)
        edited.name = "Renamed"
        try store.upsert(edited)
        #expect(store.projects[0].sharedImage == pending)
        #expect(store.projects[0].background?.imagePath == Self.path(Self.digestA))
    }

    @Test func noneOnAnImageBecomesRemoved() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = imageStore(url, backend: backend)
        var project = sharedProject(path: Self.path(Self.digestA))
        try store.upsert(project)
        project = store.projects[0]
        project.background = Self.background(nil)
        try store.upsert(project)
        #expect(store.projects[0].sharedImage == .removed)
        guard case .record(let record)? = backend.snapshot()[project.id] else { Issue.record("no record"); return }
        #expect(record.background?.image == .removed)
    }

    @Test func decliningPendingBecomesRemoved() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let store = imageStore(url)
        var project = sharedProject(path: nil, sharedImage: .named(digest: Self.digestA, name: "Pending"))
        try store.upsert(project)
        #expect(store.projects[0].sharedImage == .named(digest: Self.digestA, name: "Pending"))
        project = store.projects[0]
        project.sharedImage = nil
        try store.upsert(project)
        #expect(store.projects[0].sharedImage == .removed)
    }

    @Test func aPickAfterRemovedNamesTheImage() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let store = imageStore(url)
        var project = sharedProject(path: nil, sharedImage: .removed)
        try store.upsert(project)
        project = store.projects[0]
        project.background = Self.background(Self.path(Self.digestA))
        try store.upsert(project)
        #expect(store.projects[0].sharedImage == .named(digest: Self.digestA, name: "Harbor"))
    }

    @Test func followClearsTheSharedImage() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = imageStore(url, backend: backend)
        var project = sharedProject(path: Self.path(Self.digestA))
        try store.upsert(project)
        project = store.projects[0]
        project.background = nil
        try store.upsert(project)
        #expect(store.projects[0].sharedImage == nil)
        guard case .record(let record)? = backend.snapshot()[project.id] else { Issue.record("no record"); return }
        #expect(record.background == nil)
    }

    @Test func aSaveAfterRemoveInBackgroundImagesPublishesUnspecified() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = imageStore(url, backend: backend)
        try store.upsert(sharedProject(path: Self.path(Self.digestA)))
        try store.clearBackgroundImage(digest: Self.digestA)
        #expect(store.projects[0].sharedImage == nil)
        try store.upsert(store.projects[0])
        guard case .record(let record)? = backend.snapshot()[store.projects[0].id] else { Issue.record("no record"); return }
        #expect(record.background?.image == .unspecified)
        #expect(record.background?.settings == Self.background(nil))
    }

    @Test func setSharedTrueNamesTheImage() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = imageStore(url, backend: backend)
        var project = sharedProject(path: Self.path(Self.digestA))
        project.isShared = false
        try store.upsert(project)
        #expect(store.projects[0].sharedImage == nil)
        try store.setShared(id: project.id, true)
        #expect(store.projects[0].sharedImage == .named(digest: Self.digestA, name: "Harbor"))
        guard case .record(let record)? = backend.snapshot()[project.id] else { Issue.record("no record"); return }
        #expect(record.background?.image == .named(digest: Self.digestA, name: "Harbor"))
    }

    @Test func setSharedFalseClearsTheSharedImage() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let store = imageStore(url)
        let project = sharedProject(path: Self.path(Self.digestA))
        try store.upsert(project)
        try store.setShared(id: project.id, false)
        #expect(store.projects[0].sharedImage == nil)
        #expect(store.projects[0].background?.imagePath == Self.path(Self.digestA))
    }

    @Test func setResolvedDoesNotStampOrPublish() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        var now = Self.stamp
        let store = ProjectStore(fileURL: url, clock: { now }, backend: backend, home: "/Users/test", sharedImagesEnabled: true)
        try store.upsert(sharedProject(path: nil, sharedImage: .named(digest: Self.digestA, name: "Harbor")))
        let calls = backend.calls.count
        now = now.addingTimeInterval(500)
        #expect(try store.setResolvedSharedImage(id: store.projects[0].id, digest: Self.digestA, path: Self.path(Self.digestA)))
        #expect(store.projects[0].background == Self.background(Self.path(Self.digestA)))
        #expect(store.projects[0].modifiedAt == Self.stamp)
        #expect(backend.calls.count == calls)
        #expect(ProjectStore(fileURL: url).projects[0].background?.imagePath == Self.path(Self.digestA))
    }

    @Test func setResolvedIgnoresAnOutdatedDigest() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let store = imageStore(url)
        try store.upsert(sharedProject(path: Self.path(Self.digestB, name: "Picked")))
        #expect(try !store.setResolvedSharedImage(id: store.projects[0].id, digest: Self.digestA, path: Self.path(Self.digestA)))
        #expect(store.projects[0].background?.imagePath == Self.path(Self.digestB, name: "Picked"))
    }

    @Test func upgradeLaunchPublishesNothing() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        try imageStore(url, enabled: false).upsert(sharedProject(path: Self.path(Self.digestA)))
        let before = try Data(contentsOf: url)
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = imageStore(url, backend: backend)
        #expect(store.projects[0].sharedImage == nil)
        #expect(store.projects[0].modifiedAt == Self.stamp)
        #expect(backend.calls.isEmpty)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aLocalProjectsFileIsUnchangedByThisField() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        var local = sharedProject(path: Self.path(Self.digestA))
        local.isShared = false
        try imageStore(url, backend: nil).upsert(local)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("sharedImage"))
        #expect(ProjectStore(fileURL: url).projects[0].sharedImage == nil)
    }

    @Test func aBadSharedImageInTheFileCostsOnlyThatField() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"version":1,"projects":[{"id":"\#(UUID().uuidString)","name":"N","rootPath":"/tmp/n","layout":{"root":{"type":"pane","pane":{"kind":"terminal","tabs":[]}}},"color":0,"symbol":"folder","sharedImage":{"digest":"../x"}}]}"#
        try Data(json.utf8).write(to: url)
        let store = ProjectStore(fileURL: url)
        #expect(store.projects.count == 1)
        #expect(store.projects[0].sharedImage == nil)
    }

    @Test func sharedImagesOffChangesNoRecordOrFile() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = imageStore(url, backend: backend, enabled: false)
        let project = sharedProject(path: Self.path(Self.digestA))
        try store.upsert(project)
        #expect(store.projects[0].sharedImage == nil)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("sharedImage"))
        guard case .record(let record)? = backend.snapshot()[project.id] else { Issue.record("no record"); return }
        #expect(record.background?.image == .unspecified)
        #expect(!String(decoding: try ProjectsFile.encoder.encode(record), as: UTF8.self).contains("imageDigest"))
    }

    @Test func mergeWithSharedImagesOffLeavesTheImageAlone() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = imageStore(url, backend: backend, enabled: false)
        let project = sharedProject(path: Self.path(Self.digestA))
        try store.upsert(project)
        var record = store.projects[0].syncRecord(home: "/Users/test")
        record.modifiedAt = Self.stamp.addingTimeInterval(10)
        record.background = ProjectSyncBackground(secondBackgroundValue(path: nil), image: .removed)
        backend.receive([record.id: .record(record)])
        store.mergeRemote()
        #expect(store.projects[0].background == secondBackgroundValue(path: Self.path(Self.digestA)))
        #expect(store.projects[0].sharedImage == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func defaultSharedImageTransportNeedsEntitlementFlagAndNoTests(isTestProcess: Bool, hasEntitlement: Bool) {
        for isEnabled in [false, true] {
            var built = false
            let transport = AppStateStore.defaultSharedImageTransport(
                isTestProcess: isTestProcess, hasEntitlement: hasEntitlement, isEnabled: isEnabled,
                make: { built = true; return FakeSharedImageTransport() })
            let expected = !isTestProcess && hasEntitlement && isEnabled
            #expect((transport != nil) == expected)
            #expect(built == expected)
        }
    }

    @Test func clearBackgroundImageClearsTabPathsWithoutStamping() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let store = imageStore(url)
        let layout = ProjectLayout(root: .pane(.terminal(tabs: [ProjectTab(background: Self.background(Self.path(Self.digestA))), ProjectTab(background: Self.background(Self.path(Self.digestB)))])))
        try store.upsert(Project(name: "Tabs", rootPath: "/tmp/tabs", layout: layout))
        let stamped = store.projects[0].modifiedAt
        try store.clearBackgroundImage(digest: Self.digestA)
        #expect(store.projects[0].layout.panes[0].tabs.map(\.background) == [Self.background(nil), Self.background(Self.path(Self.digestB))])
        #expect(store.projects[0].modifiedAt == stamped)
        #expect(ProjectStore(fileURL: url).projects[0].layout.panes[0].tabs[0].background == Self.background(nil))
    }

    @Test func fileNamesATabImageTheListDoesNot() throws {
        let url = makeTempURL(); defer { cleanup(url) }
        let store = imageStore(url)
        try store.upsert(Project(name: "Mine", rootPath: "/tmp/mine"))
        let layout = ProjectLayout(root: .pane(.terminal(tabs: [ProjectTab(background: Self.background(Self.path(Self.digestA)))])))
        try imageStore(url).upsert(Project(name: "Theirs", rootPath: "/tmp/theirs", layout: layout))
        #expect(store.fileNamesImageTheListDoesNot(digest: Self.digestA))
        #expect(!store.fileNamesImageTheListDoesNot(digest: Self.digestB))
    }
}
