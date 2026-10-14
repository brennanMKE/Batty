// ProjectSharingTests.swift

import AppKit
import BattyXPCCore
import Foundation
import SwiftUI
import Testing
@testable import BattyKit

nonisolated private let layoutJSON = #""layout":{"root":{"type":"pane","pane":{"kind":"terminal"}}}"#

@MainActor
struct ProjectSharingModelTests {
    private func roundTrip(_ project: Project) throws -> Project {
        try ProjectsFile.decoder.decode(Project.self, from: ProjectsFile.encoder.encode(project))
    }

    private func keys(of encodable: some Encodable) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: ProjectsFile.encoder.encode(encodable)) as? [String: Any]
        return Set(try #require(object).keys)
    }

    @Test func aProjectWithNoIsSharedKeyDecodesAsLocal() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Old","rootPath":"/tmp/a",\#(layoutJSON)}"#
        let decoded = try ProjectsFile.decoder.decode(Project.self, from: Data(json.utf8))
        #expect(!decoded.isShared)
        #expect(decoded.modifiedAt == nil)
    }

    @Test func isSharedAndModifiedAtRoundTripWithFractionalSeconds() throws {
        let stamp = Date(timeIntervalSince1970: 1_750_000_000.375)
        let shared = Project(name: "S", rootPath: "/tmp/s", isShared: true, modifiedAt: stamp)
        let decoded = try roundTrip(shared)
        #expect(decoded.isShared)
        #expect(decoded.modifiedAt == stamp)
        #expect(decoded == shared)
    }

    @Test func aLocalProjectWritesNoIsSharedKeyAndASharedOneWritesTrue() throws {
        let local = Project(name: "L", rootPath: "/tmp/l", modifiedAt: Date(timeIntervalSince1970: 1_750_000_000))
        let shared = Project(name: "S", rootPath: "/tmp/s", isShared: true)
        #expect(!(try keys(of: local)).contains("isShared"))
        #expect(try keys(of: local).contains("modifiedAt"))
        #expect(try keys(of: shared).contains("isShared"))
        #expect(!(try keys(of: shared)).contains("modifiedAt"))
    }

    @Test func anUnknownKeyInAProjectObjectIsIgnored() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Future","rootPath":"/tmp/a","isShared":true,"futureField":{"x":1},\#(layoutJSON)}"#
        let decoded = try ProjectsFile.decoder.decode(Project.self, from: Data(json.utf8))
        #expect(decoded.name == "Future")
        #expect(decoded.isShared)
    }

    @Test func aMalformedIsSharedOrModifiedAtDecodesAsLocalAndUndatedWithoutDroppingTheProject() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Odd","rootPath":"/tmp/a","isShared":"yes","modifiedAt":"yesterday",\#(layoutJSON)}"#
        let decoded = try ProjectsFile.decoder.decode(Project.self, from: Data(json.utf8))
        #expect(!decoded.isShared)
        #expect(decoded.modifiedAt == nil)
    }

    private func deviceStateProject() -> Project {
        Project(
            name: "Site", rootPath: "/Users/test/Developer/site", color: .violet, symbol: .chip,
            layout: .preset(.twoByTwoGrid), runStartupCommandsOnOpen: true,
            approvedCommandsHash: "secret-hash", lastOpenedAt: Date(timeIntervalSince1970: 1_650_000_000),
            isShared: true, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func theSyncRecordCarriesTheDefinitionAndNoDeviceState() throws {
        let project = deviceStateProject()
        let record = project.syncRecord(home: "/Users/test")
        let encoded = try keys(of: record)
        #expect(!encoded.contains("lastOpenedAt"))
        #expect(!encoded.contains("approvedCommandsHash"))
        #expect(!encoded.contains("isShared"))
        let text = String(decoding: try ProjectsFile.encoder.encode(record), as: UTF8.self)
        #expect(!text.contains("secret-hash"))
        #expect(record.rootPath == "~/Developer/site")
        #expect(record.name == "Site" && record.color == .violet && record.symbol == .chip)
        #expect(record.layout == project.layout && record.runStartupCommandsOnOpen)
        #expect(record.modifiedAt == project.modifiedAt)
    }

    @Test func aRecordRootIsStandardizedAfterDecoding() {
        var record = deviceStateProject().syncRecord(home: "/Users/test")
        record.rootPath = "~/a/../b"
        #expect(Project(syncRecord: record, home: "/Users/other").rootPath == "/Users/other/b")
        record.rootPath = "~/"
        #expect(Project(syncRecord: record, home: "/Users/other").rootPath == "/Users/other")
    }

    @Test func aProjectBuiltFromARecordIsSharedWithNoDeviceState() {
        let record = deviceStateProject().syncRecord(home: "/Users/test")
        let built = Project(syncRecord: record, home: "/Users/other")
        #expect(built.isShared)
        #expect(built.approvedCommandsHash == nil)
        #expect(built.lastOpenedAt == nil)
        #expect(built.rootPath == "/Users/other/Developer/site")
        #expect(built.id == record.id && built.modifiedAt == record.modifiedAt)
    }
}

/// Accepts or refuses `publish` on demand, recording what it kept.
@MainActor
final class SwitchableProjectSyncBackend: ProjectSyncBackend {
    var refusal: ProjectSyncError?
    private(set) var published: [ProjectSyncRecord] = []
    let isAvailable = true
    let snapshotIsAuthoritative = true
    let changes = AsyncStream<Void>.makeStream().stream
    var onSyncError: (@MainActor (ProjectSyncError) -> Void)?

    func snapshot() -> [UUID: ProjectSyncEntry] { [:] }
    func publish(_ record: ProjectSyncRecord) throws {
        if let refusal { throw refusal }
        published.append(record)
    }
    func withdraw(id: UUID) {}
    func tombstone(id: UUID, deletedAt: Date) {}
}

@MainActor
struct ProjectSharingStoreTests {
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private let home = "/Users/test"

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-sharing-\(UUID().uuidString)")
            .appendingPathComponent("projects.json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func project(_ name: String, shared: Bool = false, modified: Date? = nil) -> Project {
        Project(
            name: name, rootPath: "/Users/test/Developer/\(name)", color: .teal,
            approvedCommandsHash: "approved-\(name)", lastOpenedAt: Date(timeIntervalSince1970: 1_650_000_000),
            isShared: shared, modifiedAt: modified)
    }

    private func store(_ url: URL, _ clock: Clock, backend: (any ProjectSyncBackend)? = nil) -> ProjectStore {
        ProjectStore(fileURL: url, clock: { clock.now }, backend: backend, home: home)
    }

    @Test func setSharedPersistsThroughAFreshStoreAndStampsModifiedAtFromTheClock() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = store(url, clock)
        let a = project("Alpha")
        try store.upsert(a)
        clock.now = Date(timeIntervalSince1970: 1_800_000_000.5)

        try store.setShared(id: a.id, true)

        let reloaded = try #require(ProjectStore(fileURL: url).project(id: a.id))
        #expect(reloaded.isShared)
        #expect(reloaded.modifiedAt == Date(timeIntervalSince1970: 1_800_000_000.5))
        #expect(reloaded.approvedCommandsHash == "approved-Alpha")
        #expect(reloaded.lastOpenedAt == a.lastOpenedAt)
    }

    @Test func setSharedForAnUnknownIdThrowsAndChangesNothing() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = store(url, clock)
        try store.upsert(project("Alpha"))
        let before = try Data(contentsOf: url)
        let missing = UUID()

        #expect(throws: ProjectStoreError.unknownProject(missing)) { try store.setShared(id: missing, true) }

        #expect(try Data(contentsOf: url) == before)
    }

    @Test func recordOpenLeavesModifiedAtAlone() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = store(url, clock)
        let a = project("Alpha", shared: true)
        try store.upsert(a)
        clock.now = Date(timeIntervalSince1970: 1_900_000_000)

        try store.recordOpen(id: a.id, at: clock.now)

        let stored = try #require(store.project(id: a.id))
        #expect(stored.lastOpenedAt == clock.now)
        #expect(stored.modifiedAt == Date(timeIntervalSince1970: 1_700_000_000), "opening is device state, not a definition write")
    }

    @Test func upsertStampsModifiedAtOnEveryCall() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = store(url, clock)
        var a = project("Alpha", modified: Date(timeIntervalSince1970: 1_000))
        try store.upsert(a)
        #expect(store.project(id: a.id)?.modifiedAt == Date(timeIntervalSince1970: 1_700_000_000))
        clock.now = Date(timeIntervalSince1970: 1_750_000_000)
        a.color = .red
        try store.upsert(a)
        #expect(store.project(id: a.id)?.modifiedAt == Date(timeIntervalSince1970: 1_750_000_000))
    }

    @Test(arguments: [
        #"{"version":99,"projects":[{"id":"11111111-1111-1111-1111-111111111111","name":"Keep","rootPath":"/tmp/a",\#(layoutJSON)}]}"#,
        #"{"version":1,"projects":[{"id":"11111111-1111-1111-1111-111111111111","name":"Keep","rootPath":"/tmp/a",\#(layoutJSON)},{"id":"22222222-2222-2222-2222-222222222222","name":"Dropped","rootPath":"relative",\#(layoutJSON)}]}"#,
    ])
    func setSharedOnAFileNotFullyLoadedUpdatesMemoryOnly(json: String) throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(json.utf8)
        try original.write(to: url)
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = store(url, clock)
        let keep = try #require(store.projects.first)

        try store.setShared(id: keep.id, true)

        #expect(store.project(id: keep.id)?.isShared == true)
        #expect(try Data(contentsOf: url) == original, "the file is byte-for-byte untouched")
    }

    @Test func aSharedProjectReachesTheBackendAndALocalOneNeverDoes() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let backend = LocalOnlyProjectSyncBackend()
        let store = store(url, clock, backend: backend)
        let shared = project("Shared", shared: true)
        let local = project("Local")

        try store.upsert(local)
        try store.setShared(id: local.id, false)
        try store.delete(id: local.id)
        #expect(backend.calls.isEmpty, "upsert, an unshare of a local Project, and delete of a local Project are all silent")

        try store.upsert(shared)
        let record = try #require(store.project(id: shared.id)).syncRecord(home: home)
        #expect(backend.calls.last == .publish(record))
        #expect(record.rootPath == "~/Developer/Shared")
        let afterPublish = backend.calls.count

        try store.setShared(id: shared.id, false)
        #expect(backend.calls.count == afterPublish + 1)
        #expect(backend.calls.last == .withdraw(shared.id))

        try store.setShared(id: shared.id, true)
        #expect(backend.calls.last == .publish(try #require(store.project(id: shared.id)).syncRecord(home: home)))

        clock.now = Date(timeIntervalSince1970: 1_900_000_000)
        try store.delete(id: shared.id)
        #expect(backend.calls.last == .tombstone(shared.id, clock.now))
    }

    @Test func editingASharedProjectIntoALocalOneWithdrawsIt() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let backend = LocalOnlyProjectSyncBackend()
        let store = store(url, Clock(Date(timeIntervalSince1970: 1_700_000_000)), backend: backend)
        var p = project("Edited", shared: true)
        try store.upsert(p)
        p.isShared = false
        try store.upsert(p)
        #expect(backend.calls.last == .withdraw(p.id))
    }

    @Test func aRefusedShareLeavesTheFlagAndTheFileUntouchedAndSetsSyncError() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let backend = SwitchableProjectSyncBackend()
        let store = store(url, Clock(Date(timeIntervalSince1970: 1_700_000_000)), backend: backend)
        let local = project("Local")
        try store.upsert(local)
        let before = try Data(contentsOf: url)
        backend.refusal = .quotaExceeded(reason: .totalTooLarge)

        #expect(throws: ProjectSyncError.quotaExceeded(reason: .totalTooLarge)) { try store.setShared(id: local.id, true) }

        #expect(store.project(id: local.id)?.isShared == false)
        #expect(try Data(contentsOf: url) == before, "projects.json is byte-identical")
        #expect(store.syncError == ProjectSyncError.quotaExceeded(reason: .totalTooLarge).localizedDescription)
        #expect(backend.published.isEmpty)
    }

    @Test func aRefusedUpsertOfASharedProjectAddsNothing() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let backend = SwitchableProjectSyncBackend()
        backend.refusal = .quotaExceeded(reason: .recordTooLarge)
        let store = store(url, Clock(Date(timeIntervalSince1970: 1_700_000_000)), backend: backend)

        #expect(throws: ProjectSyncError.quotaExceeded(reason: .recordTooLarge)) { try store.upsert(project("Big", shared: true)) }

        #expect(store.projects.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.syncError != nil)
    }

    @Test func anAcceptedShareCommitsTheFlagAndClearsSyncError() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let backend = SwitchableProjectSyncBackend()
        let store = store(url, Clock(Date(timeIntervalSince1970: 1_700_000_000)), backend: backend)
        let local = project("Local")
        try store.upsert(local)
        backend.refusal = .quotaExceeded(reason: .tooManyKeys)
        #expect(throws: ProjectSyncError.self) { try store.setShared(id: local.id, true) }
        #expect(store.syncError != nil)
        backend.refusal = nil

        try store.setShared(id: local.id, true)

        #expect(store.project(id: local.id)?.isShared == true)
        #expect(ProjectStore(fileURL: url).project(id: local.id)?.isShared == true)
        #expect(store.syncError == nil)
        #expect(backend.published.map(\.id) == [local.id])
    }

    @Test func aBackendReportedErrorSurfacesAsSyncError() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let backend = LocalOnlyProjectSyncBackend()
        let store = store(url, Clock(Date(timeIntervalSince1970: 1_700_000_000)), backend: backend)
        #expect(store.syncError == nil)

        backend.onSyncError?(.quotaExceeded(reason: .totalTooLarge))

        #expect(store.syncError == ProjectSyncError.quotaExceeded(reason: .totalTooLarge).localizedDescription)
    }

    @Test func theLocalOnlyBackendNeverRefuses() throws {
        let backend = LocalOnlyProjectSyncBackend()
        let huge = ProjectSyncRecord(
            id: UUID(), name: String(repeating: "n", count: 2_000_000), rootPath: "~/x", color: .teal, symbol: .chip,
            layout: .preset(.singlePane), runStartupCommandsOnOpen: true, modifiedAt: nil)
        try backend.publish(huge)
        #expect(backend.calls == [.publish(huge)])
    }

    @Test func aNonAuthoritativeBackendNeverWithdrawsASharedProjectButStillAppliesRecords() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        backend.snapshotIsAuthoritative = false
        let store = store(url, Clock(Date(timeIntervalSince1970: 1_700_000_000)), backend: backend)
        let mine = project("Mine", shared: true, modified: Date(timeIntervalSince1970: 1_000))
        try store.upsert(mine)
        let fresh = UUID()
        backend.receive([fresh: .record(ProjectSyncRecord(
            id: fresh, name: "Arrived", rootPath: "~/Arrived", color: .violet, symbol: .chip,
            layout: .preset(.singlePane), runStartupCommandsOnOpen: false,
            modifiedAt: Date(timeIntervalSince1970: 1_600_000_000)))])
        backend.finishChanges()
        await store.syncTask?.value

        #expect(store.project(id: mine.id)?.isShared == true, "an empty-for-this-id snapshot before the first server change must not unshare")
        #expect(store.project(id: fresh)?.name == "Arrived")
    }

    @Test func anAuthoritativeBackendWithdrawsASharedProjectAbsentFromTheSnapshot() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = store(url, Clock(Date(timeIntervalSince1970: 1_700_000_000)), backend: backend)
        let mine = project("Mine", shared: true, modified: Date(timeIntervalSince1970: 1_000))
        try store.upsert(mine)
        backend.receive([:])
        backend.finishChanges()
        await store.syncTask?.value
        #expect(store.project(id: mine.id)?.isShared == false)
    }

    @Test func aStoreWithNoBackendHasNoSyncState() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = store(url, Clock(Date(timeIntervalSince1970: 1_700_000_000)))
        try store.upsert(project("Shared", shared: true))
        #expect(store.syncTask == nil)
    }

    @Test func aBackendChangeMergesIntoTheListAndPersists() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = store(url, Clock(Date(timeIntervalSince1970: 1_700_000_000)), backend: backend)
        let mine = project("Mine", shared: true, modified: Date(timeIntervalSince1970: 1_000))
        try store.upsert(mine)
        let fresh = UUID()
        backend.receive([
            fresh: .record(ProjectSyncRecord(
                id: fresh, name: "Remote", rootPath: "~/Remote", color: .violet, symbol: .chip,
                layout: .preset(.singlePane), runStartupCommandsOnOpen: false,
                modifiedAt: Date(timeIntervalSince1970: 1_600_000_000))),
            mine.id: .tombstone(deletedAt: Date(timeIntervalSince1970: 1_600_000_000)),
        ])
        backend.finishChanges()

        await store.syncTask?.value

        #expect(store.projects.map(\.name) == ["Remote"])
        let persisted = ProjectStore(fileURL: url).projects
        #expect(persisted.map(\.name) == ["Remote"])
        #expect(persisted.first?.rootPath == "/Users/test/Remote")
        #expect(persisted.first?.isShared == true)
    }

    @Test func anUnavailableBackendChangeIsIgnored() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let backend = LocalOnlyProjectSyncBackend()
        let store = store(url, Clock(Date(timeIntervalSince1970: 1_700_000_000)), backend: backend)
        try store.upsert(project("Mine", shared: true))
        backend.receive([:])
        backend.finishChanges()

        await store.syncTask?.value

        #expect(store.projects.map(\.isShared) == [true], "an empty snapshot from an unavailable backend must not unshare anything")
    }

    @Test func recordingAnApprovalIsDeviceStateOnly() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let backend = LocalOnlyProjectSyncBackend()
        let store = store(url, clock, backend: backend)
        let a = project("Alpha", shared: true)
        try store.upsert(a)
        let stamped = try #require(store.project(id: a.id)?.modifiedAt)
        let callsBefore = backend.calls.count
        clock.now = Date(timeIntervalSince1970: 1_900_000_000)

        try store.recordApproval(id: a.id, hash: "new-hash")

        let after = try #require(ProjectStore(fileURL: url).project(id: a.id))
        #expect(after.approvedCommandsHash == "new-hash")
        #expect(after.modifiedAt == stamped)
        #expect(backend.calls.count == callsBefore, "an approval never reaches the backend")
        let missing = UUID()
        #expect(throws: ProjectStoreError.unknownProject(missing)) { try store.recordApproval(id: missing, hash: "x") }
    }

    @Test func recordingAnApprovalOnAFileNotFullyLoadedUpdatesMemoryOnly() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version":99,"projects":[{"id":"11111111-1111-1111-1111-111111111111","name":"Keep","rootPath":"/tmp/a",\#(layoutJSON)}]}"#.utf8)
        try original.write(to: url)
        let store = store(url, Clock(Date(timeIntervalSince1970: 1_700_000_000)))
        let keep = try #require(store.projects.first)

        try store.recordApproval(id: keep.id, hash: "h")

        #expect(store.project(id: keep.id)?.approvedCommandsHash == "h")
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func aPreSharingFileSavesBackByteIdentical() throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let projects = [project("Alpha"), project("Beta")].map { p -> Project in
            var p = p
            p.modifiedAt = nil
            return p
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProjectsFile.encoder.encode(ProjectsFile(projects: projects)).write(to: url)
        let original = try Data(contentsOf: url)
        let object = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        let entries = try #require(object["projects"] as? [[String: Any]])
        #expect(entries.allSatisfy { $0["isShared"] == nil && $0["modifiedAt"] == nil }, "the fixture is a pre-sharing file")

        let reloaded = ProjectStore(fileURL: url)
        try reloaded.save()

        #expect(try Data(contentsOf: url) == original)
    }

    @Test func aBackendChangeIsSkippedWhileTheFileIsNotFullyLoaded() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version":99,"projects":[{"id":"11111111-1111-1111-1111-111111111111","name":"Keep","rootPath":"/tmp/a",\#(layoutJSON)}]}"#.utf8)
        try original.write(to: url)
        let backend = LocalOnlyProjectSyncBackend(isAvailable: true)
        let store = store(url, Clock(Date(timeIntervalSince1970: 1_700_000_000)), backend: backend)
        let id = UUID()
        backend.receive([id: .record(ProjectSyncRecord(
            id: id, name: "Incoming", rootPath: "~/x", color: .blue, symbol: .folder,
            layout: .preset(.singlePane), runStartupCommandsOnOpen: false, modifiedAt: Date(timeIntervalSince1970: 1)))])
        backend.finishChanges()

        await store.syncTask?.value

        #expect(store.projects.map(\.name) == ["Keep"])
        #expect(try Data(contentsOf: url) == original)
    }
}

