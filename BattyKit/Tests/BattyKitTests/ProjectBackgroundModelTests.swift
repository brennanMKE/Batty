// ProjectBackgroundModelTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct ProjectBackgroundModelTests {
    private let full = projectBackgroundValue(path: "/tmp/batty-model-tests/photo.png")

    private func project(background: TerminalBackgroundSettings? = nil) -> Project {
        Project(id: UUID(), name: "Model", rootPath: "/tmp/model", background: background)
    }

    private func decoded(_ project: Project, background: Any) throws -> Project {
        var object = try #require(try JSONSerialization.jsonObject(with: ProjectsFile.encoder.encode(project)) as? [String: Any])
        object["background"] = background
        return try ProjectsFile.decoder.decode(Project.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func settings(_ object: [String: Any]) throws -> TerminalBackgroundSettings {
        try #require(try decoded(project(), background: object).background)
    }

    /// A literal, so a later encoder change can't make this vacuous.
    @Test func aProjectsFileWrittenBeforeBackgroundsLoadsFully() throws {
        let fixture = try ProjectBackgroundFixture()
        let local = UUID()
        let shared = UUID()
        let layout = #""layout":{"root":{"type":"pane","pane":{"kind":"terminal","tabs":[{"workingDirectory":"."}]}}}"#
        let json = """
        {"version":1,"projects":[
        {"id":"\(local.uuidString)","name":"Local","rootPath":"/tmp/local","color":2,"symbol":"ai",\(layout),\
        "runStartupCommandsOnOpen":true},
        {"id":"\(shared.uuidString)","name":"Shared","rootPath":"/tmp/shared","color":2,"customColor":"#123456",\
        "symbol":"folder","symbolName":"star",\(layout),"runStartupCommandsOnOpen":false,\
        "isShared":true,"modifiedAt":"2026-10-01T12:00:00.000Z"}
        ]}
        """
        try Data(json.utf8).write(to: fixture.projectsFile)

        let store = ProjectStore(fileURL: fixture.projectsFile)
        #expect(store.projects.map(\.id) == [local, shared])
        #expect(store.projects.allSatisfy { $0.background == nil })
        #expect(!store.mayReferenceUnlistedImages)

        let loadedLocal = try #require(store.project(id: local))
        #expect(loadedLocal.color == .green)
        #expect(loadedLocal.symbol == .ai)
        #expect(loadedLocal.customColorHex == nil)
        #expect(loadedLocal.customSymbolName == nil)
        #expect(loadedLocal.runStartupCommandsOnOpen)
        #expect(!loadedLocal.isShared)
        #expect(loadedLocal.modifiedAt == nil)

        let loadedShared = try #require(store.project(id: shared))
        #expect(loadedShared.customColorHex == "#123456")
        #expect(loadedShared.symbol == .folder)
        #expect(loadedShared.customSymbolName == "star")
        #expect(!loadedShared.runStartupCommandsOnOpen)
        #expect(loadedShared.isShared)
        #expect(loadedShared.modifiedAt == Date(timeIntervalSince1970: 1_790_856_000))

        try store.recordOpen(id: local, at: Date(timeIntervalSince1970: 1_800_000_000))
        let backup = fixture.projectsFile.deletingLastPathComponent().appendingPathComponent(ProjectStore.backupFileName)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func absentBackgroundDecodesAsFollow() throws {
        let data = try ProjectsFile.encoder.encode(project())
        #expect(try ProjectsFile.decoder.decode(Project.self, from: data).background == nil)
    }

    @Test func projectWithNoBackgroundEncodesByteIdentically() throws {
        let plain = project()
        let data = try ProjectsFile.encoder.encode(plain)
        #expect(!String(decoding: data, as: UTF8.self).contains("background"))

        var withBackground = plain
        withBackground.background = full
        var object = try #require(try JSONSerialization.jsonObject(with: ProjectsFile.encoder.encode(withBackground)) as? [String: Any])
        #expect(object.removeValue(forKey: "background") != nil)
        let stripped = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let original = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.prettyPrinted, .sortedKeys])
        #expect(stripped == original, "the key is the only difference")
        #expect(try ProjectsFile.encoder.encode(ProjectsFile.decoder.decode(Project.self, from: data)) == data)
    }

    @Test func fullBackgroundSurvivesEncodeAndDecode() throws {
        let data = try ProjectsFile.encoder.encode(project(background: full))
        #expect(try ProjectsFile.decoder.decode(Project.self, from: data).background == full)
    }

    @Test(arguments: [0, 1, 2])
    func wrongTypeBackgroundKeepsTheProjectAndFollows(index: Int) throws {
        let values: [Any] = ["text", 42, [1, 2]]
        let plain = project()
        let loaded = try decoded(plain, background: values[index])
        #expect(loaded.id == plain.id)
        #expect(loaded.background == nil)
    }

    @Test func unknownFitAndPositionFallBackAndKeepTheRest() throws {
        let value = try settings(["fit": "future", "position": 7, "imageOpacity": 0.35, "terminalOpacity": 0.6, "opacityAffectsCells": true])
        #expect(value == TerminalBackgroundSettings(imagePath: nil, fit: .cover, position: .center, imageOpacity: 0.35, terminalOpacity: 0.6, opacityAffectsCells: true))
    }

    @Test func missingFitDecodesToFill() throws {
        #expect(try settings(["position": "top-right"]).fit == .cover)
    }

    @Test func nonNumericOpacityFallsBackAndKeepsTheRest() throws {
        let value = try settings(["fit": "stretch", "position": "top-right", "imageOpacity": "half", "terminalOpacity": [], "opacityAffectsCells": "yes"])
        #expect(value == TerminalBackgroundSettings(imagePath: nil, fit: .stretch, position: .topRight))
    }

    @Test func outOfRangeOpacityIsClamped() throws {
        let value = try settings(["imageOpacity": -2, "terminalOpacity": 7])
        #expect(value.imageOpacity == 0)
        #expect(value.terminalOpacity == 1)
    }

    @Test(arguments: ["relative/photo.png", "/tmp/a\nb.png"])
    func relativeOrControlCharacterPathDecodesToNoImage(path: String) throws {
        let value = try settings(["imagePath": path, "terminalOpacity": 0.6])
        #expect(value.imagePath == nil)
        #expect(value.terminalOpacity == 0.6)
    }

    @Test func oneBadBackgroundDropsNoProjectAndWritesNoBackup() throws {
        let fixture = try ProjectBackgroundFixture()
        let good = fixture.project(name: "Good", background: nil)
        let bad = fixture.project(name: "Bad", background: nil)
        var badObject = try #require(try JSONSerialization.jsonObject(with: ProjectsFile.encoder.encode(bad)) as? [String: Any])
        badObject["background"] = "not an object"
        let goodObject = try JSONSerialization.jsonObject(with: ProjectsFile.encoder.encode(good))
        try JSONSerialization.data(withJSONObject: ["version": 1, "projects": [goodObject, badObject]]).write(to: fixture.projectsFile)

        let store = ProjectStore(fileURL: fixture.projectsFile)
        #expect(store.projects.map(\.name) == ["Good", "Bad"])
        #expect(!store.mayReferenceUnlistedImages)
        try store.recordOpen(id: bad.id, at: Date())
        #expect(!FileManager.default.fileExists(atPath: fixture.backupFile.path))
    }

    @Test func fileStaysVersionOne() throws {
        let fixture = try ProjectBackgroundFixture()
        try ProjectStore(fileURL: fixture.projectsFile).upsert(fixture.project(background: full))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.projectsFile)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
    }

    @Test func projectInitKeepsBackground() {
        #expect(project(background: full).background == full)
    }

    @Test func draftFromProjectKeepsBackground() {
        #expect(ProjectDraft(project: project(background: full)).background == full)
    }

    @Test func draftInitKeepsBackground() {
        #expect(ProjectDraft(name: "A", rootPath: "/tmp", color: .blue, background: full).background == full)
    }

    @Test func makeProjectKeepsBackground() {
        #expect(ProjectDraft(project: project(background: full)).makeProject().background == full)
    }

    @Test func changingBackgroundDoesNotChangeTheCommandsHash() {
        let tab = ProjectTab(startupCommand: "make")
        var value = Project(name: "A", rootPath: "/tmp", layout: ProjectLayout(root: .pane(.terminal(tabs: [tab]))))
        let before = value.startupCommandsHash
        value.background = full
        #expect(value.startupCommandsHash == before)
    }
    private func tabbed(_ tabs: [ProjectTab], background: TerminalBackgroundSettings? = nil) -> Project {
        Project(id: UUID(), name: "Model", rootPath: "/tmp/model", layout: ProjectLayout(root: .pane(.terminal(tabs: tabs))), background: background)
    }

    @Test func projectWithNoTabBackgroundsEncodesByteIdentically() throws {
        let plain = tabbed([ProjectTab(title: "A", startupCommand: "make"), ProjectTab()])
        let data = try ProjectsFile.encoder.encode(plain)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("background"))
        #expect(try ProjectsFile.encoder.encode(ProjectsFile.decoder.decode(Project.self, from: data)) == data)
        let legacy = Data(#"{"title":"A","workingDirectory":".","startupCommand":"make"}"#.utf8)
        let tab = try ProjectsFile.decoder.decode(ProjectTab.self, from: legacy)
        #expect(tab == ProjectTab(title: "A", startupCommand: "make"))
    }

    @Test func tabBackgroundSurvivesEncodeAndDecode() throws {
        let data = try ProjectsFile.encoder.encode(tabbed([ProjectTab(background: full), ProjectTab()]))
        let loaded = try ProjectsFile.decoder.decode(Project.self, from: data)
        #expect(loaded.layout.panes[0].tabs.map(\.background) == [full, nil])
    }

    @Test func aBadTabBackgroundCostsOnlyThatTab() throws {
        let value = tabbed([ProjectTab(title: "A", background: full), ProjectTab(title: "B", background: full)])
        var object = try #require(try JSONSerialization.jsonObject(with: ProjectsFile.encoder.encode(value)) as? [String: Any])
        var layout = try #require(object["layout"] as? [String: Any])
        var root = try #require(layout["root"] as? [String: Any])
        var pane = try #require(root["pane"] as? [String: Any])
        var tabs = try #require(pane["tabs"] as? [[String: Any]])
        tabs[0]["background"] = "text"
        pane["tabs"] = tabs
        root["pane"] = pane
        layout["root"] = root
        object["layout"] = layout
        let loaded = try ProjectsFile.decoder.decode(Project.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(loaded.id == value.id)
        #expect(loaded.layout.panes[0].tabs.map(\.title) == ["A", "B"])
        #expect(loaded.layout.panes[0].tabs.map(\.background) == [nil, full])
    }

    @Test func makeProjectKeepsTabBackgrounds() {
        let made = ProjectDraft(project: tabbed([ProjectTab(background: full), ProjectTab()])).makeProject()
        #expect(made.layout.panes[0].tabs.map(\.background) == [full, nil])
    }

    @Test func changingATabBackgroundDoesNotChangeTheCommandsHash() {
        var value = tabbed([ProjectTab(startupCommand: "make")])
        let before = value.startupCommandsHash
        value.layout = value.layout.mappingTabBackgrounds { $0 }
        value.layout.root = .pane(.terminal(tabs: [ProjectTab(startupCommand: "make", background: full)]))
        #expect(value.startupCommandsHash == before)
    }

    @Test func allBackgroundImagePathsListsProjectAndTabs() {
        let other = projectBackgroundValue(path: "/tmp/batty-model-tests/other.png")
        let value = tabbed([ProjectTab(background: other), ProjectTab(background: full), ProjectTab(background: other)], background: full)
        #expect(value.tabBackgroundImagePaths == [other.imagePath, full.imagePath].compactMap { $0 })
        #expect(value.allBackgroundImagePaths == [full.imagePath, other.imagePath].compactMap { $0 })
        let cleared = value.layout.mappingTabBackgrounds { $0.withImagePath(nil) }
        #expect(cleared.panes[0].tabs.allSatisfy { $0.background != nil && $0.background?.imagePath == nil })
    }
}
