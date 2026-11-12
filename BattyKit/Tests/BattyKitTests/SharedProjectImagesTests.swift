// SharedProjectImagesTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

@MainActor
struct SharedProjectImagesTests {
    private let w: SharedImageWorld

    init() throws { w = try SharedImageWorld() }

    private func backgroundPath(_ id: UUID) -> String? { w.store.project(id: id)?.background?.imagePath }

    /// A read that never comes fails the test, and the gate opens so the rest of
    /// the test can't wait on a pass the gate still holds.
    private func requireHeldRead() async -> Bool {
        let held = await w.fake.waitForHeldRead()
        if !held {
            Issue.record("no read reached the gate")
            w.fake.releaseReads()
        }
        return held
    }

    /// Advancing past a sleeper that never registered fires nothing, and the
    /// loop it belongs to could then never finish.
    private func requireSleeper() async -> Bool {
        let registered = await w.clock.waitForSleepers(1)
        if !registered {
            Issue.record("the retry loop never slept")
            w.images.retryTask?.cancel()
        }
        return registered
    }

    // MARK: - Download

    @Test func anAbsentFileLeavesTheProjectWaitingWithNoProblem() async throws {
        let digest = try w.imageBytes().digest
        let id = w.receive(digest: digest)
        await w.pass()
        #expect(w.store.project(id: id)?.pendingSharedImage?.digest == digest)
        #expect(backgroundPath(id) == nil)
        #expect(w.images.message == nil)
    }

    @Test func anEvictedFileRequestsADownloadOnce() async throws {
        let (data, digest) = try w.imageBytes()
        w.fake.put(data, digest: digest, evicted: true)
        _ = w.receive(digest: digest)
        await w.pass()
        await w.pass()
        #expect(w.fake.count(.requestDownload(digest)) == 1)
        #expect(w.fake.count(.read(digest)) == 0)
    }

    /// The ordinary path on a second Mac: a file from another Mac starts evicted.
    @Test func anImageNamedAgainAfterItArrivedRequestsAnotherDownload() async throws {
        let (data, digest) = try w.imageBytes()
        w.fake.put(data, digest: digest, evicted: true)
        let id = w.receive(digest: digest)
        await w.pass()
        #expect(w.fake.count(.requestDownload(digest)) == 1)

        w.fake.put(data, digest: digest)
        await w.pass()
        let path = try #require(backgroundPath(id))
        try w.store.clearBackgroundImage(digest: digest)
        try w.fixture.removeFolder(of: path)
        w.fake.put(data, digest: digest, evicted: true)
        _ = w.receive(digest: digest, id: id)
        #expect(w.store.project(id: id)?.pendingSharedImage?.digest == digest)

        await w.pass()
        #expect(w.fake.count(.requestDownload(digest)) == 2)
    }

    @Test func anImageNamedAgainAfterItWasDroppedRequestsAnotherDownload() async throws {
        let (data, digest) = try w.imageBytes()
        w.fake.put(data, digest: digest, evicted: true)
        let id = w.receive(digest: digest)
        await w.pass()
        #expect(w.fake.count(.requestDownload(digest)) == 1)

        try w.store.clearBackgroundImage(digest: digest)
        await w.pass()
        _ = w.receive(digest: digest, id: id)
        #expect(w.store.project(id: id)?.pendingSharedImage?.digest == digest)

        await w.pass()
        #expect(w.fake.count(.requestDownload(digest)) == 2)
    }

    /// A failed request is why an evicted file gets read. Once a later request
    /// can succeed, that reason has gone.
    @Test func anImageNamedAgainForgetsAnEarlierFailedRequest() async throws {
        let (data, digest) = try w.imageBytes()
        w.fake.put(data, digest: digest, evicted: true)
        w.fake.setDownloadError(FakeSharedImageTransport.Failure())
        let id = w.receive(digest: digest)
        await w.pass()
        let path = try #require(backgroundPath(id))
        #expect(w.fake.count(.read(digest)) == 1)

        w.fake.setDownloadError(nil)
        try w.store.clearBackgroundImage(digest: digest)
        try w.fixture.removeFolder(of: path)
        _ = w.receive(digest: digest, id: id)
        await w.pass()
        #expect(w.fake.count(.requestDownload(digest)) == 2)
        #expect(w.fake.count(.read(digest)) == 1)
    }

