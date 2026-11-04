// ProjectStoreReadFailureTests.swift

import Foundation
import Observation
import Testing
@testable import BattyKit

/// A temp folder holding a `projects.json` of three Projects. `cleanup` undoes
/// any mode or ACL first, because a mode `000` folder can't be removed.
@MainActor
private final class ReadFailureFixture {
    static let stamp = Date(timeIntervalSince1970: 1_750_000_000)
    static let seeded = ["One", "Two", "Three"]

    let folder: URL
    let file: URL
    let gate = ProjectFileReadGate()
    private(set) var bytes = Data()

    init(seeded: Bool = true) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("batty-read-failure-\(UUID().uuidString)")
        file = folder.appendingPathComponent("projects.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if seeded { try seed() }
    }

    func seed() throws {
        let store = ProjectStore(fileURL: file, clock: { Self.stamp }, home: "/Users/test")
        for name in Self.seeded { try store.upsert(project(name)) }
        bytes = try Data(contentsOf: file)
    }

    func cleanup() {
        try? setMode(0o755, folder)
        try? setMode(0o644, file)
        try? runChmod(["-N", file.path])
        try? FileManager.default.removeItem(at: folder)
    }

    func project(_ name: String, isShared: Bool = false) -> Project {
        Project(name: name, rootPath: "/tmp/\(name)", isShared: isShared, modifiedAt: Self.stamp)
    }

    /// A store that reads through the gate, failing at load if `failing` is set.
    func gatedStore(failing error: Error? = nil, backend: (any ProjectSyncBackend)? = nil) -> ProjectStore {
        gate.failure = error
        let gate = gate
        return ProjectStore(
            fileURL: file, clock: { Self.stamp }, backend: backend, home: "/Users/test",
            readFile: { try gate.read($0) })
    }

    func realStore(backend: (any ProjectSyncBackend)? = nil) -> ProjectStore {
        ProjectStore(fileURL: file, clock: { Self.stamp }, backend: backend, home: "/Users/test")
    }

    func setMode(_ mode: Int, _ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func runChmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    func denyRead() throws {
        try runChmod(["+a", "\(NSUserName()) deny read", file.path])
    }

    func removeACL() throws {
        try runChmod(["-N", file.path])
    }

    var backupFile: URL { folder.appendingPathComponent(ProjectStore.backupFileName) }
    var hasBackup: Bool { FileManager.default.fileExists(atPath: backupFile.path) }
    var diskNames: [String] { realStore().projects.map(\.name) }

    func fileBytesAreUnchanged() throws -> Bool {
        try Data(contentsOf: file) == bytes
    }

    var unreadableError: ProjectStoreError { .fileUnreadable(path: file.path) }

    static func incoming() -> [UUID: ProjectSyncEntry] {
        let id = UUID()
        return [id: .record(ProjectSyncRecord(
            id: id, name: "Shared", rootPath: "~/x", color: .blue, symbol: .folder,
            layout: .preset(.singlePane), runStartupCommandsOnOpen: false, modifiedAt: Date(timeIntervalSince1970: 1)))]
    }
}

nonisolated private final class ObservedFlag: @unchecked Sendable {
    var fired = false
}

/// Delivers one remote change and returns once the store has handled it.
@MainActor
private func deliver(_ backend: LocalOnlyProjectSyncBackend, to store: ProjectStore) async {
    backend.receive(ReadFailureFixture.incoming())
    backend.finishChanges()
    await store.syncTask?.value
}

@MainActor
struct ProjectStoreReadFailureTests {
    // MARK: Through the seam

