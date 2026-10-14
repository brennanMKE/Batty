// ProjectSyncMergeTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

struct ProjectSyncMergeTests {
    private let home = "/Users/test"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let opened = Date(timeIntervalSince1970: 1_650_000_000)

    /// Device state is set on every local Project, so "kept" is never vacuous.
    private func local(
        _ name: String, id: UUID = UUID(), shared: Bool = true, modified: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Project {
        Project(
            id: id, name: name, rootPath: "/Users/test/Developer/\(name)", color: .teal, symbol: .hammer,
            layout: .preset(.twoByTwoGrid), runStartupCommandsOnOpen: true,
            approvedCommandsHash: "approved-\(name)", lastOpenedAt: Date(timeIntervalSince1970: 1_650_000_000),
            isShared: shared, modifiedAt: modified)
    }

    private func record(_ name: String, id: UUID, modified: Date?) -> ProjectSyncRecord {
        ProjectSyncRecord(
            id: id, name: name, rootPath: "~/Remote/\(name)", color: .violet, symbol: .chip,
            layout: .preset(.mainLeftTwoRight), runStartupCommandsOnOpen: false, modifiedAt: modified)
    }

    private func merge(_ remote: [UUID: ProjectSyncEntry], _ projects: [Project]) -> [Project] {
        ProjectSyncMerge.apply(remote: remote, to: projects, home: home, now: now)
    }

    @Test func anUnknownRecordIsInsertedAsASharedProjectWithNoDeviceState() {
        let existing = local("Keep")
        let id = UUID()
        let result = merge([id: .record(record("Fresh", id: id, modified: base))], [existing])
        let inserted = result.first { $0.id == id }
        #expect(result.count == 2)
        #expect(inserted?.isShared == true)
        #expect(inserted?.lastOpenedAt == nil)
        #expect(inserted?.approvedCommandsHash == nil)
        #expect(inserted?.rootPath == "/Users/test/Remote/Fresh", "the portable root is decoded against this Mac's home")
        #expect(inserted?.color == .violet)
        #expect(inserted?.modifiedAt == base)
    }

    @Test func aNewerRemoteReplacesTheDefinitionAndKeepsDeviceState() throws {
        let mine = local("Site", shared: true)
        let remote = record("Site Renamed", id: mine.id, modified: base.addingTimeInterval(10))
        let result = try #require(merge([mine.id: .record(remote)], [mine]).first)
        #expect(result.name == "Site Renamed")
        #expect(result.color == .violet)
        #expect(result.symbol == .chip)
        #expect(result.layout == .preset(.mainLeftTwoRight))
        #expect(result.rootPath == "/Users/test/Remote/Site Renamed")
        #expect(!result.runStartupCommandsOnOpen)
        #expect(result.modifiedAt == base.addingTimeInterval(10))
        #expect(result.approvedCommandsHash == "approved-Site", "the trust approval is never replaced or copied")
        #expect(result.lastOpenedAt == opened)
        #expect(result.isShared)
    }

    @Test(arguments: [0.0, -10.0])
    func anEqualOrOlderRemoteIsIgnored(offset: Double) throws {
        let mine = local("Site")
        let remote = record("Other", id: mine.id, modified: base.addingTimeInterval(offset))
        #expect(merge([mine.id: .record(remote)], [mine]) == [mine])
    }

    @Test func anOlderRecordDoesNotReshareAProjectTheUserMadeLocal() {
        let mine = local("Site", shared: false, modified: base.addingTimeInterval(100))
        let remote = record("Site", id: mine.id, modified: base)
        let result = merge([mine.id: .record(remote)], [mine])
        #expect(result == [mine])
        #expect(result[0].isShared == false)
    }

    @Test func aRecordAsNewAsTheLocalOneReSharesIt() {
        let mine = local("Site", shared: false, modified: base)
        let remote = record("Site", id: mine.id, modified: base)
        #expect(merge([mine.id: .record(remote)], [mine]).first?.isShared == true)
    }

    @Test func aLocalProjectWithNoModifiedDateLosesToAnyRemoteDate() throws {
        let mine = local("Site", shared: false, modified: nil)
        let remote = record("Remote Site", id: mine.id, modified: Date(timeIntervalSince1970: 1))
        let result = try #require(merge([mine.id: .record(remote)], [mine]).first)
        #expect(result.name == "Remote Site")
        #expect(result.isShared, "a record for a known id makes it shared")
        #expect(result.approvedCommandsHash == "approved-Site")
        #expect(result.lastOpenedAt == opened)
    }

    @Test func aRemoteWithNoDateDoesNotReplaceALocalWithNoDate() {
        let mine = local("Site", shared: true, modified: nil)
        let remote = record("Other", id: mine.id, modified: nil)
        #expect(merge([mine.id: .record(remote)], [mine]) == [mine])
    }

    @Test func aTombstoneDeletesASharedLocalAndKeepsOneTheUserMadeLocal() {
        let shared = local("Shared", shared: true)
        let madeLocal = local("Madeloc", shared: false)
        let remote: [UUID: ProjectSyncEntry] = [
            shared.id: .tombstone(deletedAt: base),
            madeLocal.id: .tombstone(deletedAt: base),
            UUID(): .tombstone(deletedAt: base),
        ]
        #expect(merge(remote, [shared, madeLocal]) == [madeLocal])
    }

    @Test func absenceMakesASharedProjectLocalAndNeverDeletesIt() {
        let withdrawn = local("Withdrawn", shared: true)
        let alwaysLocal = local("Always", shared: false)
        let result = merge([:], [withdrawn, alwaysLocal])
        var expected = withdrawn
        expected.isShared = false
        #expect(result == [expected, alwaysLocal])
        #expect(result[0].approvedCommandsHash == "approved-Withdrawn")
        #expect(result[0].lastOpenedAt == opened)
    }

    @Test func anIncomingNameThatCollidesGetsANumericSuffixOnThisMac() {
        let mine = local("Alpha", shared: false)
        let taken = local("alpha 2", shared: false)
        let id = UUID()
        let result = merge([id: .record(record("ALPHA", id: id, modified: base))], [mine, taken])
        #expect(result.first { $0.id == id }?.name == "ALPHA 3")
        #expect(result.filter { $0.id != id } == [mine, taken])
    }

    @Test func aNewerRecordWhoseNameNowCollidesWithAnotherProjectIsSuffixed() throws {
        let mine = local("Site", shared: true)
        let other = local("Docs", shared: false)
        let remote = record("docs", id: mine.id, modified: base.addingTimeInterval(5))
        let result = merge([mine.id: .record(remote)], [mine, other])
        #expect(result.first { $0.id == mine.id }?.name == "docs 2")
        #expect(result.first { $0.id == other.id } == other)
    }

    @Test func applyingTheSameRemoteSetTwiceEqualsApplyingItOnce() {
        let updated = local("Updated", shared: true)
        let gone = local("Gone", shared: true)
        let withdrawn = local("Withdrawn", shared: true)
        let kept = local("Kept", shared: false)
        let freshID = UUID()
        let remote: [UUID: ProjectSyncEntry] = [
            updated.id: .record(record("Updated 2", id: updated.id, modified: base.addingTimeInterval(1))),
            gone.id: .tombstone(deletedAt: base),
            freshID: .record(record("Updated 2", id: freshID, modified: base)),
        ]
        let once = merge(remote, [updated, gone, withdrawn, kept])
        let twice = merge(remote, once)
        #expect(once == twice)
        #expect(once.map(\.name).contains("Updated 2 2"), "the collision suffix is applied once and then stable")
    }
}