    @Test func aDownloadThatThrowsStillTriesARead() async throws {
        let (data, digest) = try w.imageBytes()
        w.fake.put(data, digest: digest, evicted: true)
        w.fake.setDownloadError(FakeSharedImageTransport.Failure())
        let id = w.receive(digest: digest)
        await w.pass()
        #expect(w.fake.count(.read(digest)) == 1)
        #expect(backgroundPath(id) != nil)
    }

    @Test func aVerifiedFileBecomesALocalCopyAndSetsThePath() async throws {
        let (data, digest) = try w.imageBytes()
        w.fake.put(data, digest: digest)
        let stamped = { w.store.project(id: $0)?.modifiedAt }
        let id = w.receive(digest: digest, name: "Harbor")
        let before = stamped(id)
        let publishes = w.backend.calls.count
        await w.pass()
        let path = try #require(backgroundPath(id))
        #expect(path == w.fixture.projectFolder.appendingPathComponent(digest).appendingPathComponent("Harbor.png").path)
        #expect(TerminalBackgroundImageImporter.inspect(path: path, directory: w.fixture.projectFolder) == .usable)
        #expect(w.store.project(id: id)?.pendingSharedImage == nil)
        #expect(w.store.project(id: id)?.background == projectBackgroundValue(path: path))
        #expect(stamped(id) == before)
        #expect(w.backend.calls.count == publishes)
    }

    @Test func aWrongFileIsRejectedLeavesNoCopyAndSaysSo() async throws {
        let digest = try w.imageBytes().digest
        w.fake.put(try w.imageBytes(width: 64).data, digest: digest)
        let id = w.receive(digest: digest, name: "Harbor")
        await w.pass()
        #expect(backgroundPath(id) == nil)
        #expect(w.images.message?.contains("Harbor") == true)
        #expect(!FileManager.default.fileExists(atPath: w.fixture.projectFolder.appendingPathComponent(digest).path))
    }

    @Test func anOversizedFileIsRejected() async throws {
        let (data, digest) = try w.imageBytes()
        w.fake.put(data, digest: digest)
        w.fake.setReadError(SharedImageTransportError.tooLarge)
        let id = w.receive(digest: digest, name: "Harbor")
        await w.pass()
        #expect(backgroundPath(id) == nil)
        #expect(w.images.message?.contains("too large") == true)
    }

    @Test func aDigestAlreadyHeldLocallyMakesNoTransportCall() async throws {
        let path = try await w.fixture.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        let id = w.receive(digest: digest)
        await w.pass(userInitiated: false)
        #expect(w.fake.calls.isEmpty)
        #expect(backgroundPath(id) == path)
    }

    @Test func aPickDuringADownloadWins() async throws {
        let (data, digest) = try w.imageBytes()
        w.fake.put(data, digest: digest)
        let id = w.receive(digest: digest)
        w.fake.holdReads()
        let pass = w.images.reconcile(userInitiated: true)
        guard await requireHeldRead() else { return }

        let picked = try await w.fixture.copy(width: 72)
        var project = try #require(w.store.project(id: id))
        project.background = secondBackgroundValue(path: picked)
        try w.store.upsert(project)

        w.fake.releaseReads()
        await pass.value
        await w.pass()
        #expect(backgroundPath(id) == picked)
    }

    /// The test itself runs on the main actor while the read is held.
    @Test func aSlowReadDoesNotHoldTheMainActor() async throws {
        let (data, digest) = try w.imageBytes()
        w.fake.put(data, digest: digest)
        let id = w.receive(digest: digest)
        w.fake.holdReads()
        let pass = w.images.reconcile(userInitiated: true)
        guard await requireHeldRead() else { return }
        #expect(backgroundPath(id) == nil)
        w.fake.releaseReads()
        await pass.value
        #expect(backgroundPath(id) != nil)
    }

    // MARK: - Open

    private func open(_ id: UUID) throws -> SessionRuntime {
        try w.appStore.openProject(id: id, mode: .openNew, contentFactory: SharedImageWorld.noContent).session
    }

    @Test func openingAPendingProjectDoesNotWaitForTheTransport() async throws {
        let (data, digest) = try w.imageBytes()
        w.fake.put(data, digest: digest)
        let id = w.receive(digest: digest)
        w.fake.holdReads()
        let session = try open(id)
        #expect(session.backgroundOverride?.imagePath == nil)
        guard await requireHeldRead() else { return }
        #expect(session.backgroundOverride?.imagePath == nil)
        w.fake.releaseReads()
        await w.pass()
        #expect(session.backgroundOverride?.imagePath == backgroundPath(id))
        #expect(session.backgroundOverride?.imagePath != nil)
    }

