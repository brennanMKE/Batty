// ICloudKeyValueProjectSyncBackendTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
final class FakeKeyValueStore: KeyValueStoring {
    private(set) var values: [String: Data] = [:]
    private(set) var synchronizeCount = 0
    private(set) var writes: [String] = []

    var dictionaryRepresentation: [String: Any] { values }
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data, forKey key: String) {
        values[key] = data
        writes.append(key)
    }
    func removeObject(forKey key: String) { values[key] = nil }
    func synchronize() -> Bool {
        synchronizeCount += 1
        return true
    }
    func seed(_ data: Data, forKey key: String) { values[key] = data }
}

@MainActor
struct ICloudKeyValueProjectSyncBackendTests {
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private struct Fixture {
        let store = FakeKeyValueStore()
        let center = NotificationCenter()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let backend: ICloudKeyValueProjectSyncBackend

        init(entitlement: Bool = true, account: Bool = true) {
            let store = store, center = center, clock = clock
            backend = ICloudKeyValueProjectSyncBackend(
                store: store, notificationCenter: center, clock: { clock.now },
                hasEntitlement: { entitlement }, hasAccount: { account })
        }

        func post(reason: Int?, keys: [String]?) {
            var info: [AnyHashable: Any] = [:]
            if let reason { info[NSUbiquitousKeyValueStoreChangeReasonKey] = NSNumber(value: reason) }
            if let keys { info[NSUbiquitousKeyValueStoreChangedKeysKey] = keys }
            center.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, userInfo: info)
        }

        /// Yields caused by notifications: the one the backend emits at
        /// construction, to merge what the store already holds, is not counted.
        func yieldCount() async -> Int {
            backend.finishChanges()
            var count = 0
            for await _ in backend.changes { count += 1 }
            return count - 1
        }

