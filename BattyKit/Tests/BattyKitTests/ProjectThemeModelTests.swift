// ProjectThemeModelTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct ProjectThemeModelTests {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000584")!

    private func project(theme: ThemePair? = nil) -> Project {
        Project(id: id, name: "Model", rootPath: "/tmp/model", theme: theme)
    }

    private func roundTrip(_ project: Project) throws -> Project {
        try ProjectsFile.decoder.decode(Project.self, from: ProjectsFile.encoder.encode(project))
    }

    @Test func projectWithNoThemeEncodesByteIdentically() throws {
        let text = String(decoding: try ProjectsFile.encoder.encode(project()), as: UTF8.self)
        #expect(!text.contains("theme"))
        let withEmpty = Project(id: id, name: "Model", rootPath: "/tmp/model", theme: ThemePair(dark: nil, light: nil))
        #expect(try ProjectsFile.encoder.encode(withEmpty) == ProjectsFile.encoder.encode(project()))
    }

    @Test func aProjectsFileWrittenBeforeThemesLoadsFully() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("projects.json")
        let layout = #""layout":{"root":{"type":"pane","pane":{"kind":"terminal","tabs":[{"workingDirectory":"."}]}}}"#
        let json = """
        {"version":1,"projects":[
        {"id":"\(id.uuidString)","name":"Local","rootPath":"/tmp/local","color":2,"symbol":"ai",\(layout),"runStartupCommandsOnOpen":true}
        ]}
        """
        try Data(json.utf8).write(to: file)
        let store = ProjectStore(fileURL: file)
        let loaded = try #require(store.project(id: id))
        #expect(loaded.theme == nil)
        #expect(loaded.name == "Local")
    }

    @Test func darkOnlyLightOnlyAndBothRoundTrip() throws {
        for pair in [ThemePair(dark: "Nord", light: nil), ThemePair(dark: nil, light: "Nord"), ThemePair(dark: "A", light: "B")] {
            #expect(try roundTrip(project(theme: pair)).theme == pair)
        }
    }

    @Test func unknownThemeNameSurvivesEncodeAndDecode() throws {
        let pair = ThemePair(dark: "Not In This Batty", light: nil)
        #expect(try roundTrip(project(theme: pair)).theme == pair)
    }

    @Test func wrongTypeThemeFollowsSettingsAndKeepsTheProject() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: ProjectsFile.encoder.encode(project())) as? [String: Any])
        object["theme"] = "Nord"
        let decoded = try ProjectsFile.decoder.decode(Project.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.theme == nil)
        #expect(decoded.name == "Model")
    }

    @Test func draftRoundTripKeepsTheTheme() {
        let pair = ThemePair(dark: "Nord", light: "Unknown X")
        #expect(ProjectDraft(project: project(theme: pair)).makeProject().theme == pair)
    }

    @Test func changingOnlyTheThemeMakesTheDraftDirty() {
        let original = ProjectDraft(project: project())
        var changed = original
        changed.theme = .both("Nord")
        #expect(changed != original)
    }

    @Test func upsertStampsModifiedAtForAThemeChange() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = Date(timeIntervalSince1970: 1_700_000_100)
        var now = first
        let store = ProjectStore(fileURL: base.appendingPathComponent("projects.json"), clock: { now })
        var stored = project()
        try store.upsert(stored)
        #expect(store.project(id: id)?.modifiedAt == first)
        now = second
        stored.theme = .both("Nord")
        try store.upsert(stored)
        #expect(store.project(id: id)?.modifiedAt == second)
        #expect(store.project(id: id)?.theme == .both("Nord"))
    }
}