    @Test func openingAPendingProjectGivesNoTriangle() async throws {
        let digest = try w.imageBytes().digest
        let session = try open(w.receive(digest: digest))
        await w.pass()
        #expect(session.projectBackgroundImageProblem == nil)
    }

    @Test func openingALocalProjectTouchesNoTransport() async throws {
        let path = try await w.fixture.copy()
        let project = w.project(name: "Local", path: path, shared: false)
        try w.store.upsert(project)
        _ = try open(project.id)
        await w.pass(userInitiated: false)
        #expect(w.fake.calls.isEmpty)
    }

    @Test func arrivalUpdatesAnUnchangedSessionAndItsSeed() async throws {
        let (data, digest) = try w.imageBytes()
        let id = w.receive(digest: digest)
        let session = try open(id)
        await w.pass()
        #expect(session.backgroundOverride == projectBackgroundValue(path: nil))
        w.fake.put(data, digest: digest)
        await w.pass()
        let path = try #require(backgroundPath(id))
        #expect(session.backgroundOverride == projectBackgroundValue(path: path))
        #expect(session.projectBackgroundSeed == projectBackgroundValue(path: path))
    }

    @Test func arrivalLeavesASessionTheUserChanged() async throws {
        let (data, digest) = try w.imageBytes()
        let id = w.receive(digest: digest)
        let session = try open(id)
        session.setBackgroundOverride(secondBackgroundValue(path: nil))
        w.fake.put(data, digest: digest)
        await w.pass()
        #expect(backgroundPath(id) != nil)
        #expect(session.backgroundOverride == secondBackgroundValue(path: nil))
        #expect(session.projectBackgroundSeed == projectBackgroundValue(path: nil))
    }

    // MARK: - Status

    @Test func iCloudDriveOffSaysSoAndTheProjectStillSaves() async throws {
        w.fake.setAvailability(.off)
        let path = try await w.fixture.copy()
        let project = w.project(path: path)
        try w.store.upsert(project)
        await w.pass()
        #expect(w.images.message?.contains("Turn on iCloud Drive") == true)
        #expect(w.store.project(id: project.id)?.background?.imagePath == path)
        #expect(w.fake.writes.isEmpty)
    }

    @Test func notAllowedSaysWhereToAllowIt() async throws {
        w.fake.setAvailability(.notAllowed)
        try w.store.upsert(w.project(path: try await w.fixture.copy()))
        await w.pass()
        #expect(w.images.message?.contains("Privacy & Security") == true)
    }

    @Test func aDeniedWriteSaysWhereToAllowIt() async throws {
        w.fake.setWriteError(SharedImageTransportError.notAllowed)
        try w.store.upsert(w.project(path: try await w.fixture.copy()))
        await w.pass()
        #expect(w.images.message?.contains("Privacy & Security") == true)
    }

    @Test func aFullICloudSaysSo() async throws {
        w.fake.setUploadProblem(.iCloudFull)
        try w.store.upsert(w.project(path: try await w.fixture.copy()))
        await w.pass()
        #expect(w.images.message?.contains("iCloud is full") == true)
    }

    @Test func aFailedCopyDoesNotFailSave() async throws {
        w.fake.setWriteError(FakeSharedImageTransport.Failure())
        let path = try await w.fixture.copy()
        let project = w.project(path: path)
        try w.store.upsert(project)
        await w.pass()
        #expect(w.store.syncError == nil)
        #expect(ProjectStore(fileURL: w.fixture.projectsFile).project(id: project.id)?.background?.imagePath == path)
    }

    @Test func aFailedCopyDoesNotUncheckShared() async throws {
        w.fake.setWriteError(FakeSharedImageTransport.Failure())
        let project = w.project(path: try await w.fixture.copy(), shared: false)
        try w.store.upsert(project)
        try w.store.setShared(id: project.id, true)
        await w.pass()
        #expect(w.store.project(id: project.id)?.isShared == true)
    }

    // MARK: - Prompt and backoff

