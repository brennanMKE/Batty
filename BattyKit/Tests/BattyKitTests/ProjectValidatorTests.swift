// ProjectValidatorTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct ProjectValidatorTests {
    private let root = "/projects/app"
    private let existing: Set<String> = ["/projects/app", "/projects/app/src", "/projects/app/repo"]

    private func validate(
        _ project: Project,
        others: [Project] = [],
        rootNeedsChoosing: Bool = false,
        images: [String: BackgroundImageState] = [:],
        notes: [ProjectEditorField: String] = [:]
    ) -> ProjectEditorValidation {
        ProjectValidator.validate(
            project, others: others, rootNeedsChoosing: rootNeedsChoosing,
            directoryExists: { existing.contains($0) },
            imageState: { images[$0] ?? .none },
            captureNotes: notes)
    }

    private func project(name: String = "App", tabs: [ProjectTab] = [ProjectTab()]) -> Project {
        var layout = ProjectLayout.preset(.singlePane)
        layout.root = layout.root.withPanes([.terminal(tabs: tabs)])
        return Project(name: name, rootPath: root, layout: layout)
    }

    @Test func emptyNameIsAnError() {
        #expect(validate(project(name: "")).errors[.name] != nil)
    }

    @Test func nameClashIgnoringCaseIsAnErrorNamingTheOther() {
        let other = Project(name: "Website", rootPath: root)
        let error = validate(project(name: "website"), others: [other]).errors[.name]
        #expect(error?.contains("Website") == true)
    }

    @Test func theProjectsOwnNameIsNotAClash() {
        let stored = project(name: "App")
        #expect(validate(stored, others: [stored]).errors[.name] == nil)
    }

    @Test func rootMustBeAbsoluteAndExist() {
        #expect(validate(Project(name: "A", rootPath: "relative/dir")).errors[.root] != nil)
        #expect(validate(Project(name: "A", rootPath: "/nope")).errors[.root] != nil)
        #expect(validate(Project(name: "A", rootPath: "")).errors[.root] != nil)
        #expect(validate(project()).errors[.root] == nil)
    }

    @Test func rootNeedsChoosingIsAnError() {
        #expect(validate(project(), rootNeedsChoosing: true).errors[.root] != nil)
    }

    @Test func tabDirectoryOutsideTheRootIsAnError() {
        let result = validate(project(tabs: [ProjectTab(workingDirectory: "../elsewhere")]))
        #expect(result.errors[.tabDirectory(slot: 0, tab: 0)] != nil)
    }

    @Test func missingTabDirectoryIsOnlyAWarning() {
        let result = validate(project(tabs: [ProjectTab(workingDirectory: "later")]))
        #expect(result.isValid)
        #expect(result.warnings[.tabDirectory(slot: 0, tab: 0)] != nil)
    }

    @Test func controlCharacterCommandIsAnError() {
        let result = validate(project(tabs: [ProjectTab(startupCommand: "echo \u{1B}[31m")]))
        #expect(result.errors[.tabCommand(slot: 0, tab: 0)] != nil)
        #expect(validate(project(tabs: [ProjectTab(startupCommand: "npm run dev")])).isValid)
    }

    @Test func gitStatusRepositoryIsChecked() {
        var layout = ProjectLayout.preset(.horizontalSplit, kinds: [.terminal, .gitStatus])
        layout.root = layout.root.withPanes([.terminal(), ProjectPane(kind: .gitStatus, repositoryPath: "../out")])
        #expect(validate(Project(name: "A", rootPath: root, layout: layout)).errors[.repository(slot: 1)] != nil)
        layout.root = layout.root.withPanes([.terminal(), ProjectPane(kind: .gitStatus, repositoryPath: "missing")])
        #expect(validate(Project(name: "A", rootPath: root, layout: layout)).warnings[.repository(slot: 1)] != nil)
    }

    @Test func missingImageIsAWarningAtEveryLevel() {
        let image = TerminalBackgroundSettings(imagePath: "/images/gone.png")
        var layout = ProjectLayout.preset(.singlePane)
        var pane = ProjectPane.terminal(tabs: [ProjectTab(background: image)])
        pane.background = image
        layout.root = layout.root.withPanes([pane])
        let result = validate(
            Project(name: "A", rootPath: root, layout: layout, background: image),
            images: ["/images/gone.png": .missing])
        #expect(result.isValid)
        #expect(result.warnings[.background] != nil)
        #expect(result.warnings[.paneBackground(slot: 0)] != nil)
        #expect(result.warnings[.tabBackground(slot: 0, tab: 0)] != nil)
    }

    @Test func unknownThemeIsAWarning() {
        var p = project()
        p.theme = ThemePair(dark: "No Such Theme 0700", light: nil)
        let result = validate(p)
        #expect(result.isValid)
        #expect(result.warnings[.theme]?.contains("No Such Theme 0700") == true)
    }

    @Test func captureNotesBecomeWarningsWhereNoOtherMessage() {
        let result = validate(project(name: ""), notes: [.name: "note on name", .background: "note on image"])
        #expect(result.errors[.name] != nil)
        #expect(result.warnings[.name] == nil)
        #expect(result.warnings[.background] == "note on image")
    }

    @Test func editorValidationMatchesTheValidator() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-validator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let rootURL = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let store = ProjectStore(fileURL: base.appendingPathComponent("projects.json"))
        var layout = ProjectLayout.preset(.horizontalSplit, kinds: [.terminal, .gitStatus])
        layout.root = layout.root.withPanes([
            .terminal(tabs: [ProjectTab(workingDirectory: "../out", startupCommand: "a\u{7}b"), ProjectTab(workingDirectory: "later")]),
            ProjectPane(kind: .gitStatus, repositoryPath: "missing"),
        ])
        var stored = Project(name: "Rich", rootPath: rootURL.path, layout: layout)
        stored.theme = ThemePair(dark: "No Such Theme 0700", light: nil)
        try store.upsert(stored)
        try store.upsert(Project(name: "Other", rootPath: rootURL.path))
        let model = ProjectEditorViewModel(store: store, initialSelection: stored.id, defaultRoot: { nil }, suggestName: { _ in nil })
        model.setName("other")
        let editor = model.validate()
        let draft = try #require(model.draft)
        let shared = ProjectValidator.validate(
            draft.makeProject(), others: store.projects, rootNeedsChoosing: draft.rootNeedsChoosing,
            directoryExists: ProjectEditorViewModel.fileSystemDirectoryExists,
            imageState: { _ in .none }, captureNotes: draft.captureNotes)
        #expect(!editor.errors.isEmpty && !editor.warnings.isEmpty)
        #expect(editor.errors == shared.errors)
        #expect(editor.warnings == shared.warnings)
    }

    @Test func cliPathNamesEveryField() {
        let fields: [ProjectEditorField] = [
            .name, .root, .repository(slot: 1), .tabDirectory(slot: 0, tab: 2), .tabCommand(slot: 0, tab: 1),
            .background, .tabBackground(slot: 2, tab: 0), .paneBackground(slot: 3), .theme,
        ]
        #expect(fields.map(\.cliPath) == [
            "name", "path", "layout.panes[1].repository", "layout.panes[0].tabs[2].cwd", "layout.panes[0].tabs[1].command",
            "background", "layout.panes[2].tabs[0].background", "layout.panes[3].background", "theme",
        ])
    }
}