        func launchYields() async -> Int {
            backend.finishChanges()
            var count = 0
            for await _ in backend.changes { count += 1 }
            return count
        }
    }

    private func record(_ name: String = "Site", id: UUID = UUID(), modified: Date? = Date(timeIntervalSince1970: 1_700_000_000.25)) -> ProjectSyncRecord {
        ProjectSyncRecord(
            id: id, name: name, rootPath: "~/Developer/\(name)", color: .violet, symbol: .chip,
            layout: .preset(.twoByTwoGrid), runStartupCommandsOnOpen: true, modifiedAt: modified)
    }

    private let projectKey = ICloudKeyValueProjectSyncBackend.key(for:)

    // MARK: - Keys and values

    @Test func publishWritesOneCompactJSONValueUnderProjectDotUUID() throws {
        let f = Fixture()
        let r = record()
        try f.backend.publish(r)

        let data = try #require(f.store.data(forKey: "project.\(r.id.uuidString)"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\n") && !text.contains("  ") && !text.contains("\": "))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = ProjectsFile.encoder.dateEncodingStrategy
        #expect(data == (try encoder.encode(r)))
        #expect(text.contains("2023-11-14T22:13:20.250Z"))
        #expect(try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: data) == r)
        #expect(f.store.writes == ["project.\(r.id.uuidString)"])
    }

    @Test func withdrawRemovesTheKey() throws {
        let f = Fixture()
        let r = record()
        try f.backend.publish(r)
        let other = record("Other")
        try f.backend.publish(other)

        f.backend.withdraw(id: r.id)

        #expect(f.store.data(forKey: projectKey(r.id)) == nil)
        #expect(f.store.data(forKey: projectKey(other.id)) != nil)
    }

    @Test func tombstoneWritesOnlyDeletedAt() throws {
        let f = Fixture()
        let id = UUID()
        let at = Date(timeIntervalSince1970: 1_799_000_000.5)
        f.backend.tombstone(id: id, deletedAt: at)

        let data = try #require(f.store.data(forKey: projectKey(id)))
        #expect(String(decoding: data, as: UTF8.self) == #"{"deletedAt":"2027-01-03T18:13:20.500Z"}"#)
    }

    @Test func snapshotRoundTripsRecordsAndTombstonesAndSkipsWithoutDeletingWhatItCannotDecode() throws {
        let f = Fixture()
        let r = record()
        try f.backend.publish(r)
        let gone = UUID()
        let at = Date(timeIntervalSince1970: 1_799_000_000.5)
        f.backend.tombstone(id: gone, deletedAt: at)
        let garbage = UUID()
        f.store.seed(Data("not json".utf8), forKey: projectKey(garbage))
        let mismatched = UUID()
        f.store.seed(try ICloudKeyValueProjectSyncBackend.encoder.encode(r), forKey: projectKey(mismatched))
        f.store.seed(Data("{}".utf8), forKey: "unrelated")
        f.store.seed(Data("{}".utf8), forKey: "project.not-a-uuid")

        let snapshot = f.backend.snapshot()

        #expect(snapshot == [r.id: .record(r), gone: .tombstone(deletedAt: at)])
        #expect(f.store.data(forKey: projectKey(garbage)) == Data("not json".utf8))
        #expect(f.store.data(forKey: projectKey(mismatched)) != nil)
        #expect(f.store.data(forKey: "unrelated") != nil && f.store.data(forKey: "project.not-a-uuid") != nil)
    }

    // MARK: - Changes

    @Test func constructionYieldsOnceToMergeTheCurrentStoreAndIsNotAuthoritative() async {
        let f = Fixture()
        #expect(!f.backend.snapshotIsAuthoritative)
        #expect(await f.launchYields() == 1)
    }

    @Test func changesYieldNothingBeforeANotification() async {
        let f = Fixture()
        #expect(await f.yieldCount() == 0)
    }

    @Test func serverAndInitialSyncChangesMakeTheSnapshotAuthoritativeAndAnAccountChangeTakesItBack() {
        let f = Fixture()
        let key = ["project.\(UUID().uuidString)"]
        f.post(reason: NSUbiquitousKeyValueStoreAccountChange, keys: nil)
        #expect(!f.backend.snapshotIsAuthoritative, "an account change alone is not an authoritative read")
        f.post(reason: NSUbiquitousKeyValueStoreServerChange, keys: key)
        #expect(f.backend.snapshotIsAuthoritative)
        f.post(reason: NSUbiquitousKeyValueStoreAccountChange, keys: nil)
        #expect(!f.backend.snapshotIsAuthoritative, "a later account change re-arms the guard")
        f.post(reason: NSUbiquitousKeyValueStoreInitialSyncChange, keys: key)
        #expect(f.backend.snapshotIsAuthoritative)
    }

    @Test func aStoreMergingAfterAnAccountChangeKeepsSharedProjectsUntilAServerChangeFollows() async throws {
        let f = Fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("batty-icloud-\(UUID().uuidString)/projects.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ProjectStore(fileURL: url, clock: { f.clock.now }, backend: f.backend, home: "/Users/test")
        let mine = Project(name: "Mine", rootPath: "/Users/test/Mine", color: .teal, isShared: true, modifiedAt: nil)
        try store.upsert(mine)
        f.post(reason: NSUbiquitousKeyValueStoreServerChange, keys: ["project.\(mine.id.uuidString)"])
        f.store.removeObject(forKey: ICloudKeyValueProjectSyncBackend.key(for: mine.id))

        f.post(reason: NSUbiquitousKeyValueStoreAccountChange, keys: nil)
        store.mergeRemote()
        #expect(store.project(id: mine.id)?.isShared == true, "the new account's cache may simply be empty so far")

        f.post(reason: NSUbiquitousKeyValueStoreServerChange, keys: ["project.\(mine.id.uuidString)"])
        store.mergeRemote()
        #expect(store.project(id: mine.id)?.isShared == false)
    }

    @Test func serverInitialSyncAndAccountChangesEachYieldOnce() async {
        let f = Fixture()
        let key = ["project.\(UUID().uuidString)"]
        f.post(reason: NSUbiquitousKeyValueStoreServerChange, keys: key)
        f.post(reason: NSUbiquitousKeyValueStoreInitialSyncChange, keys: key)
        f.post(reason: NSUbiquitousKeyValueStoreAccountChange, keys: nil)
        #expect(await f.yieldCount() == 3)
    }

    @Test func aQuotaViolationNeverYieldsButSetsLastErrorAndReports() async {
        let f = Fixture()
        var reported: [ProjectSyncError] = []
        f.backend.onSyncError = { reported.append($0) }
        f.post(reason: NSUbiquitousKeyValueStoreQuotaViolationChange, keys: ["project.x"])

        #expect(f.backend.lastError == .quotaExceeded(reason: .totalTooLarge))
        #expect(reported == [.quotaExceeded(reason: .totalTooLarge)])
        #expect(await f.yieldCount() == 0)
    }

    @Test func aNotificationWhoseKeysAreAllOutsideTheProjectPrefixIsIgnored() async {
        let f = Fixture()
        f.post(reason: NSUbiquitousKeyValueStoreServerChange, keys: ["theme.current", "other"])
        f.post(reason: NSUbiquitousKeyValueStoreServerChange, keys: ["theme.current", "project.\(UUID().uuidString)"])
        f.post(reason: nil, keys: ["project.x"])
        #expect(await f.yieldCount() == 1)
    }

    @Test func aNotificationFromAnotherStoreIsIgnored() async {
        let f = Fixture()
        f.center.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: FakeKeyValueStore(),
            userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSNumber(value: NSUbiquitousKeyValueStoreServerChange)])
        #expect(await f.yieldCount() == 0)
    }

    @Test func initSynchronizesTheStoreAndWritesNothing() {
        let f = Fixture()
        #expect(f.store.synchronizeCount == 1)
        #expect(f.store.writes.isEmpty && f.store.values.isEmpty)
    }

    // MARK: - Limits

    @Test func aRecordOverTheValueLimitThrowsAndWritesNothing() {
        let f = Fixture()
        var huge = record()
        huge.name = String(repeating: "x", count: ICloudKeyValueProjectSyncBackend.maxValueBytes)
        #expect(throws: ProjectSyncError.quotaExceeded(reason: .recordTooLarge)) { try f.backend.publish(huge) }
        #expect(f.store.writes.isEmpty && f.store.values.isEmpty)
    }

    @Test func aRecordJustUnderTheValueLimitIsWritten() throws {
        let f = Fixture()
        var fits = record("")
        let base = try ICloudKeyValueProjectSyncBackend.encoder.encode(fits).count
        fits.name = String(repeating: "x", count: ICloudKeyValueProjectSyncBackend.maxValueBytes - base)
        try f.backend.publish(fits)
        #expect(f.store.values.count == 1)
    }

    @Test func the1025thKeyThrowsAndWritesNothingWhileThe1024thIsWritten() throws {
        let f = Fixture()
        for index in 0..<1_023 { f.store.seed(Data("x".utf8), forKey: "other.\(index)") }
        try f.backend.publish(record("Last"))
        #expect(f.store.values.count == ICloudKeyValueProjectSyncBackend.maxKeys)

        let writesBefore = f.store.writes.count
        let next = record("Overflow")
        #expect(throws: ProjectSyncError.quotaExceeded(reason: .tooManyKeys)) { try f.backend.publish(next) }
        #expect(f.store.writes.count == writesBefore)
        #expect(f.store.data(forKey: projectKey(next.id)) == nil)
    }

    @Test func republishingAnExistingKeyAtTheKeyCapIsAllowed() throws {
        let f = Fixture()
        let r = record("Existing")
        try f.backend.publish(r)
        for index in 0..<1_023 { f.store.seed(Data("x".utf8), forKey: "other.\(index)") }
        var edited = r
        edited.name = "Renamed"
        try f.backend.publish(edited)
        #expect(f.store.values.count == ICloudKeyValueProjectSyncBackend.maxKeys)
    }

    @Test func aTotalThatWouldExceedTheLimitThrowsAndWritesNothingWhileOneByteLessIsWritten() throws {
        let f = Fixture()
        let r = record()
        let size = try ICloudKeyValueProjectSyncBackend.encoder.encode(r).count
        let fillerKey = projectKey(UUID())
        let room = ICloudKeyValueProjectSyncBackend.maxTotalBytes - size
        f.store.seed(Data(repeating: 0x20, count: room + 1), forKey: fillerKey)
        #expect(throws: ProjectSyncError.quotaExceeded(reason: .totalTooLarge)) { try f.backend.publish(r) }
        #expect(f.store.writes.isEmpty)

        f.store.seed(Data(repeating: 0x20, count: room), forKey: fillerKey)
        try f.backend.publish(r)
        #expect(f.store.writes == [projectKey(r.id)])
    }

    @Test func replacingARecordDoesNotCountItsOldValueTwice() throws {
        let f = Fixture()
        let r = record()
        let size = try ICloudKeyValueProjectSyncBackend.encoder.encode(r).count
        f.store.seed(Data(repeating: 0x20, count: ICloudKeyValueProjectSyncBackend.maxTotalBytes - size), forKey: projectKey(UUID()))
        try f.backend.publish(r)
        try f.backend.publish(r)
        #expect(f.store.writes.count == 2)
    }

    // MARK: - Availability

    @Test func isAvailableDependsOnTheEntitlementAloneNotOnTheUbiquityIdentityToken() {
        #expect(Fixture(entitlement: true, account: true).backend.isAvailable)
        #expect(Fixture(entitlement: true, account: false).backend.isAvailable)
        #expect(!Fixture(entitlement: false, account: true).backend.isAvailable)
        #expect(!Fixture(entitlement: false, account: false).backend.isAvailable)
    }

    // MARK: - Pruning

    @Test func aTombstoneOlderThanThirtyDaysIsPrunedAndANewerOneKept() {
        let f = Fixture()
        let day: TimeInterval = 24 * 60 * 60
        let old = UUID(), recent = UUID()
        f.backend.tombstone(id: old, deletedAt: f.clock.now.addingTimeInterval(-31 * day))
        f.backend.tombstone(id: recent, deletedAt: f.clock.now.addingTimeInterval(-29 * day))

        let snapshot = f.backend.snapshot()

        #expect(snapshot.keys.sorted { $0.uuidString < $1.uuidString } == [recent])
        #expect(f.store.data(forKey: projectKey(old)) == nil)
        #expect(f.store.data(forKey: projectKey(recent)) != nil)
    }

    @Test func aRecordIsNeverPrunedHoweverOld() throws {
        let f = Fixture()
        let r = record(modified: Date(timeIntervalSince1970: 1))
        try f.backend.publish(r)
        #expect(f.backend.snapshot()[r.id] == .record(r))
    }
}