    @Test func noBackgroundPassTouchesTheFolderBeforeAUserAction() async throws {
        let digest = try w.imageBytes().digest
        _ = w.receive(digest: digest)
        await w.pass(userInitiated: false)
        w.fixture.notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await w.pass(userInitiated: false)
        #expect(w.fake.calls.isEmpty)
    }

    @Test func aBackgroundPassRunsOnceTheFolderWasReached() async throws {
        let digest = try w.imageBytes().digest
        _ = w.receive(digest: digest)
        await w.pass(userInitiated: true)
        w.fake.resetCalls()
        await w.pass(userInitiated: false)
        #expect(w.fake.count(.state(digest)) == 1)
    }

    @Test func becomingActiveRunsAPass() async throws {
        let digest = try w.imageBytes().digest
        _ = w.receive(digest: digest)
        await w.pass(userInitiated: true)
        w.fake.resetCalls()
        w.fixture.notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await w.pass(userInitiated: false)
        #expect(w.fake.count(.state(digest)) == 2)
    }

    @Test func backoffDoublesToTheCapAndEndsWhenNothingWaits() async throws {
        w.fake.setIsUploaded(false)
        try w.store.upsert(w.project(path: try await w.fixture.copy()))
        await w.pass()
        for delay in [30, 60, 120, 240, 480, 900, 900] {
            guard await requireSleeper() else { return }
            #expect(await w.clock.advance(by: .seconds(delay - 1)) == 0)
            #expect(await w.clock.advance(by: .seconds(1)) == 1)
        }
        guard await requireSleeper() else { return }
        w.fake.setIsUploaded(true)
        let loop = try #require(w.images.retryTask)
        #expect(await w.clock.advance(by: .seconds(900)) == 1)
        await loop.value
        #expect(w.clock.pendingCount == 0)
        #expect(w.images.retryTask == nil)
    }

    @Test func noUploadAfterAnHourSaysSo() async throws {
        w.fake.setIsUploaded(false)
        try w.store.upsert(w.project(path: try await w.fixture.copy()))
        await w.pass()
        #expect(w.images.message == nil)
        guard await requireSleeper() else { return }
        await w.clock.advance(by: .seconds(3_600))
        guard await requireSleeper() else { return }
        await w.pass()
        #expect(w.images.message?.contains("after an hour") == true)
    }

    // MARK: - Removal and repair

    @Test func removalDoesNotTriggerADownload() async throws {
        let (data, digest) = try w.imageBytes()
        let id = w.receive(digest: digest)
        await w.pass()
        try w.store.clearBackgroundImage(digest: digest)
        w.fake.put(data, digest: digest)
        w.fake.resetCalls()
        await w.pass()
        #expect(w.fake.calls.isEmpty)
        #expect(backgroundPath(id) == nil)
    }

    @Test func reUploadsADigestARecordNamesButTheFolderLost() async throws {
        let path = try await w.fixture.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        try w.store.upsert(w.project(path: path))
        await w.pass()
        w.fake.removeFile(digest: digest)
        await w.pass()
        #expect(w.fake.count(.write(digest)) == 2)
        #expect(w.fake.hasFile(digest: digest))
    }

    // MARK: - What a sender uploads

    @Test func aDamagedLocalCopyIsNotUploaded() async throws {
        let path = try await w.fixture.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        try Data("damaged".utf8).write(to: URL(fileURLWithPath: path))
        let project = w.project(path: path)
        try w.store.upsert(project)
        await w.pass()
        #expect(w.fake.count(.state(digest)) >= 1)
        #expect(w.fake.writes.isEmpty)
        #expect(!w.fake.hasFile(digest: digest))
        #expect(backgroundPath(project.id) == path)
    }

    /// Its digest is right, so only the pixel limit can stop it.
    @Test func anOversizedLocalCopyIsNotUploaded() async throws {
        let bytes = try BackgroundTestImage.encoded(width: TerminalBackgroundImageImporter.maxPixelSize + 1, height: 4)
        let digest = BackgroundTestImage.digest(of: bytes)
        let folder = w.fixture.projectFolder.appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("Huge.png").path
        try bytes.write(to: URL(fileURLWithPath: path))
        #expect(TerminalBackgroundImageImporter.inspect(path: path, directory: w.fixture.projectFolder) == .usable)

        try w.store.upsert(w.project(path: path))
        await w.pass()
        #expect(w.fake.count(.state(digest)) >= 1)
        #expect(w.fake.writes.isEmpty)
        #expect(!w.fake.hasFile(digest: digest))
    }

