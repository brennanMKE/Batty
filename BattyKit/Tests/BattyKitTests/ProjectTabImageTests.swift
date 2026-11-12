// ProjectTabImageTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct ProjectTabImageTests {
    private static let digestA = String(repeating: "a", count: 64)
    private static let digestB = String(repeating: "b", count: 64)
    private static let url = URL(string: "https://batty.sstools.co/backgrounds/canal.jpg")!
    private static func path(_ digest: String, name: String = "Canal After Rain") -> String { "/images/\(digest)/\(name).png" }

    private func decodeTab(_ object: [String: Any]) throws -> ProjectTab {
        try ProjectsFile.decoder.decode(ProjectTab.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func tabObject(image: [String: Any]) -> [String: Any] {
        ["workingDirectory": ".", "background": ["fit": "fill"], "image": image]
    }

    @Test func hostedIdentityIsTheURLNotTheDigest() throws {
        let record = HostedImageRecord(url: Self.url, digest: Self.digestA, fetchedAt: Date())
        let image = ProjectTabImage.derive(path: Self.path(Self.digestA), hostedRecords: [record], cacheEntries: [])
        #expect(image == .hosted(url: Self.url, name: "Canal After Rain"))
        let text = String(decoding: try ProjectsFile.encoder.encode(image), as: UTF8.self)
        #expect(text.contains("canal.jpg"))
        #expect(!text.contains(Self.digestA))
    }

    @Test func customIdentityIsTheDigest() throws {
        let image = ProjectTabImage.derive(path: Self.path(Self.digestA), hostedRecords: [], cacheEntries: [])
        #expect(image == .custom(digest: Self.digestA, name: "Canal After Rain"))
        #expect(ProjectTabImage.derive(path: "/images/not-a-digest/x.png", hostedRecords: [], cacheEntries: []) == nil)
    }

    @Test func deriveFindsAHostedRecordByDigest() {
        let other = HostedImageRecord(url: URL(string: "https://batty.sstools.co/other.jpg")!, digest: Self.digestB, fetchedAt: Date())
        let match = HostedImageRecord(url: Self.url, digest: Self.digestA, fetchedAt: Date())
        #expect(ProjectTabImage.derive(path: Self.path(Self.digestA), hostedRecords: [other, match], cacheEntries: [])?.url == Self.url)
        #expect(ProjectTabImage.derive(path: Self.path(Self.digestB), hostedRecords: [match], cacheEntries: [])?.digest == Self.digestB)
    }

    @Test func deriveFromACachedHostedCopyKeepsTheURL() {
        let entry = DownloadedImageEntry(digest: Self.digestA, url: Self.url, name: "Canal After Rain", bytes: 10, lastUsedAt: Date())
        #expect(ProjectTabImage.derive(path: Self.path(Self.digestA), hostedRecords: [], cacheEntries: [entry]) == .hosted(url: Self.url, name: "Canal After Rain"))
    }

    @Test func identityIsKeptWhenThePathStillResolvesToIt() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-tab-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let identity = TabImageIdentity(hostedDirectory: base.appendingPathComponent("Hosted"), downloadedDirectory: base.appendingPathComponent("Downloaded"))
        let hosted = ProjectTabImage.hosted(url: Self.url, name: "Canal")
        #expect(identity.identity(forPath: Self.path(Self.digestA), keeping: hosted, previousPath: Self.path(Self.digestA, name: "Other")) == hosted)
        #expect(identity.identity(forPath: Self.path(Self.digestB), keeping: hosted, previousPath: Self.path(Self.digestA)) == .custom(digest: Self.digestB, name: "Canal After Rain"))
        let custom = ProjectTabImage.custom(digest: Self.digestA, name: "Kept")
        #expect(identity.identity(forPath: Self.path(Self.digestA), keeping: custom) == custom)
        #expect(identity.identity(forPath: nil, keeping: custom) == nil)
    }

    @Test func nonHTTPSURLDecodesAsNoIdentity() throws {
        #expect(try decodeTab(tabObject(image: ["url": "http://batty.sstools.co/a.jpg", "name": "A"])).image == nil)
        #expect(try decodeTab(tabObject(image: ["url": "https:///a.jpg", "name": "A"])).image == nil)
        let long = "https://batty.sstools.co/" + String(repeating: "x", count: 2_100)
        #expect(try decodeTab(tabObject(image: ["url": long, "name": "A"])).image == nil)
        let tab = try decodeTab(tabObject(image: ["url": Self.url.absoluteString, "name": "A"]))
        #expect(tab.image == .hosted(url: Self.url, name: "A"))
        #expect(tab.background != nil)
    }

    @Test func badDigestDecodesAsNoIdentity() throws {
        let tab = try decodeTab(tabObject(image: ["digest": "xyz", "name": "A"]))
        #expect(tab.image == nil)
        #expect(tab.background != nil)
        #expect(try decodeTab(tabObject(image: ["digest": Self.digestA, "name": "A"])).image == .custom(digest: Self.digestA, name: "A"))
    }

    @Test func longNameIsSanitized() throws {
        let tab = try decodeTab(tabObject(image: ["digest": Self.digestA, "name": String(repeating: "n", count: 400)]))
        #expect((tab.image?.name.utf8.count ?? 0) <= ProjectSharedImage.maxNameBytes)
    }

    @Test func anImageWithoutABackgroundIsDropped() throws {
        let decoded = try decodeTab(["workingDirectory": ".", "image": ["digest": Self.digestA, "name": "A"]])
        #expect(decoded.image == nil)
        #expect(ProjectTab(image: .custom(digest: Self.digestA, name: "A")).image == nil)
        let layout = ProjectLayout(root: .pane(.terminal(tabs: [ProjectTab(background: projectBackgroundValue(path: nil), image: .custom(digest: Self.digestA, name: "A"))])))
        var draft = ProjectDraft(project: Project(name: "A", rootPath: "/tmp", layout: layout))
        draft.layout.root = .pane(.terminal(tabs: [{ var tab = ProjectTab(); tab.image = .custom(digest: Self.digestA, name: "A"); return tab }()]))
        #expect(draft.makeProject().layout.panes[0].tabs[0].image == nil)
    }

    @Test func projectWithNoTabImagesEncodesByteIdentically() throws {
        let layout = ProjectLayout(root: .pane(.terminal(tabs: [ProjectTab(background: projectBackgroundValue(path: nil))])))
        let project = Project(name: "A", rootPath: "/tmp", layout: layout)
        let data = try ProjectsFile.encoder.encode(project)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"image\""))
        #expect(try ProjectsFile.encoder.encode(ProjectsFile.decoder.decode(Project.self, from: data)) == data)
    }
}