@MainActor
struct ProjectSharingPickerTests {
    private let home = "/Users/test"

    private func project(_ name: String, root: String = "/Users/test/Developer/work", shared: Bool = false, opened: TimeInterval? = nil) -> Project {
        Project(name: name, rootPath: root, lastOpenedAt: opened.map(Date.init(timeIntervalSince1970:)), isShared: shared)
    }

    @Test func cardsCarryTheSharedFlagAndTheMissingRootFromTheInjectedCheck() {
        let shared = project("Alpha", shared: true)
        let missing = project("Beta", root: "/Users/test/Gone")
        let m = ProjectPickerModel(projects: [shared, missing], openProjectIDs: [], homeDirectory: home, rootExists: { $0 != "/Users/test/Gone" })
        let alpha = m.cards.first { $0.name == "Alpha" }
        let beta = m.cards.first { $0.name == "Beta" }
        #expect(alpha?.isShared == true && alpha?.rootIsMissing == false)
        #expect(beta?.isShared == false && beta?.rootIsMissing == true)
    }

    @Test func refreshingNeverRechecksARootItHasAlreadySeen() {
        var checked: [String] = []
        let a = project("Alpha", root: "/a"), b = project("Beta", root: "/b")
        let base = ProjectPickerModel(projects: [a], openProjectIDs: [], homeDirectory: home, rootExists: { checked.append($0); return true })
        #expect(checked.isEmpty, "building the model checks nothing")
        // The view keeps `base` in @State and renders `base.refreshed(...)`, which is a copy.
        _ = base.refreshed(projects: [a], openProjectIDs: []).cards
        _ = base.refreshed(projects: [a], openProjectIDs: []).cards
        _ = base.refreshed(projects: [a], openProjectIDs: []).tiers
        #expect(checked == ["/a"], "later renders read the shared cache and never reach the filesystem")
        _ = base.refreshed(projects: [a, b], openProjectIDs: []).cards
        #expect(checked == ["/a", "/b"], "a Project that appears while the sheet is up is checked once")
        _ = base.refreshed(projects: [a, b], openProjectIDs: []).cards
        #expect(checked == ["/a", "/b"])
    }

