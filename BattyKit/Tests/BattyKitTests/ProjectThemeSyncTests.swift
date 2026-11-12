// ProjectThemeSyncTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct ProjectThemeSyncTests {
    private let home = "/Users/test"
    private let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_700_000_100)

    private func shared(theme: ThemePair?) -> Project {
        Project(id: UUID(), name: "Shared", rootPath: "/Users/test/a", isShared: true, modifiedAt: earlier, theme: theme)
    }

    private func record(of project: Project, theme: ThemePair?, at date: Date? = nil) -> ProjectSyncRecord {
        var remote = project
        remote.theme = theme
        remote.modifiedAt = date ?? later
        return remote.syncRecord(home: home)
    }

    private func apply(_ record: ProjectSyncRecord, to local: [Project]) -> [Project] {
        ProjectSyncMerge.apply(remote: [record.id: .record(record)], to: local, home: home, now: later)
    }

    private func encodedObject(_ record: ProjectSyncRecord) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: ProjectsFile.encoder.encode(record)) as? [String: Any])
    }

    @Test func recordCarriesTheTheme() throws {
        let record = shared(theme: ThemePair(dark: "Nord", light: nil)).syncRecord(home: home)
        let decoded = try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: ProjectsFile.encoder.encode(record))
        #expect(decoded.theme == ThemePair(dark: "Nord", light: nil))
    }

    @Test func recordWithoutAThemeHasNoThemeKey() throws {
        #expect(try encodedObject(shared(theme: nil).syncRecord(home: home))["theme"] == nil)
    }

    @Test func recordWithoutThemeKeyDecodes() throws {
        let record = shared(theme: nil).syncRecord(home: home)
        #expect(try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: ProjectsFile.encoder.encode(record)) == record)
    }

    @Test func wrongTypeThemeInARecordStillDecodesTheRecord() throws {
        let record = shared(theme: nil).syncRecord(home: home)
        var object = try encodedObject(record)
        object["theme"] = 7
        let decoded = try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.theme == nil)
        #expect(decoded.id == record.id)
    }

    @Test func insertedRemoteProjectHasTheTheme() {
        let remote = shared(theme: nil)
        let merged = apply(record(of: remote, theme: .both("Nord")), to: [])
        #expect(merged.first?.theme == .both("Nord"))
    }

    @Test func newerRemoteThemeReplacesLocal() {
        let local = shared(theme: .both("Nord"))
        let merged = apply(record(of: local, theme: ThemePair(dark: nil, light: "Other")), to: [local])
        #expect(merged.first?.theme == ThemePair(dark: nil, light: "Other"))
    }

    @Test func olderRemoteKeepsLocalTheme() {
        var local = shared(theme: .both("Nord"))
        local.modifiedAt = later
        let merged = apply(record(of: local, theme: .both("Older"), at: earlier), to: [local])
        #expect(merged.first?.theme == .both("Nord"))
    }

    @Test func remoteUnknownNameIsKept() {
        let local = shared(theme: nil)
        let merged = apply(record(of: local, theme: .both("Future Theme")), to: [local])
        #expect(merged.first?.theme == .both("Future Theme"))
    }

    @Test func aThemeAddsLittleToARecord() throws {
        let long = String(repeating: "x", count: 128)
        let without = try ProjectsFile.encoder.encode(shared(theme: nil).syncRecord(home: home))
        let with = try ProjectsFile.encoder.encode(shared(theme: ThemePair(dark: long, light: long + "")).syncRecord(home: home))
        #expect(with.count - without.count < 320)
    }
}