    @Test(arguments: [POSIXErrorCode.EMFILE, .EIO, .EACCES])
    func transientReadFailureThenUpsertKeepsEveryProject(error: POSIXErrorCode) throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let store = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: error))
        #expect(store.projects.isEmpty)
        fixture.gate.failure = nil

        try store.upsert(fixture.project("New"))

        #expect(fixture.diskNames == ["One", "Two", "Three", "New"])
        #expect(!fixture.hasBackup)
    }

    @Test func transientReadFailureThenMergeKeepsEveryProject() async throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: .EMFILE), backend: backend)
        fixture.gate.failure = nil

        await deliver(backend, to: store)

        #expect(fixture.diskNames == ["One", "Two", "Three", "Shared"])
    }

    @Test func stillFailingReadRefusesEveryWrite() throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let store = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: .EIO))

        #expect(throws: fixture.unreadableError) { try store.upsert(fixture.project("New")) }
        #expect(throws: fixture.unreadableError) { try store.reorder([]) }
        #expect(throws: fixture.unreadableError) { try store.save() }
        #expect(throws: fixture.unreadableError) { try store.delete(id: UUID()) }
        #expect(throws: fixture.unreadableError) { try store.setShared(id: UUID(), true) }
        #expect(throws: fixture.unreadableError) { try store.recordOpen(id: UUID(), at: Date()) }
        #expect(throws: fixture.unreadableError) { try store.recordApproval(id: UUID(), hash: "h") }

        #expect(try fixture.fileBytesAreUnchanged())
        #expect(store.projects.isEmpty)
    }

    @Test func stillFailingReadSkipsAMerge() async throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: .EIO), backend: backend)

        await deliver(backend, to: store)

        #expect(try fixture.fileBytesAreUnchanged())
        #expect(store.projects.isEmpty)
    }

    /// `writeFile`'s guard would also keep the file safe, so only a write to the
    /// list shows a merge got past its own check.
    @Test func aMergeWhileUnreadNeverTouchesTheList() async throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: .EIO), backend: backend)
        let changed = ObservedFlag()
        withObservationTracking { _ = store.projects } onChange: { changed.fired = true }

        await deliver(backend, to: store)

        #expect(!changed.fired)
    }

    @Test func sharedUpsertPublishesNothingWhileTheFileIsUnread() throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: .EIO), backend: backend)

        #expect(throws: fixture.unreadableError) { try store.upsert(fixture.project("New", isShared: true)) }

        #expect(backend.calls.isEmpty)
        #expect(try fixture.fileBytesAreUnchanged())
    }

    @Test func mergeWhileUnreadCallsNoBackendWrites() async throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: .EIO), backend: backend)

        await deliver(backend, to: store)

        #expect(backend.calls.isEmpty)
    }

    @Test func everyWriteAttemptRetriesTheRead() throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let store = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: .EIO))
        let afterLoad = fixture.gate.reads

        _ = try? store.upsert(fixture.project("New"))
        #expect(fixture.gate.reads == afterLoad + 1)
        _ = try? store.reorder([])
        #expect(fixture.gate.reads == afterLoad + 2)
    }

    @Test func aLoadedStoreDoesNotReadAgain() throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let clean = fixture.gatedStore()
        let afterLoad = fixture.gate.reads
        #expect(afterLoad == 1)
        try clean.upsert(fixture.project("New"))
        try clean.recordOpen(id: try #require(clean.project(named: "New")).id, at: ReadFailureFixture.stamp)
        clean.retryLoadIfNeeded()
        #expect(fixture.gate.reads == afterLoad)

        let healed = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: .EIO))
        fixture.gate.failure = nil
        healed.retryLoadIfNeeded()
        let afterHeal = fixture.gate.reads
        try healed.upsert(fixture.project("Newer"))
        try healed.recordOpen(id: try #require(healed.project(named: "One")).id, at: ReadFailureFixture.stamp)
        #expect(fixture.gate.reads == afterHeal)
    }

    @Test func retryLoadIfNeededHealsWithoutWriting() throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let store = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: .EIO))
        #expect(store.unreadableFilePath == fixture.file.path)
        fixture.gate.failure = nil

        store.retryLoadIfNeeded()

        #expect(store.projects.map(\.name) == ReadFailureFixture.seeded)
        #expect(store.unreadableFilePath == nil)
        #expect(try fixture.fileBytesAreUnchanged())
    }

    @Test func retryThatStillFailsKeepsRefusing() throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let store = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: .EIO))

        store.retryLoadIfNeeded()

        #expect(store.unreadableFilePath == fixture.file.path)
        #expect(throws: fixture.unreadableError) { try store.upsert(fixture.project("New")) }
        #expect(try fixture.fileBytesAreUnchanged())
    }

    @Test func aHealAppliesAMergeThatWasSkipped() async throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: .EIO), backend: backend)
        await deliver(backend, to: store)
        #expect(try fixture.fileBytesAreUnchanged())
        fixture.gate.failure = nil

        store.retryLoadIfNeeded()

        #expect(fixture.diskNames == ["One", "Two", "Three", "Shared"])
    }

    @Test func aHealedNameStillCountsAsADuplicate() throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let store = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: .EIO))
        fixture.gate.failure = nil

        #expect(throws: ProjectStoreError.duplicateName("one")) { try store.upsert(fixture.project("one")) }

        #expect(try fixture.fileBytesAreUnchanged())
    }

    @Test func readFailureThenFileDeletedBehavesAsFirstRun() throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let store = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: .EIO))
        try FileManager.default.removeItem(at: fixture.file)
        fixture.gate.failure = nil

        try store.upsert(fixture.project("New"))

        #expect(store.unreadableFilePath == nil)
        #expect(fixture.diskNames == ["New"])
        #expect(!fixture.hasBackup)
    }

    @Test func readFailureThenCorruptFileIsBackedUp() throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        let store = fixture.gatedStore(failing: ProjectFileReadGate.cocoaReadError(posix: .EIO))
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: fixture.file)
        fixture.gate.failure = nil

        try store.upsert(fixture.project("New"))

        #expect(try Data(contentsOf: fixture.backupFile) == corrupt)
        #expect(fixture.diskNames == ["New"])
    }

    // MARK: Real file states

    @Test func modeZeroRestoredBeforeUpsertKeepsEveryProject() throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        try fixture.setMode(0o000, fixture.file)
        let store = fixture.realStore()
        #expect(store.projects.isEmpty)
        try fixture.setMode(0o644, fixture.file)

        try store.upsert(fixture.project("New"))

        #expect(fixture.diskNames == ["One", "Two", "Three", "New"])
        #expect(!fixture.hasBackup)
    }

    @Test func modeZeroRestoredBeforeMergeKeepsEveryProject() async throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        try fixture.setMode(0o000, fixture.file)
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = fixture.realStore(backend: backend)
        try fixture.setMode(0o644, fixture.file)

        await deliver(backend, to: store)

        #expect(fixture.diskNames == ["One", "Two", "Three", "Shared"])
    }

    @Test func aclDenyReadStillInPlaceRefusesUpsert() throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        try fixture.denyRead()
        let store = fixture.realStore()

        #expect(throws: fixture.unreadableError) { try store.upsert(fixture.project("New")) }

        try fixture.removeACL()
        #expect(try fixture.fileBytesAreUnchanged())
    }

    @Test func modeZeroStillInPlaceRefusesUpsert() throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        try fixture.setMode(0o000, fixture.file)
        let store = fixture.realStore()

        #expect(throws: fixture.unreadableError) { try store.upsert(fixture.project("New")) }

        try fixture.setMode(0o644, fixture.file)
        #expect(try fixture.fileBytesAreUnchanged())
    }

    @Test func modeZeroStillInPlaceSkipsMerge() async throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        try fixture.setMode(0o000, fixture.file)
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = fixture.realStore(backend: backend)

        await deliver(backend, to: store)

        #expect(store.projects.isEmpty)
        try fixture.setMode(0o644, fixture.file)
        #expect(try fixture.fileBytesAreUnchanged())
    }

    @Test func modeTwoHundredStillInPlaceRefusesUpsert() throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        try fixture.setMode(0o200, fixture.file)
        let store = fixture.realStore()

        #expect(throws: fixture.unreadableError) { try store.upsert(fixture.project("New")) }

        try fixture.setMode(0o644, fixture.file)
        #expect(try fixture.fileBytesAreUnchanged())
    }

    @Test func unreadableParentFolderIsAFailureNotAFirstRun() throws {
        let fixture = try ReadFailureFixture()
        defer { fixture.cleanup() }
        try fixture.setMode(0o000, fixture.folder)
        let store = fixture.realStore()
        #expect(store.unreadableFilePath == fixture.file.path)
        #expect(throws: fixture.unreadableError) { try store.upsert(fixture.project("New")) }

        try fixture.setMode(0o755, fixture.folder)
        store.retryLoadIfNeeded()

        #expect(store.projects.map(\.name) == ReadFailureFixture.seeded)
        #expect(try fixture.fileBytesAreUnchanged())
    }

    @Test func pathThatIsADirectoryIsAFailureNotAFirstRun() throws {
        let fixture = try ReadFailureFixture(seeded: false)
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: true)
        let store = fixture.realStore()

        #expect(store.unreadableFilePath == fixture.file.path)
        #expect(throws: fixture.unreadableError) { try store.upsert(fixture.project("New")) }
    }

    // MARK: Missing file

    @Test func firstRunUpsertStillCreatesTheFile() throws {
        let fixture = try ReadFailureFixture(seeded: false)
        defer { fixture.cleanup() }
        let store = fixture.realStore()
        #expect(store.unreadableFilePath == nil)

        try store.upsert(fixture.project("New"))

        #expect(fixture.diskNames == ["New"])
        #expect(!fixture.hasBackup)
    }

    @Test func firstRunMergeStillCreatesTheFile() async throws {
        let fixture = try ReadFailureFixture(seeded: false)
        defer { fixture.cleanup() }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = fixture.realStore(backend: backend)

        await deliver(backend, to: store)

        #expect(fixture.diskNames == ["Shared"])
    }

    @Test func missingThenRestoredBeforeUpsertKeepsTheRestoredProjects() throws {
        let fixture = try ReadFailureFixture(seeded: false)
        defer { fixture.cleanup() }
        let store = fixture.realStore()
        try fixture.seed()

        try store.upsert(fixture.project("New"))

        #expect(fixture.diskNames == ["One", "Two", "Three", "New"])
    }

    @Test func missingThenRestoredBeforeMergeKeepsTheRestoredProjects() async throws {
        let fixture = try ReadFailureFixture(seeded: false)
        defer { fixture.cleanup() }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = fixture.realStore(backend: backend)
        try fixture.seed()

        await deliver(backend, to: store)

        #expect(fixture.diskNames == ["One", "Two", "Three", "Shared"])
    }

    @Test func missingThenRestoredCorruptIsBackedUp() throws {
        let fixture = try ReadFailureFixture(seeded: false)
        defer { fixture.cleanup() }
        let store = fixture.realStore()
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: fixture.file)

        try store.upsert(fixture.project("New"))

        #expect(try Data(contentsOf: fixture.backupFile) == corrupt)
        #expect(fixture.diskNames == ["New"])
    }

    @Test func missingThenRestoredButUnreadableRefuses() throws {
        let fixture = try ReadFailureFixture(seeded: false)
        defer { fixture.cleanup() }
        let store = fixture.realStore()
        try fixture.seed()
        try fixture.setMode(0o000, fixture.file)

        #expect(throws: fixture.unreadableError) { try store.upsert(fixture.project("New")) }

        try fixture.setMode(0o644, fixture.file)
        #expect(try fixture.fileBytesAreUnchanged())
    }
}

/// A directory at the file's path is a read failure that stays put, and needs
/// no mode change.
@MainActor
struct ProjectFileProblemXPCTests {
    @Test func aProblemNamesThePathAndOpenFailsWithIt() throws {
        let fixture = try ProjectBackgroundFixture()
        try FileManager.default.createDirectory(at: fixture.projectsFile, withIntermediateDirectories: true)
        let store = fixture.appStore()

        let problem = try #require(store.projectFileProblemForXPC())
        #expect(problem.contains(fixture.projectsFile.path))

        var outcome: AppStateStore.ProjectOpenXPCOutcome?
        let opened = store.openProjectForXPC(name: "Anything", openNew: false) { outcome = $0 }
        #expect(opened == nil)
        #expect(outcome == .failed(problem))
    }

    @Test func aGoodFileHasNoProblem() throws {
        let fixture = try ProjectBackgroundFixture()
        try ProjectStore(fileURL: fixture.projectsFile).upsert(fixture.project(background: nil))
        #expect(fixture.appStore().projectFileProblemForXPC() == nil)
    }
}
