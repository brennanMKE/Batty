// SharedImageSweepTests.swift

import Foundation
import Testing
@testable import BattyKit

struct SharedImageSweepDecisionTests {
    private let digest = String(repeating: "d", count: 64)
    private let other = String(repeating: "e", count: 64)
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let thirtyDays: TimeInterval = 30 * 24 * 60 * 60

    @Test func aNamedDigestIsKept() {
        let result = SharedImageSweep.decide(listed: [digest], named: [digest], ledger: [digest: now.addingTimeInterval(-2 * thirtyDays)], now: now)
        #expect(result.delete.isEmpty)
        #expect(result.ledger.isEmpty)
    }

    @Test func anUnnamedDigestIsNotDeletedBeforeThirtyDays() {
        let first = SharedImageSweep.decide(listed: [digest], named: [], ledger: [:], now: now)
        #expect(first.delete.isEmpty)
        #expect(first.ledger == [digest: now])
        let later = SharedImageSweep.decide(listed: [digest], named: [], ledger: first.ledger, now: now.addingTimeInterval(thirtyDays - 1))
        #expect(later.delete.isEmpty)
        #expect(later.ledger == [digest: now])
    }

    @Test func anUnnamedDigestGoesAfterThirtyDays() {
        let result = SharedImageSweep.decide(listed: [digest, other], named: [other], ledger: [digest: now], now: now.addingTimeInterval(thirtyDays))
        #expect(result.delete == [digest])
        #expect(result.ledger.isEmpty)
    }

    @Test func beingNamedAgainResetsTheLedger() {
        let old = now.addingTimeInterval(-2 * thirtyDays)
        let named = SharedImageSweep.decide(listed: [digest], named: [digest], ledger: [digest: old], now: now)
        let unnamed = SharedImageSweep.decide(listed: [digest], named: [], ledger: named.ledger, now: now)
        #expect(unnamed.delete.isEmpty)
        #expect(unnamed.ledger == [digest: now])
    }

    @Test func otherNamesAreNeverTouched() {
        let result = SharedImageSweep.decide(listed: ["notes", "../x", String(repeating: "D", count: 64)], named: [], ledger: ["notes": now.addingTimeInterval(-2 * thirtyDays)], now: now)
        #expect(result.delete.isEmpty)
        #expect(result.ledger.isEmpty)
    }
}

/// Every case starts from a shared-folder file that would be deleted if the
/// sweep ran with an aged ledger, so "nothing deleted" can't pass by accident.
@MainActor
struct SharedImageSweepTests {
    private let w: SharedImageWorld
    private let orphan = String(repeating: "f", count: 64)

    init() throws {
        w = try SharedImageWorld()
        w.fake.put(Data("orphan".utf8), digest: orphan)
        SharedImageSweep.writeLedger([orphan: Date(timeIntervalSince1970: 1_000_000_000)], to: ledger)
        w.fixture.testDefaults.defaults.set(true, forKey: SharedProjectImages.folderWasReachedKey)
    }

    private var ledger: URL { w.fixture.base.appendingPathComponent(SharedImageSweep.ledgerFileName) }

    private func sweep() async {
        try? w.fixture.saveProjectsFile()
        await w.images.sweepIfAllowed()?.value
    }

    @Test func anAgedOrphanIsDeleted() async {
        await sweep()
        #expect(w.fake.deletes == [.delete(orphan)])
        #expect(SharedImageSweep.readLedger(at: ledger).isEmpty)
    }

    @Test func itRunsOncePerLaunch() async {
        await sweep()
        #expect(w.images.sweepIfAllowed() == nil)
    }

    /// The three keep-set tests below reach `sweepIfAllowed` with no suspension
    /// after `backend.receive`, which queues a merge that would copy a record
    /// into the list and the file. So each names the digest in one place only.
    private func expectSweepRanAndKeptTheOrphan() {
        #expect(w.fake.count(.list) == 1)
        #expect(w.fake.deletes.isEmpty)
        #expect(w.fake.hasFile(digest: orphan))
    }

    @Test func aDigestNamedOnlyByTheListIsKept() async throws {
        let images = w.images
        try w.store.upsert(w.project(path: nil, sharedImage: .named(digest: orphan, name: "Pending")))
        w.backend.receive([:])
        try FileManager.default.removeItem(at: w.fixture.projectsFile)
        try w.fixture.saveProjectsFile()
        #expect(w.store.projects.contains { $0.sharedImage?.digest == orphan })
        #expect(w.store.sharedImageDigestsInFile() == [])
        await images.sweepIfAllowed()?.value
        expectSweepRanAndKeptTheOrphan()
    }

