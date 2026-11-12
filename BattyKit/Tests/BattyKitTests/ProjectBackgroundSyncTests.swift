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
    // MARK: - Tab images

    private let url = URL(string: "https://batty.sstools.co/backgrounds/canal.jpg")!

    private func tabbed(_ tabs: [ProjectTab]) -> Project {
        Project(id: UUID(), name: "Tabs", rootPath: "/Users/test/a",
                layout: ProjectLayout(root: .pane(.terminal(tabs: tabs))), isShared: true, modifiedAt: earlier)
    }

    private func remote(_ project: Project, tabs: [ProjectTab]) -> ProjectSyncRecord {
        var remote = project
        remote.layout = ProjectLayout(root: .pane(.terminal(tabs: tabs)))
        remote.modifiedAt = later
        return remote.syncRecord(home: home)
    }

    private func tabs(_ project: Project?) -> [ProjectTab] { project?.layout.panes.flatMap(\.tabs) ?? [] }

    private var hostedTab: ProjectTab {
        ProjectTab(title: "H", background: projectBackgroundValue(path: pathNaming(digestA)), image: .hosted(url: url, name: "Canal"))
    }

    private var customTab: ProjectTab {
        ProjectTab(title: "C", background: secondBackgroundValue(path: pathNaming(digestB)), image: .custom(digest: digestB, name: "Mine"))
    }

    @Test func recordCarriesTabSettingsAndIdentityButNoPath() throws {
        let record = tabbed([hostedTab, customTab]).syncRecord(home: home)
        let text = String(decoding: try ProjectsFile.encoder.encode(record), as: UTF8.self)
        #expect(!text.contains("here.png"))
        #expect(!text.contains("imagePath"))
        #expect(text.contains("canal.jpg"))
        #expect(text.contains(digestB))
        #expect(record.layout.panes[0].tabs.map(\.background) == [projectBackgroundValue(path: nil), secondBackgroundValue(path: nil)])
    }

    @Test func recordWithAStrayTabImagePathDropsIt() throws {
        var record = tabbed([]).syncRecord(home: home)
        record.layout = ProjectLayout(root: .pane(.terminal(tabs: [hostedTab])))
        let project = Project(syncRecord: record, home: home)
        #expect(tabs(project)[0].background == projectBackgroundValue(path: nil))
        #expect(tabs(project)[0].image == hostedTab.image)
    }

    @Test func tabSelectionRoundTripsThroughARecord() throws {
        let record = tabbed([hostedTab, customTab]).syncRecord(home: home)
        let decoded = try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: ProjectsFile.encoder.encode(record))
        let project = Project(syncRecord: decoded, home: home)
        #expect(tabs(project).map(\.image) == [hostedTab.image, customTab.image])
    }

    @Test func customDigestIsInTheRecordWithTheFlagOff() throws {
        let data = try ProjectsFile.encoder.encode(tabbed([customTab]).syncRecord(home: home, carriesSharedImage: false))
        #expect(String(decoding: data, as: UTF8.self).contains(digestB))
    }

    @Test func mergeKeepsThisMacsPathForTheSameIdentity() {
        let local = tabbed([hostedTab, customTab])
        var changed = customTab
        changed.background = changed.background?.withTerminalOpacity(0.3)
        let merged = apply(remote(local, tabs: [hostedTab, changed]), to: [local])
        #expect(tabs(merged.first).map { $0.background?.imagePath } == [pathNaming(digestA), pathNaming(digestB)])
        #expect(tabs(merged.first)[1].background?.terminalOpacity == 0.3)
    }

    @Test func mergeFollowsAnImageWhenTabsAreReordered() {
        let local = tabbed([hostedTab, customTab])
        let merged = apply(remote(local, tabs: [customTab, hostedTab]), to: [local])
        #expect(tabs(merged.first).map { $0.background?.imagePath } == [pathNaming(digestB), pathNaming(digestA)])
    }

    @Test func mergeOfAnAddedTabDoesNotBorrowANeighboursImage() {
        let local = tabbed([hostedTab])
        let added = ProjectTab(title: "New", background: secondBackgroundValue(path: nil))
        let merged = apply(remote(local, tabs: [added, hostedTab]), to: [local])
        #expect(tabs(merged.first).map { $0.background?.imagePath } == [nil, pathNaming(digestA)])
    }

    @Test func mergeLeavesANewIdentityPending() {
        let local = tabbed([ProjectTab(title: "Plain")])
        let merged = apply(remote(local, tabs: [customTab]), to: [local])
        #expect(tabs(merged.first)[0].image == customTab.image)
        #expect(tabs(merged.first)[0].background?.imagePath == nil)
        #expect(tabs(merged.first)[0].background == secondBackgroundValue(path: nil))
    }

    @Test func twoMacsHostedCopiesWithDifferentDigestsMatchByURL() {
        var mine = hostedTab
        mine.background = mine.background?.withImagePath(pathNaming(digestB))
        let local = tabbed([mine])
        var theirs = hostedTab
        theirs.background = theirs.background?.withImagePath(pathNaming(digestA))
        let merged = apply(remote(local, tabs: [theirs]), to: [local])
        #expect(tabs(merged.first)[0].background?.imagePath == pathNaming(digestB))
    }

    @Test func remoteFollowOnATabClearsItsImage() {
        let local = tabbed([hostedTab])
        let merged = apply(remote(local, tabs: [ProjectTab(title: "H")]), to: [local])
        #expect(tabs(merged.first)[0].background == nil)
        #expect(tabs(merged.first)[0].image == nil)
    }

    @Test func mergeTwiceWithTabImagesEqualsOnce() {
        let local = tabbed([hostedTab, customTab])
        let record = remote(local, tabs: [customTab, hostedTab])
        let once = apply(record, to: [local])
        #expect(apply(record, to: once) == once)
    }

    @Test func tabBackgroundsAddLittleToARecord() throws {
        let plain = Project(id: UUID(), name: "Big", rootPath: "/Users/test/a",
                            layout: ProjectLayout(root: .split(direction: .horizontal, children: [
                                .pane(.terminal(tabs: [ProjectTab(), ProjectTab()])), .pane(.terminal(tabs: [ProjectTab(), ProjectTab()])),
                                .pane(.terminal(tabs: [ProjectTab()])), .pane(.terminal(tabs: [ProjectTab()])),
                            ])), isShared: true, modifiedAt: earlier)
        var full = plain
        full.layout = plain.layout.mappingTabs { tab in
            var tab = tab
            tab.background = projectBackgroundValue(path: pathNaming(digestA))
            tab.image = .hosted(url: url, name: String(repeating: "n", count: ProjectSharedImage.maxNameBytes))
            return tab
        }
        let without = try ProjectsFile.encoder.encode(plain.syncRecord(home: home))
        let with = try ProjectsFile.encoder.encode(full.syncRecord(home: home))
        #expect(with.count - without.count < 300 + 6 * 500)
        #expect(with.count < 1_000_000)
    }

    @Test func recordWithNoTabBackgroundsIsByteIdenticalToToday() throws {
        let project = tabbed([ProjectTab(title: "A", startupCommand: "make"), ProjectTab()])
        let text = String(decoding: try ProjectsFile.encoder.encode(project.syncRecord(home: home)), as: UTF8.self)
        #expect(!text.contains("background"))
        #expect(!text.contains("\"image\""))
    }

    // MARK: - Pane level and Session state (#0589)

    private static let paneDigest = String(repeating: "d", count: 64)

    private func withPaneImage(_ project: Project, path: String?) -> Project {
        var project = project
        project.layout = ProjectLayout(root: .pane(ProjectPane(
            kind: .terminal,
            tabs: [ProjectTab()],
            background: projectBackgroundValue(path: path),
            image: .custom(digest: Self.paneDigest, name: "pane")
        )))
        return project
    }

    @Test func syncRecordStripsThePaneImagePathAndKeepsItsIdentity() throws {
        let project = withPaneImage(shared(background: nil), path: "/Users/test/Library/ProjectBackgrounds/\(Self.paneDigest)/pane.png")
        let record = project.syncRecord(home: home)
        #expect(record.layout.panes[0].background?.imagePath == nil)
        #expect(record.layout.panes[0].image == .custom(digest: Self.paneDigest, name: "pane"))
        #expect(project.tabCustomDigests.contains(Self.paneDigest))
    }

    @Test func muteAndPaneListExpansionSync() throws {
        var project = shared(background: nil)
        #expect(try encodedObject(project.syncRecord(home: home))["notificationsMuted"] == nil)
        project.notificationsMuted = true
        project.paneListExpanded = true
        let record = project.syncRecord(home: home)
        let object = try encodedObject(record)
        #expect(object["notificationsMuted"] as? Bool == true)
        #expect(object["paneListExpanded"] as? Bool == true)
        let inserted = try #require(apply(record, to: []).first)
        #expect(inserted.notificationsMuted)
        #expect(inserted.paneListExpanded)
    }
}
