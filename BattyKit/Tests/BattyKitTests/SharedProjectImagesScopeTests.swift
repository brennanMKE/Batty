// SharedProjectImagesScopeTests.swift

import Foundation
import Testing
@testable import BattyKit

/// The scope rule: an image reaches iCloud only when selected for a Project set
/// to Shared, or when a Project with an image becomes Shared.
@MainActor
struct SharedProjectImagesScopeTests {
    private let w: SharedImageWorld

    init() throws { w = try SharedImageWorld() }

    /// A Shared Project with no image exists, so a pass really runs.
    private func expectNothingSent() async throws {
        try w.store.upsert(w.project(name: "Shared With No Image", path: nil))
        await w.pass()
        #expect(w.fake.calls.isEmpty)
        #expect(w.hasNoImageKeys())
    }

    @Test func libraryImageIsNeverUploaded() async throws {
        let source = w.fixture.base.appendingPathComponent("library-source.png")
        try BackgroundTestImage.encoded(width: 40).write(to: source)
        _ = try await w.fixture.imageLibrary.add(from: source)
        try await expectNothingSent()
    }

    @Test func paneImageIsNeverUploaded() async throws {
        let path = try await w.fixture.copy(in: w.fixture.paneFolder)
        let session = w.fixture.session()
        session.tree.allPanes[0].setBackgroundOverride(projectBackgroundValue(path: path))
        try await expectNothingSent()
    }

    @Test func sessionImageIsNeverUploaded() async throws {
        let path = try await w.fixture.copy(in: w.fixture.paneFolder)
        w.fixture.session().setBackgroundOverride(projectBackgroundValue(path: path))
        try await expectNothingSent()
    }

    @Test func appWideImageIsNeverUploaded() async throws {
        let path = try await w.fixture.copy(in: w.fixture.appWideFolder)
        SettingsPreference.writeBackground(appWideBackgroundValue(path: path), defaults: w.fixture.testDefaults.defaults)
        try await expectNothingSent()
    }

    @Test func localProjectImageIsNeverUploaded() async throws {
        let path = try await w.fixture.copy()
        try w.store.upsert(w.project(name: "Local", path: path, shared: false))
        #expect(w.store.projects[0].sharedImage == nil)
        try await expectNothingSent()
    }

    @Test func localProjectImagePublishesNoRecord() async throws {
        let path = try await w.fixture.copy()
        try w.store.upsert(w.project(name: "Local", path: path, shared: false))
        await w.pass()
        #expect(w.backend.calls.isEmpty)
    }

    @Test func unsavedDraftImageIsNeverUploaded() async throws {
        let path = try await w.fixture.copy()
        try w.store.upsert(w.project(path: nil))
        await w.pass()
        let model = ProjectEditorViewModel(store: w.store, initialSelection: w.store.projects[0].id, directoryExists: { _ in true }, backgrounds: w.fixture.library)
        model.setBackgroundOverride(projectBackgroundValue(path: path))
        #expect(model.draft?.background?.imagePath == path)
        await w.pass()
        #expect(w.fake.calls.isEmpty)
        #expect(w.hasNoImageKeys())
    }

    @Test func sharedProjectWithNoImageUploadsNothing() async throws {
        try await expectNothingSent()
    }

    @Test func aLibraryScanMakesNoTransportCall() async throws {
        _ = try await w.fixture.copy(in: w.fixture.appWideFolder)
        await w.appStore.backgroundImages.refresh()
        #expect(!w.appStore.backgroundImages.entries.isEmpty)
        #expect(w.fake.calls.isEmpty)
    }

    @Test func theWindowHasNoStatusForALibraryImage() async throws {
        let path = try await w.fixture.copy(in: w.fixture.appWideFolder)
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        await w.pass()
        await w.appStore.backgroundImages.refresh()
        #expect(w.appStore.backgroundImages.sharedStatus(forDigest: digest) == nil)
        #expect(w.images.sharedStatus.isEmpty)
    }

    // The same fixtures do upload once the rule is met.

    @Test func choosingAnImageForASharedProjectUploadsIt() async throws {
        let path = try await w.fixture.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        try w.store.upsert(w.project(path: nil))
        try w.store.upsert({ var p = w.store.projects[0]; p.background = projectBackgroundValue(path: path); return p }())
        await w.pass()
        #expect(w.fake.writes == [.write(digest)])
        #expect(w.images.sharedStatus[digest] == .inICloudDrive)
        #expect(w.appStore.backgroundImages.sharedStatus(forDigest: digest) == .inICloudDrive)
    }

    @Test func sharingAProjectWithAnImageUploadsIt() async throws {
        let path = try await w.fixture.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        let project = w.project(path: path, shared: false)
        try w.store.upsert(project)
        await w.pass()
        #expect(w.fake.calls.isEmpty)
        try w.store.setShared(id: project.id, true)
        await w.pass()
        #expect(w.fake.writes == [.write(digest)])
    }

    @Test func theSameImageOnALocalAndASharedProjectUploadsOnceForTheSharedOne() async throws {
        let path = try await w.fixture.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        try w.store.upsert(w.project(name: "Local", path: path, shared: false))
        try w.store.upsert(w.project(name: "Shared", path: path))
        await w.pass()
        #expect(w.fake.count(.write(digest)) == 1)
    }

    @Test func savingAnUnchangedImageWritesNoSecondCopy() async throws {
        let path = try await w.fixture.copy()
        try w.store.upsert(w.project(path: path))
        await w.pass()
        #expect(w.fake.writes.count == 1)
        try w.store.upsert(w.store.projects[0])
        await w.pass()
        #expect(w.fake.writes.count == 1)
    }

    @Test func aFailedUploadRetriesWhileTheProjectStaysShared() async throws {
        let path = try await w.fixture.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        w.fake.setWriteError(FakeSharedImageTransport.Failure())
        try w.store.upsert(w.project(path: path))
        await w.pass()
        #expect(w.images.sharedStatus[digest] == .waitingToUpload)
        w.fake.setWriteError(nil)
        await w.pass()
        #expect(w.fake.hasFile(digest: digest))
        #expect(w.images.sharedStatus[digest] == .inICloudDrive)
    }

    @Test func aRetryStopsOnceTheProjectIsUnshared() async throws {
        let path = try await w.fixture.copy()
        w.fake.setWriteError(FakeSharedImageTransport.Failure())
        let project = w.project(path: path)
        try w.store.upsert(project)
        await w.pass()
        try w.store.setShared(id: project.id, false)
        await w.pass()
        w.fake.resetCalls()
        await w.pass()
        #expect(w.fake.calls.isEmpty)
        #expect(w.images.sharedStatus.isEmpty)
        #expect(w.images.retryTask == nil)
    }
}