    @Test func flippingTheSharedFlagOfTheSelectedCardKeepsSelectionAndPosition() throws {
        let a = project("Alpha", opened: 3000)
        let b = project("Beta", shared: true, opened: 2000)
        let c = project("Gamma", opened: 1000)
        var m = ProjectPickerModel(projects: [a, b, c], openProjectIDs: [], homeDirectory: home, rootExists: { _ in true })
        m.select(b.id)
        let position = try #require(m.selectedPosition)
        let hint = m.hint
        var unshared = b
        unshared.isShared = false

        let after = m.refreshed(projects: [a, unshared, c], openProjectIDs: [])

        #expect(after.cards.first { $0.id == b.id }?.isShared == false)
        #expect(after.selectedID == b.id)
        #expect(after.selectedPosition == position)
        #expect(after.hint == hint)
        #expect(after.tiers.featured.map(\.id) == m.tiers.featured.map(\.id))
    }

    @Test func theSheetLaysOutWithASharedCardAndAMissingRootCard() {
        let projects = [
            project("Alpha", shared: true, opened: 5), project("Beta", root: "/Users/test/Gone", opened: 4),
            project("Gamma", opened: 3), project("Delta", root: "/Users/test/Gone", shared: true, opened: 2),
            project("Eps", opened: 1),
        ]
        let open: Set<UUID> = [projects[0].id]
        let view = ProjectPickerView(
            projects: { projects }, openProjectIDs: { open }, homeDirectory: home,
            rootExists: { $0 != "/Users/test/Gone" }, onAction: { _ in }, onSetShared: { _, _ in }, onCancel: {})
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 860, height: 600)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }

    @Test func theModelCarriesTheSyncErrorOnlyForTheRefreshThatPassesItAndClearsOnTheNext() {
        let projects = [project("Alpha"), project("Beta", shared: true)]
        let model = ProjectPickerModel(projects: projects, openProjectIDs: [], homeDirectory: home, rootExists: { _ in true })
        #expect(model.syncError == nil)

        let failed = model.refreshed(projects: projects, openProjectIDs: [], syncError: "Too big")
        #expect(failed.syncError == "Too big")
        #expect(failed.refreshed(projects: projects, openProjectIDs: []).syncError == nil, "a successful publish clears it")
    }

    @Test func aSharedChipFitsAsNarrowlyAsAnUnsharedOne() {
        let chipWidth: CGFloat = (860 - 32 - 30) / 4
        func fixedWidth(shared: Bool) -> CGFloat {
            let p = project("", shared: shared)
            let card = ProjectPickerModel(projects: [p], openProjectIDs: [], homeDirectory: home, rootExists: { _ in true }).cards[0]
            return NSHostingView(rootView: ProjectPickerOpenChipView(
                card: card, isSelected: false, onSelect: {}, onSwitch: {}, onAnother: {}, onSetShared: { _ in })).fittingSize.width
        }
        let name = NSHostingView(rootView: Text("Charlie Wood").fontWeight(.semibold).lineLimit(1).fixedSize()).fittingSize.width
        #expect(fixedWidth(shared: true) + name + 8 <= chipWidth)
        #expect(fixedWidth(shared: false) + name + 8 <= chipWidth)
    }
}
