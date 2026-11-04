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
        object["background"] = ["imagePath": path, "fit": "cover"]
        let decoded = try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.background?.settings.imagePath == nil)
        #expect(decoded.background?.settings.fit == .cover)
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
}
