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