    @Test func aDamagedSharedCopyIsReplaced() async throws {
        let path = try await w.fixture.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        w.fake.put(Data("damaged".utf8), digest: digest)
        try w.store.upsert(w.project(path: path))
        await w.pass()
        #expect(w.fake.count(.write(digest)) == 1)
    }

    // MARK: - Tab images

    private func tabProject(digest: String, path: String?, shared: Bool = true) -> Project {
        var project = w.project(name: "Tab Project", path: nil, shared: shared)
        project.background = nil
        let tab = ProjectTab(background: projectBackgroundValue(path: path), image: .custom(digest: digest, name: "Tab"))
        project.layout = ProjectLayout(root: .pane(.terminal(tabs: [tab])))
        return project
    }

    private func tabPath(_ id: UUID) -> String? { w.store.project(id: id)?.layout.panes[0].tabs[0].background?.imagePath }

    @Test func aSharedProjectsCustomTabImageUploads() async throws {
        let path = try await w.fixture.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        try w.store.upsert(tabProject(digest: digest, path: path))
        await w.pass(userInitiated: false)
        await w.pass()
        #expect(w.fake.hasFile(digest: digest))
    }

    @Test func aTabDigestDownloadsOnlyAfterItIsRequested() async throws {
        let (data, digest) = try w.imageBytes()
        w.fake.put(data, digest: digest)
        let project = tabProject(digest: digest, path: nil)
        try w.store.upsert(project)
        await w.pass()
        #expect(w.fake.count(.read(digest)) == 0)
        #expect(w.fake.count(.state(digest)) == 0)
        await w.images.requestTabImage(digest: digest, name: "Tab", projectID: project.id).value
        #expect(w.fake.count(.read(digest)) == 1)
        #expect(tabPath(project.id) != nil)
    }

    @Test func aRequestedTabDigestRetriesOnBackoff() async throws {
        let (data, digest) = try w.imageBytes()
        let project = tabProject(digest: digest, path: nil)
        try w.store.upsert(project)
        await w.images.requestTabImage(digest: digest, name: "Tab", projectID: project.id).value
        #expect(tabPath(project.id) == nil)
        guard await requireSleeper() else { return }
        w.fake.put(data, digest: digest)
        let loop = try #require(w.images.retryTask)
        #expect(await w.clock.advance(by: .seconds(SharedProjectImages.initialRetryDelay)) == 1)
        await loop.value
        #expect(tabPath(project.id) != nil)
    }

    @Test func aDownloadedTabImageLandsInTheCache() async throws {
        let (data, digest) = try w.imageBytes()
        w.fake.put(data, digest: digest)
        let project = tabProject(digest: digest, path: nil)
        try w.store.upsert(project)
        await w.images.requestTabImage(digest: digest, name: "Tab", projectID: project.id).value
        let path = try #require(tabPath(project.id))
        #expect(path.hasPrefix(w.fixture.downloadedFolder.path))
        #expect(!FileManager.default.fileExists(atPath: w.fixture.projectFolder.appendingPathComponent(digest).path))
        #expect(await w.appStore.downloadedImages.allEntries().map(\.digest) == [digest])
    }

    @Test func aDigestAlsoNamedByTheProjectLandsInProjectBackgrounds() async throws {
        let (data, digest) = try w.imageBytes()
        w.fake.put(data, digest: digest)
        var project = tabProject(digest: digest, path: nil)
        project.background = projectBackgroundValue(path: nil)
        project.sharedImage = .named(digest: digest, name: "Harbor")
        try w.store.upsert(project)
        await w.images.requestTabImage(digest: digest, name: "Tab", projectID: project.id).value
        let path = try #require(tabPath(project.id))
        #expect(path.hasPrefix(w.fixture.projectFolder.path))
        #expect(await w.appStore.downloadedImages.allEntries().isEmpty)
    }

    @Test func localProjectTabImageNeverReachesTheTransport() async throws {
        let path = try await w.fixture.copy()
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: path))
        try w.store.upsert(tabProject(digest: digest, path: path, shared: false))
        await w.pass()
        #expect(!w.fake.calls.contains { $0 == .write(digest) || $0 == .state(digest) || $0 == .read(digest) })
    }
}
