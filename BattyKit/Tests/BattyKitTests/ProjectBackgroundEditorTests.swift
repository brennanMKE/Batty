// ProjectBackgroundEditorTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct ProjectBackgroundEditorTests {
    private func store(_ fixture: ProjectBackgroundFixture, _ projects: Project...) throws -> ProjectStore {
        let store = ProjectStore(fileURL: fixture.projectsFile)
        for project in projects { try store.upsert(project) }
        return store
    }

    private func model(_ fixture: ProjectBackgroundFixture, _ store: ProjectStore, selecting id: UUID? = nil) -> ProjectEditorViewModel {
        ProjectEditorViewModel(store: store, initialSelection: id, directoryExists: { _ in true }, backgrounds: fixture.library, sharedImagesAvailable: true)
    }

    private func editor(_ model: ProjectEditorViewModel, appWide: TerminalBackgroundSettings = .off) -> BackgroundOverrideEditor {
        BackgroundOverrideEditor(target: model, appWide: appWide, originalOverride: model.backgroundOverride)
    }

    @Test func customSeedsFromAppWideAndCopiesItsImage() async throws {
        let fixture = try ProjectBackgroundFixture()
        let wide = try await fixture.copy(in: fixture.appWideFolder)
        let model = model(fixture, try store(fixture, fixture.project(background: nil)))
        editor(model, appWide: appWideBackgroundValue(path: wide)).selectCustom()

        let path = try #require(model.draft?.background?.imagePath)
        #expect(path != wide)
        #expect(path.hasPrefix(fixture.projectFolder.path))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(model.draft?.background == appWideBackgroundValue(path: path))
    }

    @Test func customWithNoImageIsStoredAsNoImageNotFollow() throws {
        let fixture = try ProjectBackgroundFixture()
        let projectStore = try store(fixture, fixture.project(background: nil))
        let model = model(fixture, projectStore)
        let editor = editor(model, appWide: appWideBackgroundValue(path: nil))
        editor.selectCustom()
        let saved = try #require(model.save())
        #expect(saved.background == appWideBackgroundValue(path: nil))
        #expect(!editor.isFollowing)
    }

    @Test func followWritesNoBackgroundKey() throws {
        let fixture = try ProjectBackgroundFixture()
        let model = model(fixture, try store(fixture, fixture.project(background: projectBackgroundValue(path: nil))))
        editor(model).selectFollow()
        #expect(model.save() != nil)
        let text = try String(contentsOf: fixture.projectsFile, encoding: .utf8)
        #expect(!text.contains("background"))
    }

    @Test func editingMakesTheDraftDirtyAndSaveStoresIt() throws {
        let fixture = try ProjectBackgroundFixture()
        let project = fixture.project(background: projectBackgroundValue(path: nil))
        let projectStore = try store(fixture, project)
        let model = model(fixture, projectStore)
        #expect(!model.isDirty)
        editor(model).update { $0.withTerminalOpacity(0.25) }
        #expect(model.isDirty)
        #expect(model.save() != nil)
        #expect(projectStore.project(id: project.id)?.background?.terminalOpacity == 0.25)
        #expect(!model.isDirty)
    }

    @Test func savedBackgroundSurvivesAFreshStore() throws {
        let fixture = try ProjectBackgroundFixture()
        let project = fixture.project(background: nil)
        let model = model(fixture, try store(fixture, project))
        model.setBackgroundOverride(projectBackgroundValue(path: nil))
        #expect(model.save() != nil)
        #expect(ProjectStore(fileURL: fixture.projectsFile).project(id: project.id)?.background == projectBackgroundValue(path: nil))
    }

    @Test func sheetCancelRestoresTheDraft() throws {
        let fixture = try ProjectBackgroundFixture()
        let model = model(fixture, try store(fixture, fixture.project(background: projectBackgroundValue(path: nil))))
        let editor = editor(model)
        editor.update { $0.withFit(.stretch).withImageOpacity(0.9) }
        #expect(model.isDirty)
        editor.cancel()
        #expect(model.draft?.background == projectBackgroundValue(path: nil))
        #expect(!model.isDirty)
    }

    @Test func removedImageClearsDraftAndBaselineWithoutDirtying() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy()
        let projectStore = try store(fixture, fixture.project(background: projectBackgroundValue(path: path)))
        let model = model(fixture, projectStore)
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))

        try projectStore.clearBackgroundImage(digest: digest)
        model.backgroundImageWasRemoved(digest: digest)

        #expect(model.draft?.background == projectBackgroundValue(path: nil))
        #expect(model.backgroundImageState == .none)
        #expect(!model.isDirty)
        #expect(model.draft?.captureNotes[.background] == nil)
        withExtendedLifetime(fixture) {}
    }

    @Test func removedImageOnlyInTheDraftLeavesANote() async throws {
        let fixture = try ProjectBackgroundFixture()
        let wide = try await fixture.copy(in: fixture.appWideFolder)
        let model = model(fixture, try store(fixture, fixture.project(background: nil)))
        editor(model, appWide: appWideBackgroundValue(path: wide)).selectCustom()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: wide))

        model.backgroundImageWasRemoved(digest: digest)

        #expect(model.draft?.background?.imagePath == nil)
        #expect(model.draft?.background?.terminalOpacity == appWideBackgroundValue(path: nil).terminalOpacity)
        #expect(model.draft?.captureNotes[.background] != nil)
        withExtendedLifetime(fixture) {}
    }

    @Test func cancelOverAStoredBadPathLeavesTheDraftClean() throws {
        let fixture = try ProjectBackgroundFixture()
        let bad = projectBackgroundValue(path: "/tmp/nope.png")
        let model = model(fixture, try store(fixture, fixture.project(background: bad)))
        let editor = editor(model)
        editor.selectFollow()
        editor.cancel()
        #expect(model.draft?.background == bad)
        #expect(!model.isDirty)
        #expect(model.backgroundImageState == .rejected)
    }

    @Test func cancelKeepsASavedCopyWhoseFileIsGone() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy()
        try fixture.removeFolder(of: path)
        #expect(TerminalBackgroundImageImporter.digest(ofPath: path) != nil)
        let saved = projectBackgroundValue(path: path)
        let model = model(fixture, try store(fixture, fixture.project(background: saved)))
        let editor = editor(model)
        editor.selectFollow()
        #expect(model.isDirty)
        editor.cancel()
        #expect(model.draft?.background == saved)
        #expect(!model.isDirty)
    }

    @Test func missingImageWarnsAndDoesNotBlockSave() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy()
        try fixture.removeFolder(of: path)
        let project = fixture.project(background: projectBackgroundValue(path: path))
        let projectStore = try store(fixture, project)
        let model = model(fixture, projectStore)
        model.setName("Renamed")
        let validation = model.validate()
        #expect(validation.warnings[.background] != nil)
        #expect(model.canSave(validation))
        #expect(model.save() != nil)
        #expect(projectStore.project(id: project.id)?.background?.imagePath == path)
    }

    @Test func rejectedImageWarnsAndDoesNotBlockSave() throws {
        let fixture = try ProjectBackgroundFixture()
        let model = model(fixture, try store(fixture, fixture.project(background: projectBackgroundValue(path: "/tmp/nope.png"))))
        model.setName("Renamed")
        let validation = model.validate()
        #expect(validation.warnings[.background] != nil)
        #expect(validation.errors.isEmpty)
        #expect(model.canSave(validation))
    }

    @Test func selectingAProjectInspectsOnce() async throws {
        let fixture = try ProjectBackgroundFixture()
        let first = fixture.project(name: "First", background: nil)
        let second = fixture.project(name: "Second", background: projectBackgroundValue(path: try await fixture.copy()))
        let model = model(fixture, try store(fixture, first, second), selecting: first.id)
        #expect(fixture.inspections == 0)
        model.requestSelect(second.id)
        #expect(fixture.inspections == 1)
    }

    @Test func validateAndSliderEditsDoNotInspect() async throws {
        let fixture = try ProjectBackgroundFixture()
        let model = model(fixture, try store(fixture, fixture.project(background: projectBackgroundValue(path: try await fixture.copy()))))
        fixture.resetInspections()
        _ = model.validate()
        _ = model.backgroundSummary
        _ = model.isDirty
        editor(model).update { $0.withTerminalOpacity(0.3) }
        editor(model).update { $0.withImageOpacity(0.2) }
        _ = model.validate()
        #expect(fixture.inspections == 0)
    }

    @Test func aPickedPathInspectsOnce() async throws {
        let fixture = try ProjectBackgroundFixture()
        let model = model(fixture, try store(fixture, fixture.project(background: projectBackgroundValue(path: nil))))
        let picked = try await fixture.copy()
        editor(model).update { $0.pickingImage(path: picked) }
        #expect(model.draft?.background?.imagePath == picked)
        #expect(fixture.inspections == 1)
        #expect(model.backgroundImageState == .usable)
    }

    @Test func aPathThatCannotBeCopiedStoresNoImageAndSaysSo() throws {
        let fixture = try ProjectBackgroundFixture()
        let model = model(fixture, try store(fixture, fixture.project(background: nil)))
        model.setBackgroundOverride(projectBackgroundValue(path: "/tmp/not-a-batty-copy.png"))
        #expect(model.draft?.background == projectBackgroundValue(path: nil))
        #expect(model.validate().warnings[.background] != nil)
    }

    @Test func withoutALibraryThereIsNoRowAndNoInspection() throws {
        let fixture = try ProjectBackgroundFixture()
        let model = ProjectEditorViewModel(
            store: try store(fixture, fixture.project(background: projectBackgroundValue(path: "/tmp/nope.png"))),
            directoryExists: { _ in true }
        )
        #expect(!model.showsBackground)
        #expect(model.backgroundImageState == .none)
        #expect(model.validate().warnings[.background] == nil)
        #expect(fixture.inspections == 0)
    }

    @Test func editorSaveThatLeavesTheBackgroundAloneKeepsIt() throws {
        let fixture = try ProjectBackgroundFixture()
        let value = projectBackgroundValue(path: "/tmp/stored.png")
        let project = fixture.project(background: value)
        let projectStore = try store(fixture, project)
        let model = model(fixture, projectStore)
        model.setName("Renamed")
        #expect(model.save() != nil)
        #expect(ProjectStore(fileURL: fixture.projectsFile).project(id: project.id)?.background == value)
        #expect(!FileManager.default.fileExists(atPath: fixture.projectFolder.path))
    }

    @Test func summaryNamesFollowAndCustom() throws {
        let fixture = try ProjectBackgroundFixture()
        let model = model(fixture, try store(fixture, fixture.project(background: nil)))
        #expect(model.backgroundSummary == "Follows Settings")
        model.setBackgroundOverride(projectBackgroundValue(path: nil))
        #expect(model.backgroundSummary == "Custom: No image, terminal 60%")
    }

    @Test func summaryNamesTheImage() async throws {
        let fixture = try ProjectBackgroundFixture()
        let path = try await fixture.copy(named: "beach.png")
        let model = model(fixture, try store(fixture, fixture.project(background: projectBackgroundValue(path: path))))
        #expect(model.backgroundSummary.hasSuffix("terminal 60%"))
        #expect(model.backgroundSummary.contains("beach"))
    }

    @Test func projectScopeNamesSettingsAndTheProject() {
        let scope = BackgroundOverrideScope.project
        #expect(scope.followTitle == "Follow Settings")
        #expect(scope.customTitle == "Custom for This Project")
        #expect(scope.identifierPrefix == "project-background-sheet")
    }

    // MARK: - Shared images

    private static let digest = String(repeating: "a", count: 64)

    private func pendingModel(_ fixture: ProjectBackgroundFixture) throws -> (ProjectEditorViewModel, ProjectStore, Project) {
        let store = ProjectStore(fileURL: fixture.projectsFile, sharedImagesEnabled: true)
        var project = fixture.project(background: projectBackgroundValue(path: nil))
        project.isShared = true
        project.sharedImage = .named(digest: Self.digest, name: "Harbor")
        try store.upsert(project)
        return (model(fixture, store, selecting: project.id), store, project)
    }

    @Test func pendingCaptionNamesTheImage() throws {
        let fixture = try ProjectBackgroundFixture()
        let (model, _, _) = try pendingModel(fixture)
        #expect(model.sharedImageCaption == "Waiting for Harbor from iCloud Drive.")
    }

    /// A routine Beta build reads the same `projects.json` and has no transport.
    @Test func noCaptionWhereNothingCanFetchTheImage() throws {
        let fixture = try ProjectBackgroundFixture()
        let (_, store, project) = try pendingModel(fixture)
        #expect(store.project(id: project.id)?.pendingSharedImage != nil)
        let model = ProjectEditorViewModel(store: store, initialSelection: project.id, directoryExists: { _ in true }, backgrounds: fixture.library)
        #expect(model.draft?.sharedImage == store.project(id: project.id)?.sharedImage)
        #expect(model.sharedImageCaption == nil)
    }

    @Test func noCaptionWithoutAPendingImage() throws {
        let fixture = try ProjectBackgroundFixture()
        let model = model(fixture, try store(fixture, fixture.project(background: projectBackgroundValue(path: nil))))
        #expect(model.sharedImageCaption == nil)
    }

    @Test func declineClearsTheDraftsImage() throws {
        let fixture = try ProjectBackgroundFixture()
        let (model, store, project) = try pendingModel(fixture)
        model.declineSharedImage()
        #expect(model.draft?.sharedImage == nil)
        #expect(model.sharedImageCaption == nil)
        #expect(model.isDirty)
        _ = try #require(model.save())
        #expect(store.project(id: project.id)?.sharedImage == .removed)
    }

    @Test func arrivalLeavesACleanEditorClean() async throws {
        let fixture = try ProjectBackgroundFixture()
        let (_, store, project) = try pendingModel(fixture)
        let path = try await fixture.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        var rename = try #require(store.project(id: project.id))
        rename.sharedImage = .named(digest: digest, name: "Harbor")
        try store.upsert(rename)
        let reopened = self.model(fixture, store, selecting: project.id)
        #expect(!reopened.isDirty)
        try store.setResolvedSharedImage(id: project.id, digest: digest, path: path)
        reopened.sharedImageArrived(projectID: project.id, path: path)
        #expect(reopened.draft?.background?.imagePath == path)
        #expect(reopened.backgroundImageState == .usable)
        #expect(!reopened.isDirty)
        #expect(reopened.sharedImageCaption == nil)
    }

    @Test func arrivalKeepsADirtyDraftsEdits() async throws {
        let fixture = try ProjectBackgroundFixture()
        let (model, _, project) = try pendingModel(fixture)
        let picked = try await fixture.copy(width: 72)
        model.setBackgroundOverride(secondBackgroundValue(path: picked))
        let draftImage = model.draft?.background
        model.sharedImageArrived(projectID: project.id, path: "/elsewhere/\(Self.digest)/Harbor.png")
        #expect(model.draft?.background == draftImage)
        #expect(model.isDirty)
    }

    @Test func arrivalForAnotherProjectChangesNothing() throws {
        let fixture = try ProjectBackgroundFixture()
        let (model, _, _) = try pendingModel(fixture)
        let draft = model.draft
        model.sharedImageArrived(projectID: UUID(), path: "/elsewhere/\(Self.digest)/Harbor.png")
        #expect(model.draft == draft)
        #expect(!model.isDirty)
    }
}
