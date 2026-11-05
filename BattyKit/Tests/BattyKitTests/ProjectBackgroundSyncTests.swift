// ProjectBackgroundSyncTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct ProjectBackgroundSyncTests {
    private let home = "/Users/test"
    private let path = "/Users/test/Library/ProjectBackgrounds/here.png"
    private let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_700_000_100)

    private func shared(background: TerminalBackgroundSettings?, name: String = "Shared") -> Project {
        Project(id: UUID(), name: name, rootPath: "/Users/test/a", isShared: true, modifiedAt: earlier, background: background)
    }

    private func record(of project: Project, background: TerminalBackgroundSettings?, name: String? = nil) -> ProjectSyncRecord {
        var remote = project
        remote.background = background
        remote.modifiedAt = later
        if let name { remote.name = name }
        return remote.syncRecord(home: home)
    }

    private func apply(_ record: ProjectSyncRecord, to local: [Project]) -> [Project] {
        ProjectSyncMerge.apply(remote: [record.id: .record(record)], to: local, home: home, now: later)
    }

    private func encodedObject(_ record: ProjectSyncRecord) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: ProjectsFile.encoder.encode(record)) as? [String: Any])
    }

    @Test func recordCarriesFitPositionAndOpacitiesButNoPath() throws {
        let data = try ProjectsFile.encoder.encode(shared(background: projectBackgroundValue(path: path)).syncRecord(home: home))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("imagePath"))
        #expect(!text.contains("here.png"))
        let decoded = try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: data)
        #expect(decoded.background?.settings == projectBackgroundValue(path: nil))
    }

    @Test func recordWithAStrayImagePathDropsIt() throws {
        var object = try encodedObject(shared(background: nil).syncRecord(home: home))
        object["background"] = ["imagePath": path, "fit": "stretch"]
        let decoded = try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.background?.settings.imagePath == nil)
        #expect(decoded.background?.settings.fit == .stretch)
    }

    @Test func recordWithoutABackgroundKeyDecodes() throws {
        let record = shared(background: nil).syncRecord(home: home)
        #expect(try encodedObject(record)["background"] == nil)
        #expect(try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: ProjectsFile.encoder.encode(record)) == record)
    }

    @Test func wrongTypeBackgroundInARecordStillDecodesTheRecord() throws {
        let record = shared(background: nil).syncRecord(home: home)
        var object = try encodedObject(record)
        object["background"] = "not an object"
        let entry = ICloudKeyValueProjectSyncBackend.decode(try JSONSerialization.data(withJSONObject: object), id: record.id)
        guard case .record(let decoded) = entry else {
            Issue.record("the record was skipped")
            return
        }
        #expect(decoded.background == nil)
        #expect(decoded.name == record.name)
    }

    @Test func insertedRemoteProjectKeepsOpacityAndHasNoImage() {
        let remote = shared(background: nil)
        let merged = apply(record(of: remote, background: projectBackgroundValue(path: path)), to: [])
        #expect(merged.first?.background == projectBackgroundValue(path: nil))
    }

    @Test func remoteChangeReplacesOpacityAndKeepsThisMacsImage() {
        let local = shared(background: projectBackgroundValue(path: path))
        let merged = apply(record(of: local, background: secondBackgroundValue(path: nil)), to: [local])
        #expect(merged.first?.background == secondBackgroundValue(path: path))
    }

    @Test func remoteRenameKeepsThisMacsImage() {
        let local = shared(background: projectBackgroundValue(path: path))
        let merged = apply(record(of: local, background: projectBackgroundValue(path: "/Users/other/there.png"), name: "Renamed"), to: [local])
        #expect(merged.first?.name == "Renamed")
        #expect(merged.first?.background == projectBackgroundValue(path: path))
    }

    @Test func remoteFollowClearsTheBackground() {
        let local = shared(background: projectBackgroundValue(path: path))
        #expect(apply(record(of: local, background: nil), to: [local]).first?.background == nil)
    }

    @Test func applyingTheSameRecordTwiceKeepsTheImage() {
        let local = shared(background: projectBackgroundValue(path: path))
        let incoming = record(of: local, background: secondBackgroundValue(path: nil))
        let once = apply(incoming, to: [local])
        #expect(apply(incoming, to: once) == once)
        #expect(once.first?.background?.imagePath == path)
    }

    @Test func aBackgroundAddsLittleToARecord() throws {
        let without = try ProjectsFile.encoder.encode(shared(background: nil).syncRecord(home: home))
        let with = try ProjectsFile.encoder.encode(shared(background: projectBackgroundValue(path: path)).syncRecord(home: home))
        #expect(with.count - without.count < 300)
    }

    // MARK: - Shared images

    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)

    private func pathNaming(_ digest: String) -> String { "/Users/test/Library/ProjectBackgrounds/\(digest)/here.png" }

    private func honoring(_ record: ProjectSyncRecord, to local: [Project]) -> [Project] {
        ProjectSyncMerge.apply(remote: [record.id: .record(record)], to: local, home: home, now: later, honorsSharedImages: true)
    }

    private func remote(of project: Project, image: ProjectSyncImage) -> ProjectSyncRecord {
        var record = project.syncRecord(home: home)
        record.background = ProjectSyncBackground(secondBackgroundValue(path: nil), image: image)
        record.modifiedAt = later
        return record
    }

    @Test func recordWithSharedImagesOffIsByteIdenticalToToday() throws {
        var project = shared(background: projectBackgroundValue(path: pathNaming(digestA)))
        let before = try ProjectsFile.encoder.encode(project.syncRecord(home: home))
        project.sharedImage = .named(digest: digestA, name: "Harbor")
        #expect(try ProjectsFile.encoder.encode(project.syncRecord(home: home)) == before)
        #expect(try ProjectsFile.encoder.encode(project.syncRecord(home: home, carriesSharedImage: false)) == before)
    }

    @Test func recordCarriesDigestAndNameButNoPath() throws {
        var project = shared(background: projectBackgroundValue(path: pathNaming(digestA)))
        project.sharedImage = .named(digest: digestA, name: "Harbor")
        let data = try ProjectsFile.encoder.encode(project.syncRecord(home: home, carriesSharedImage: true))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("imagePath"))
        #expect(!text.contains("here.png"))
        let decoded = try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: data)
        #expect(decoded.background?.image == .named(digest: digestA, name: "Harbor"))
        #expect(decoded.background?.settings == projectBackgroundValue(path: nil))
    }

    @Test func recordCarriesRemoval() throws {
        var project = shared(background: projectBackgroundValue(path: nil))
        project.sharedImage = .removed
        let data = try ProjectsFile.encoder.encode(project.syncRecord(home: home, carriesSharedImage: true))
        #expect(try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: data).background?.image == .removed)
    }

    @Test(arguments: ["../../etc/passwd", "ABC", String(repeating: "A", count: 64), String(repeating: "a", count: 63), ""])
    func recordWithABadDigestReadsAsUnspecified(digest: String) throws {
        var object = try encodedObject(shared(background: nil).syncRecord(home: home))
        object["background"] = ["fit": "stretch", "imageDigest": digest, "imageName": "x"]
        let decoded = try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.background?.image == .unspecified)
        #expect(decoded.background?.settings.fit == .stretch)
    }

    @Test func recordWithAWrongTypeImageKeyReadsAsUnspecified() throws {
        var object = try encodedObject(shared(background: nil).syncRecord(home: home))
        object["background"] = ["fit": "stretch", "imageDigest": 7, "imageRemoved": "yes"]
        let decoded = try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.background?.image == .unspecified)
    }

    @Test(arguments: [
        ("a/b", "ab"), ("../up", "up"), (".hidden", "hidden"), ("q\"uote", "quote"),
        ("back\\slash", "backslash"), ("ctl\u{0007}x", "ctlx"), ("co:lon", "colon"), ("//", "image"),
    ])
    func recordNameIsSanitized(raw: String, expected: String) throws {
        var object = try encodedObject(shared(background: nil).syncRecord(home: home))
        object["background"] = ["imageDigest": digestA, "imageName": raw]
        let decoded = try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.background?.image == .named(digest: digestA, name: expected))
    }

    @Test func aRemoteNamedImageMakesAnInsertedProjectPending() {
        let origin = shared(background: nil)
        let merged = honoring(remote(of: origin, image: .named(digest: digestA, name: "Harbor")), to: [])
        #expect(merged.first?.sharedImage == .named(digest: digestA, name: "Harbor"))
        #expect(merged.first?.background == secondBackgroundValue(path: nil))
        #expect(merged.first?.pendingSharedImage?.digest == digestA)
    }

    @Test func aRemoteNamedImageKeepsTheOldPathUntilItArrives() {
        let local = shared(background: projectBackgroundValue(path: pathNaming(digestA)))
        let merged = honoring(remote(of: local, image: .named(digest: digestB, name: "New")), to: [local])
        #expect(merged.first?.background == secondBackgroundValue(path: pathNaming(digestA)))
        #expect(merged.first?.pendingSharedImage?.digest == digestB)
    }

    @Test func aRemoteMatchingDigestKeepsThePath() {
        let local = shared(background: projectBackgroundValue(path: pathNaming(digestA)))
        let merged = honoring(remote(of: local, image: .named(digest: digestA, name: "Harbor")), to: [local])
        #expect(merged.first?.background == secondBackgroundValue(path: pathNaming(digestA)))
        #expect(merged.first?.pendingSharedImage == nil)
        #expect(merged.first?.sharedImage == .named(digest: digestA, name: "Harbor"))
    }

    @Test func aRemoteRemovedClearsPathAndPending() {
        var local = shared(background: projectBackgroundValue(path: pathNaming(digestA)))
        local.sharedImage = .named(digest: digestB, name: "Pending")
        let merged = honoring(remote(of: local, image: .removed), to: [local])
        #expect(merged.first?.background == secondBackgroundValue(path: nil))
        #expect(merged.first?.sharedImage == .removed)
    }

    @Test func anOlderBattyRecordKeepsImageAndPending() {
        var local = shared(background: projectBackgroundValue(path: pathNaming(digestA)))
        local.sharedImage = .named(digest: digestB, name: "Pending")
        let merged = honoring(remote(of: local, image: .unspecified), to: [local])
        #expect(merged.first?.background == secondBackgroundValue(path: pathNaming(digestA)))
        #expect(merged.first?.sharedImage == .named(digest: digestB, name: "Pending"))
    }

    @Test func withdrawalClearsPending() {
        var local = shared(background: projectBackgroundValue(path: pathNaming(digestA)))
        local.sharedImage = .named(digest: digestB, name: "Pending")
        let merged = ProjectSyncMerge.apply(remote: [:], to: [local], home: home, now: later, honorsSharedImages: true)
        #expect(merged.first?.isShared == false)
        #expect(merged.first?.sharedImage == nil)
        #expect(merged.first?.background == projectBackgroundValue(path: pathNaming(digestA)))
    }

    @Test func aNamedRecordAddsLittle() throws {
        var project = shared(background: projectBackgroundValue(path: pathNaming(digestA)))
        let without = try ProjectsFile.encoder.encode(project.syncRecord(home: home))
        project.sharedImage = .named(digest: digestA, name: String(repeating: "n", count: 100))
        let with = try ProjectsFile.encoder.encode(project.syncRecord(home: home, carriesSharedImage: true))
        #expect(with.count - without.count < 350)
    }

    @Test func mergeTwiceWithAnImageEqualsOnce() {
        let local = shared(background: projectBackgroundValue(path: pathNaming(digestA)))
        let incoming = remote(of: local, image: .named(digest: digestB, name: "New"))
        let once = honoring(incoming, to: [local])
        #expect(honoring(incoming, to: once) == once)
    }

    @Test func mergeIgnoresImageKeysWhenNotHonoring() {
        var local = shared(background: projectBackgroundValue(path: pathNaming(digestA)))
        local.sharedImage = .named(digest: digestA, name: "Kept")
        let merged = apply(remote(of: local, image: .removed), to: [local])
        #expect(merged.first?.background == secondBackgroundValue(path: pathNaming(digestA)))
        #expect(merged.first?.sharedImage == .named(digest: digestA, name: "Kept"))
        #expect(apply(remote(of: local, image: .named(digest: digestB, name: "N")), to: []).first?.sharedImage == nil)
    }
}