    @Test func aDigestNamedOnlyByTheFileIsKept() async throws {
        let images = w.images
        var project = w.project(path: nil, sharedImage: .named(digest: orphan, name: "Pending"))
        project.name = "Saved By Another Copy"
        try ProjectStore(fileURL: w.fixture.projectsFile, sharedImagesEnabled: true).upsert(project)
        #expect(!w.store.projects.contains { $0.sharedImage != nil })
        #expect(w.store.sharedImageDigestsInFile() == [orphan])
        await images.sweepIfAllowed()?.value
        expectSweepRanAndKeptTheOrphan()
    }

    @Test func aDigestNamedByARecordOnlyIsKept() async throws {
        let images = w.images
        var record = Project(name: "Elsewhere", rootPath: "/tmp/elsewhere", isShared: true).syncRecord(home: "/Users/test")
        record.modifiedAt = .distantPast
        record.background = ProjectSyncBackground(projectBackgroundValue(path: nil), image: .named(digest: orphan, name: "N"))
        w.backend.receive([record.id: .record(record)])
        try w.fixture.saveProjectsFile()
        #expect(!w.store.projects.contains { $0.sharedImage != nil })
        #expect(w.store.sharedImageDigestsInFile() == [])
        await images.sweepIfAllowed()?.value
        expectSweepRanAndKeptTheOrphan()
    }

    @Test func noSweepWithoutAnAuthoritativeSnapshot() async {
        w.backend.snapshotIsAuthoritative = false
        await sweep()
        #expect(w.fake.calls.isEmpty)
    }

    @Test func noSweepWithASkippedEntry() async {
        w.backend.snapshotSkippedEntries = true
        await sweep()
        #expect(w.fake.calls.isEmpty)
    }

    @Test func noSweepWhileProjectsAreUntrusted() async throws {
        try Data("not json".utf8).write(to: w.fixture.projectsFile)
        await w.images.sweepIfAllowed()?.value
        #expect(w.fake.calls.isEmpty)
    }

    @Test func noSweepWhileTheFolderIsOff() async {
        w.fake.setAvailability(.off)
        await sweep()
        #expect(w.fake.deletes.isEmpty)
    }

    @Test func noSweepBeforeTheFolderWasReached() async {
        w.fixture.testDefaults.defaults.set(false, forKey: SharedProjectImages.folderWasReachedKey)
        await sweep()
        #expect(w.fake.calls.isEmpty)
    }

    @Test func unshareDeletesNoSharedCopy() async throws {
        let path = try await w.fixture.copy()
        let project = w.project(path: path)
        try w.store.upsert(project)
        await w.pass()
        try w.store.setShared(id: project.id, false)
        await w.pass()
        #expect(w.fake.deletes.isEmpty)
        #expect(w.fake.hasFile(digest: try #require(TerminalBackgroundImageImporter.digest(ofPath: path))))
    }

    @Test func deletingAProjectDeletesNoSharedCopy() async throws {
        let path = try await w.fixture.copy()
        let project = w.project(path: path)
        try w.store.upsert(project)
        await w.pass()
        try w.store.delete(id: project.id)
        await w.pass()
        #expect(w.fake.deletes.isEmpty)
        #expect(w.fake.hasFile(digest: try #require(TerminalBackgroundImageImporter.digest(ofPath: path))))
    }

    @Test func changingTheImageDeletesNoSharedCopy() async throws {
        let first = try await w.fixture.copy()
        let second = try await w.fixture.copy(width: 72)
        let project = w.project(path: first)
        try w.store.upsert(project)
        await w.pass()
        var changed = try #require(w.store.project(id: project.id))
        changed.background = projectBackgroundValue(path: second)
        try w.store.upsert(changed)
        await w.pass()
        #expect(w.fake.deletes.isEmpty)
        #expect(w.fake.hasFile(digest: try #require(TerminalBackgroundImageImporter.digest(ofPath: first))))
        #expect(w.fake.hasFile(digest: try #require(TerminalBackgroundImageImporter.digest(ofPath: second))))
    }
}
