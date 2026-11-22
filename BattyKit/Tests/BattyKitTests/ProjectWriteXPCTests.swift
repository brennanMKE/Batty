// ProjectWriteXPCTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

private let noContent: @MainActor (PaneContentKind) -> (any PaneContentLifecycle)? = { _ in nil }

/// A Background Sets catalog served by the fixture's fake fetcher.
@MainActor
enum HostedCatalogFixture {
    static let catalogURL = BackgroundCatalog.builtInURL
    static let imageURL = URL(string: "https://batty.sstools.co/backgrounds/one-01.png")!
    static let setName = "Set one"
    static let title = "Title one-01"

    static func serve(_ fixture: ProjectBackgroundFixture, browsed: Bool = true, image: Bool = true) throws {
        fixture.catalogFetcher.set(.ok(CatalogJSON.data(CatalogJSON.catalog())), for: catalogURL)
        if image {
            fixture.catalogFetcher.set(.ok(try BackgroundTestImage.encoded()), for: imageURL)
        }
        if browsed { SettingsPreference.markBackgroundCatalogsBrowsed(defaults: fixture.testDefaults.defaults) }
    }
}

@MainActor
struct ProjectWriteXPCTests {
    private func create(_ store: AppStateStore, _ request: ProjectWriteRequest) async -> CLIOutcome<ProjectWriteReply> {
        await store.createProjectForXPC(request)
    }

    private func reply(_ outcome: CLIOutcome<ProjectWriteReply>) -> ProjectWriteReply? {
        if case .success(let reply) = outcome { return reply }
        if case .failure(let message) = outcome { Issue.record("failed: \(message)") }
        return nil
    }

    private func failure(_ outcome: CLIOutcome<ProjectWriteReply>) -> String? {
        if case .failure(let message) = outcome { return message }
        return nil
    }

    @Test func createSavesALocalProjectWithDefaults() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let made = try #require(reply(await create(store, ProjectWriteRequest(name: "Demo", rootPath: f.root.path))))
        #expect(made.created && made.paneCount == 1 && made.tabCount == 1)
        let saved = try #require(store.projectStore.project(named: "Demo"))
        #expect(saved.color == .blue && saved.symbol == .folder)
        #expect(saved.layout == .preset(.singlePane))
        #expect(!saved.isShared && saved.approvedCommandsHash == nil && saved.runStartupCommandsOnOpen)
        #expect(saved.background == nil && saved.theme == nil)
    }

    @Test func createWithAnExistingNameIgnoringCaseFailsAndLeavesTheFileByteIdentical() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        try store.projectStore.upsert(f.project(name: "Demo", background: nil))
        let before = try Data(contentsOf: f.projectsFile)
        let message = failure(await create(store, ProjectWriteRequest(name: "demo", rootPath: f.root.path)))
        #expect(message == "a Project named \"Demo\" already exists")
        #expect(try Data(contentsOf: f.projectsFile) == before)
    }

    @Test func createRejectsARelativeOrMissingRoot() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        #expect(failure(await create(store, ProjectWriteRequest(name: "A", rootPath: "relative")))?.hasPrefix("path:") == true)
        #expect(failure(await create(store, ProjectWriteRequest(name: "A", rootPath: f.base.appendingPathComponent("gone").path)))?.hasPrefix("path:") == true)
        #expect(store.projectStore.projects.isEmpty)
    }

    @Test func createWithStartupCommandsLeavesThemUnapproved() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        _ = reply(await create(store, ProjectWriteRequest(name: "Cmds", rootPath: f.root.path, startupCommands: ["echo hi"])))
        let saved = try #require(store.projectStore.project(named: "Cmds"))
        #expect(saved.layout.panes[0].tabs[0].startupCommand == "echo hi")
        #expect(saved.approvedCommandsHash == nil)
        #expect(ProjectStartupTrust.decide(saved) == .prompt)
    }

    @Test func moreStartupCommandsThanTabsFails() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let message = failure(await create(store, ProjectWriteRequest(name: "A", rootPath: f.root.path, layout: .preset("horizontalSplit"), startupCommands: ["a", "b", "c"])))
        #expect(message == "startup-command: 3 startup commands but only 2 terminal Tabs")
        #expect(store.projectStore.projects.isEmpty)
    }

    @Test func createWithALayoutDocumentBuildsTheTopology() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let document = try ProjectLayoutDocument.parse(Data("""
        {"preset":"mainLeftTwoRight","panes":[
          {"kind":"terminal","tabs":[{"title":"server","cwd":".","command":"npm run dev"},{"cwd":"."}]},
          {"kind":"git-status","repository":"."},{"kind":"process-status"}],"focusedPane":1}
        """.utf8))
        let made = try #require(reply(await create(store, ProjectWriteRequest(name: "Web", rootPath: f.root.path, layout: .document(document)))))
        #expect(made.paneCount == 3 && made.tabCount == 2)
        let saved = try #require(store.projectStore.project(named: "Web"))
        #expect(saved.layout.preset == .mainLeftTwoRight)
        #expect(saved.layout.panes.map(\.kind) == [.terminal, .gitStatus, .processStatus])
        #expect(saved.layout.panes[0].tabs[0].title == "server")
        #expect(saved.layout.focusedSlot == 1)
    }

    @Test func aLayoutWithABadKindFailsNamingTheField() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let document = ProjectLayoutDocument(preset: "singlePane", panes: [.init(kind: "termnial")])
        let message = failure(await create(store, ProjectWriteRequest(name: "A", rootPath: f.root.path, layout: .document(document))))
        #expect(message?.hasPrefix("panes[0].kind:") == true)
        #expect(store.projectStore.projects.isEmpty)
    }

    @Test func aLayoutWithARejectedCommandFailsNamingTheField() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let document = ProjectLayoutDocument(preset: "singlePane", panes: [.init(kind: "terminal", tabs: [.init(command: "echo \u{1B}x")])])
        let message = failure(await create(store, ProjectWriteRequest(name: "A", rootPath: f.root.path, layout: .document(document))))
        #expect(message?.hasPrefix("layout.panes[0].tabs[0].command:") == true)
        #expect(store.projectStore.projects.isEmpty)
    }

    /// Non-default in every field the edit must keep.
    private func rich(_ f: ProjectBackgroundFixture, store: AppStateStore) async throws -> Project {
        let path = try await f.copy()
        var layout = ProjectLayout.preset(.horizontalSplit)
        var pane = ProjectPane.terminal(tabs: [ProjectTab(title: "t", workingDirectory: ".", startupCommand: "ls", background: secondBackgroundValue(path: path))])
        pane.background = projectBackgroundValue(path: path)
        layout.root = layout.root.withPanes([pane, .terminal()])
        layout.splitFractions = [[0.3, 0.7]]
        var project = Project(
            name: "Rich", rootPath: f.root.path, color: .violet, symbol: .chip, layout: layout,
            runStartupCommandsOnOpen: true, approvedCommandsHash: "abc", lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_000),
            customColorHex: "#123456", background: projectBackgroundValue(path: path), theme: ThemePair(dark: "Batty Dark", light: "Batty Light"))
        project.notificationsMuted = true
        try store.projectStore.upsert(project)
        return try #require(store.projectStore.project(id: project.id))
    }

    @Test func editChangesOnlyTheGivenFields() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let stored = try await rich(f, store: store)
        let made = try #require(reply(await store.editProjectForXPC(ProjectWriteRequest(target: "rich", color: "green"))))
        #expect(!made.created && made.appliesOnNextOpen.isEmpty)
        var expected = stored
        expected.color = .green
        expected.customColorHex = nil
        var saved = try #require(store.projectStore.project(id: stored.id))
        saved.modifiedAt = expected.modifiedAt
        #expect(saved == expected)
    }

    @Test func editRenameCollisionFails() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        try store.projectStore.upsert(f.project(name: "One", background: nil))
        try store.projectStore.upsert(f.project(name: "Two", background: nil))
        let message = failure(await store.editProjectForXPC(ProjectWriteRequest(target: "One", name: "TWO")))
        #expect(message == "a Project named \"Two\" already exists")
    }

    @Test func editReplacesTheLayoutAndReportsAppliesOnNextOpen() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let stored = try await rich(f, store: store)
        let session = try store.openProject(id: stored.id, mode: .openNew, contentFactory: noContent).session
        let panesBefore = session.tree.allPanes.count
        let made = try #require(reply(await store.editProjectForXPC(ProjectWriteRequest(target: stored.id.uuidString, layout: .preset("twoByTwoGrid")))))
        #expect(made.appliesOnNextOpen == ["layout"] && made.paneCount == 4)
        #expect(store.projectStore.project(id: stored.id)?.layout == .preset(.twoByTwoGrid))
        #expect(session.tree.allPanes.count == panesBefore)
    }

    @Test func editAppliesNameColorAndBackgroundToAnOpenSession() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let stored = try await rich(f, store: store)
        let session = try store.openProject(id: stored.id, mode: .openNew, contentFactory: noContent).session
        _ = reply(await store.editProjectForXPC(ProjectWriteRequest(target: "Rich", name: "Renamed", color: "teal", terminalOpacityPercent: 40)))
        #expect(session.title == "Renamed")
        #expect(session.sessionColor == .teal)
        #expect(session.backgroundOverride?.terminalOpacity == 0.4)
        #expect(session.tree.allPanes.count == 2)
    }

    @Test func editPassesTheStoredProjectAsPrevious() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let stored = try await rich(f, store: store)
        let session = try store.openProject(id: stored.id, mode: .openNew, contentFactory: noContent).session
        let window = try #require(store.windows.first { $0.sessions.contains { $0.id == session.id } })
        window.setSessionColor(id: session.id, to: SessionColor.amber.rawValue)
        _ = reply(await store.editProjectForXPC(ProjectWriteRequest(target: "Rich", name: "Renamed")))
        #expect(session.title == "Renamed")
        #expect(session.sessionColor == .amber)
    }

    @Test func editOfAnUnknownNameListsCloseMatches() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        try store.projectStore.upsert(f.project(name: "Website", background: nil))
        let message = failure(await store.editProjectForXPC(ProjectWriteRequest(target: "Webiste", color: "red")))
        #expect(message?.contains("\"Website\"") == true)
    }

    @Test func editOpacityAloneKeepsTheImage() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let stored = try await rich(f, store: store)
        _ = reply(await store.editProjectForXPC(ProjectWriteRequest(target: "Rich", imageOpacityPercent: 60)))
        let saved = try #require(store.projectStore.project(id: stored.id))
        #expect(saved.background?.imagePath == stored.background?.imagePath)
        #expect(saved.background?.imageOpacity == 0.6)
        #expect(saved.background?.fit == stored.background?.fit)
    }

    @Test func opacityWithoutAnImageFails() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let message = failure(await create(store, ProjectWriteRequest(name: "A", rootPath: f.root.path, imageOpacityPercent: 20)))
        #expect(message == "opacity: --opacity needs an image")
    }

    @Test func noBackgroundClearsIt() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let stored = try await rich(f, store: store)
        _ = reply(await store.editProjectForXPC(ProjectWriteRequest(target: "Rich", background: ProjectWriteRequest.BackgroundChoice.none)))
        let saved = try #require(store.projectStore.project(id: stored.id))
        #expect(saved.background == nil)
        #expect(saved.layout.panes[0].background == stored.layout.panes[0].background)
    }

    @Test func hostedImageBySetAndTitleIsFetchedAndCopiedIntoTheProjectFolder() async throws {
        let f = try ProjectBackgroundFixture()
        try HostedCatalogFixture.serve(f)
        let store = f.appStore()
        _ = reply(await create(store, ProjectWriteRequest(
            name: "Space", rootPath: f.root.path,
            background: .hosted(set: "set ONE", title: "title one-01"))))
        let saved = try #require(store.projectStore.project(named: "Space"))
        let path = try #require(saved.background?.imagePath)
        #expect(path.hasPrefix(f.projectFolder.path))
        #expect(saved.background?.imageOpacity == TerminalBackgroundSettings.cliFirstImageOpacity)
        #expect(f.catalogFetcher.count(HostedCatalogFixture.imageURL) == 1)
    }

    @Test func hostedImageOnATabKeepsItsHostedIdentity() async throws {
        let f = try ProjectBackgroundFixture()
        try HostedCatalogFixture.serve(f)
        let store = f.appStore()
        let document = ProjectLayoutDocument(preset: "singlePane", panes: [
            .init(kind: "terminal", tabs: [.init(background: .init(id: HostedCatalogFixture.imageURL.absoluteString, opacity: 30))]),
        ])
        _ = reply(await create(store, ProjectWriteRequest(name: "Tabbed", rootPath: f.root.path, layout: .document(document))))
        let tab = try #require(store.projectStore.project(named: "Tabbed")?.layout.panes[0].tabs[0])
        #expect(tab.background?.imageOpacity == 0.3)
        #expect(tab.background?.imagePath?.hasPrefix(f.projectFolder.path) == true)
        guard case .hosted(let url, _)? = tab.image else { Issue.record("not hosted: \(String(describing: tab.image))"); return }
        #expect(url == HostedCatalogFixture.imageURL)
    }

    @Test func aFailedHostedFetchSavesNothing() async throws {
        let f = try ProjectBackgroundFixture()
        try HostedCatalogFixture.serve(f, image: false)
        let store = f.appStore()
        let message = failure(await create(store, ProjectWriteRequest(
            name: "Space", rootPath: f.root.path, background: .hostedID(HostedCatalogFixture.imageURL.absoluteString))))
        #expect(message?.contains("couldn't download") == true)
        #expect(store.projectStore.projects.isEmpty)
    }

    @Test func anUnknownHostedIDIsRefusedWithoutAFetch() async throws {
        let f = try ProjectBackgroundFixture()
        try HostedCatalogFixture.serve(f)
        let store = f.appStore()
        let other = "https://example.invalid/evil.png"
        let message = failure(await create(store, ProjectWriteRequest(name: "Space", rootPath: f.root.path, background: .hostedID(other))))
        #expect(message?.contains("no Background Sets image") == true)
        #expect(!f.catalogFetcher.requestedURLs.contains(URL(string: other)!))
        #expect(f.catalogFetcher.count(HostedCatalogFixture.imageURL) == 0)
    }

    @Test func myImageByDigestIsCopiedIntoTheProjectFolder() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let source = try await f.copy(in: f.appWideFolder, width: 300)
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: source))
        _ = reply(await create(store, ProjectWriteRequest(name: "Mine", rootPath: f.root.path, background: .myImage(digest: digest))))
        let path = try #require(store.projectStore.project(named: "Mine")?.background?.imagePath)
        #expect(path.hasPrefix(f.projectFolder.path))
        #expect(TerminalBackgroundImageImporter.digest(ofPath: path) == digest)
    }

    @Test func backgroundFileIsImportedByDigest() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let file = f.base.appendingPathComponent("local.png")
        try BackgroundTestImage.encoded(width: 128).write(to: file)
        _ = reply(await create(store, ProjectWriteRequest(name: "Local", rootPath: f.root.path, background: .file(file.path), imageOpacityPercent: 25)))
        let saved = try #require(store.projectStore.project(named: "Local")?.background)
        #expect(saved.imagePath?.hasPrefix(f.projectFolder.path) == true)
        #expect(saved.imagePath.flatMap(TerminalBackgroundImageImporter.digest(ofPath:)) != nil)
        #expect(saved.imageOpacity == 0.25)
    }

    @Test func anUnreadableProjectsFileRefusesTheWrite() async throws {
        let f = try ProjectBackgroundFixture()
        try f.saveProjectsFile()
        let before = try Data(contentsOf: f.projectsFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.projectsFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.projectsFile.path) }
        let store = f.appStore()
        let message = failure(await create(store, ProjectWriteRequest(name: "New", rootPath: f.root.path)))
        #expect(message?.contains("can't read the saved Projects file") == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.projectsFile.path)
        #expect(try Data(contentsOf: f.projectsFile) == before)
    }

    @Test func aSharedProjectEditStillPublishes() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let backend = SwitchableProjectSyncBackend()
        store.projectSyncBackendFactory = { backend }
        var shared = f.project(name: "Shared", background: nil)
        shared.isShared = true
        try store.projectStore.upsert(shared)
        let before = backend.published.count
        _ = reply(await store.editProjectForXPC(ProjectWriteRequest(target: "Shared", color: "red")))
        #expect(backend.published.count == before + 1)
        #expect(store.projectStore.project(named: "Shared")?.isShared == true)
    }

    @Test func fromSessionCapturesTheCallersSession() async throws {
        let f = try ProjectBackgroundFixture()
        let session = f.session(2)
        let store = f.appStore(sessions: [session])
        let made = try #require(reply(await create(store, ProjectWriteRequest(name: "Captured", rootPath: f.root.path, layout: .fromSession(nil), callerSessionID: session.id))))
        #expect(made.paneCount == 2)
        #expect(store.projectStore.project(named: "Captured")?.approvedCommandsHash == nil)
    }

    @Test func fromSessionWithAnUnknownIDFails() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore(sessions: [f.session()])
        let message = failure(await create(store, ProjectWriteRequest(name: "A", rootPath: f.root.path, layout: .fromSession(UUID()))))
        #expect(message == "unknown session id")
    }

    @Test func createFromSessionLinksTheCapturedSession() async throws {
        let f = try ProjectBackgroundFixture()
        let session = f.session(2)
        let store = f.appStore(sessions: [session])
        let paneIDs = session.tree.allPanes.map(\.id)
        #expect(session.projectID == nil && session.title == "Website")
        let made = try #require(reply(await create(store, ProjectWriteRequest(name: "Captured", rootPath: f.root.path, layout: .fromSession(nil), callerSessionID: session.id))))
        #expect(session.projectID == made.id)
        #expect(session.title == "Captured" && session.titleOverride)
        #expect(session.tree.allPanes.map(\.id) == paneIDs)
    }

    @Test func editFromSessionLinksTheCapturedSession() async throws {
        let f = try ProjectBackgroundFixture()
        let session = f.session()
        let store = f.appStore(sessions: [session])
        let stored = f.project(name: "Rich", background: nil)
        try store.projectStore.upsert(stored)
        #expect(session.projectID == nil)
        _ = try #require(reply(await store.editProjectForXPC(ProjectWriteRequest(target: "Rich", layout: .fromSession(session.id)))))
        #expect(session.projectID == stored.id)
        #expect(session.title == "Rich")
    }

    @Test func fromSessionBackgroundWithoutOpacitySavesThirtyPercent() async throws {
        let f = try ProjectBackgroundFixture()
        let session = f.session()
        session.setBackgroundOverride(TerminalBackgroundSettings(imagePath: nil, terminalOpacity: 0.8))
        let store = f.appStore(sessions: [session])
        let file = f.base.appendingPathComponent("local.png")
        try BackgroundTestImage.encoded(width: 128).write(to: file)
        _ = try #require(reply(await create(store, ProjectWriteRequest(
            name: "Thirty", rootPath: f.root.path, layout: .fromSession(session.id), background: .file(file.path)))))
        let saved = try #require(store.projectStore.project(named: "Thirty")?.background)
        #expect(saved.imageOpacity == 0.3)
        #expect(saved.terminalOpacity == 0.8)
    }

    @Test func explicitOpacityWinsOverTheAgentDefault() async throws {
        let f = try ProjectBackgroundFixture()
        let session = f.session()
        session.setBackgroundOverride(TerminalBackgroundSettings(imagePath: nil, terminalOpacity: 0.8))
        let store = f.appStore(sessions: [session])
        let file = f.base.appendingPathComponent("local.png")
        try BackgroundTestImage.encoded(width: 128).write(to: file)
        _ = try #require(reply(await create(store, ProjectWriteRequest(
            name: "Explicit", rootPath: f.root.path, layout: .fromSession(session.id), background: .file(file.path), imageOpacityPercent: 55))))
        #expect(store.projectStore.project(named: "Explicit")?.background?.imageOpacity == 0.55)
    }

    @Test func fromSessionAppliesTheAgentsChoicesToTheLiveSession() async throws {
        let f = try ProjectBackgroundFixture()
        let session = f.session()
        let store = f.appStore(sessions: [session])
        let window = try #require(store.windowOwning(sessionID: session.id))
        window.setSessionColor(id: session.id, to: SessionColor.pink.rawValue)
        let file = f.base.appendingPathComponent("local.png")
        try BackgroundTestImage.encoded(width: 128).write(to: file)
        let made = try #require(reply(await create(store, ProjectWriteRequest(
            name: "Agent", rootPath: f.root.path, colorHex: "#1E90FF", symbolName: "airplane.departure",
            layout: .fromSession(session.id), background: .file(file.path)))))
        let saved = try #require(store.projectStore.project(id: made.id))
        #expect(saved.color != .pink)
        #expect(session.projectSymbolName == "airplane.departure")
        #expect(session.colorIndex == saved.color.rawValue)
        #expect(session.backgroundOverride?.imageOpacity == 0.3)
        #expect(session.backgroundOverride?.imagePath?.hasPrefix(f.projectFolder.path) == true)
        #expect(made.warnings.isEmpty)
    }

    @Test func unknownSymbolNameSavesWithAWarning() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let made = try #require(reply(await create(store, ProjectWriteRequest(name: "Typo", rootPath: f.root.path, symbolName: "not.a.real.symbol.xyz"))))
        #expect(made.warnings.contains { $0.hasPrefix("symbol-name:") && $0.contains("not.a.real.symbol.xyz") })
        #expect(store.projectStore.project(named: "Typo")?.customSymbolName == "not.a.real.symbol.xyz")
    }
}

@MainActor
struct BackgroundListXPCTests {
    private func reply(_ outcome: CLIOutcome<BackgroundListReply>) -> BackgroundListReply? {
        if case .success(let reply) = outcome { return reply }
        if case .failure(let message) = outcome { Issue.record("failed: \(message)") }
        return nil
    }

    private func failure(_ outcome: CLIOutcome<BackgroundListReply>) -> String? {
        if case .failure(let message) = outcome { return message }
        return nil
    }

    @Test func listsHostedImagesWithTheFullURLAsID() async throws {
        let f = try ProjectBackgroundFixture()
        try HostedCatalogFixture.serve(f)
        let store = f.appStore()
        let list = try #require(reply(await store.backgroundListForXPC(BackgroundListRequest())))
        let hosted = list.images.filter { $0.source == .hosted }
        #expect(hosted.count == 2)
        #expect(hosted.allSatisfy { $0.id == $0.fullURL && $0.catalogURL == BackgroundCatalog.builtInURL.absoluteString })
        #expect(hosted.first?.id == HostedCatalogFixture.imageURL.absoluteString)
        #expect(hosted.first?.set == HostedCatalogFixture.setName && hosted.first?.title == HostedCatalogFixture.title)
    }

    @Test func marksDownloadedImages() async throws {
        let f = try ProjectBackgroundFixture()
        try HostedCatalogFixture.serve(f)
        let store = f.appStore()
        let list = try #require(reply(await store.backgroundListForXPC(BackgroundListRequest())))
        #expect(list.images.allSatisfy { !$0.downloaded })
        let hosted = store.backgroundImages.hosted
        guard case .success(let image) = hosted.hostedImage(id: HostedCatalogFixture.imageURL.absoluteString) else { Issue.record("no image"); return }
        #expect(await hosted.select(image).value != nil)
        let after = try #require(reply(await store.backgroundListForXPC(BackgroundListRequest())))
        #expect(after.images.first { $0.id == HostedCatalogFixture.imageURL.absoluteString }?.downloaded == true)
    }

    @Test func listsMyImagesByDigestWithNoPath() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let source = try await f.copy(in: f.appWideFolder, width: 300)
        let digest = try #require(TerminalBackgroundImageImporter.digest(ofPath: source))
        let list = try #require(reply(await store.backgroundListForXPC(BackgroundListRequest(set: "my images"))))
        let mine = try #require(list.images.first)
        #expect(mine.source == .myImages && mine.id == digest && mine.digest == digest && mine.set == "My Images")
        #expect(mine.fullURL == nil && mine.thumbnailURL == nil)
        let json = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
        #expect(!json.contains(f.base.lastPathComponent))
    }

    @Test func setFilterIsCaseInsensitiveAndExact() async throws {
        let f = try ProjectBackgroundFixture()
        try HostedCatalogFixture.serve(f)
        let store = f.appStore()
        let list = try #require(reply(await store.backgroundListForXPC(BackgroundListRequest(set: "SET ONE"))))
        #expect(list.images.count == 2)
        #expect(failure(await store.backgroundListForXPC(BackgroundListRequest(set: "Set"))) != nil)
    }

    @Test func unknownSetFailsListingNames() async throws {
        let f = try ProjectBackgroundFixture()
        try HostedCatalogFixture.serve(f)
        let store = f.appStore()
        let message = failure(await store.backgroundListForXPC(BackgroundListRequest(set: "Nope")))
        #expect(message == "no Background Set named \"Nope\"; sets: Set one")
    }

    @Test func offlineCatalogListsCacheWithAWarning() async throws {
        let f = try ProjectBackgroundFixture()
        try HostedCatalogFixture.serve(f)
        let store = f.appStore()
        let hosted = store.backgroundImages.hosted
        await hosted.browseAppeared()
        f.catalogFetcher.set(.failure(.unreachable), for: HostedCatalogFixture.catalogURL)
        await hosted.refresh(HostedCatalogFixture.catalogURL)
        let list = try #require(reply(await store.backgroundListForXPC(BackgroundListRequest())))
        #expect(list.images.count == 2)
        #expect(list.warnings.contains { $0.contains("batty.sstools.co") })
    }

    @Test func noCacheAndNoImagesFails() async throws {
        let f = try ProjectBackgroundFixture()
        let store = f.appStore()
        let message = failure(await store.backgroundListForXPC(BackgroundListRequest()))
        #expect(message?.contains("open Background Sets") == true)
    }

    @Test func listingNeverMarksTheCatalogsBrowsed() async throws {
        let f = try ProjectBackgroundFixture()
        try HostedCatalogFixture.serve(f, browsed: false)
        let store = f.appStore()
        _ = await store.backgroundListForXPC(BackgroundListRequest())
        #expect(!store.backgroundImages.hosted.hasBrowsed)
        #expect(!f.catalogFetcher.requestedURLs.contains(HostedCatalogFixture.catalogURL))
    }
}

@MainActor
struct ProjectLayoutMappingTests {
    private func map(_ doc: ProjectLayoutDocument) throws(ProjectLayoutMappingError) -> ProjectLayout {
        try doc.makeLayout(images: [:])
    }

    private func error(_ doc: ProjectLayoutDocument) -> ProjectLayoutMappingError? {
        do { _ = try map(doc); return nil } catch { return error }
    }

    @Test func presetSlotsFillInOrder() throws {
        let layout = try map(.init(preset: "threeColumns", panes: [.init(kind: "terminal"), .init(kind: "git-status"), .init(kind: "system-metrics")]))
        #expect(layout.panes.map(\.kind) == [.terminal, .gitStatus, .systemMetrics])
        #expect(layout.preset == .threeColumns)
        #expect(try map(.init(preset: "twoByTwoGrid")).paneCount == 4)
    }

    @Test func paneCountMismatchNamesTheExpectedCount() {
        #expect(error(.init(preset: "mainLeftTwoRight", panes: [.init(kind: "terminal"), .init(kind: "terminal")]))?.message == "panes: mainLeftTwoRight has 3 Panes; got 2")
    }

    @Test func unknownPresetListsTheNames() {
        #expect(error(.init(preset: "fourColumns"))?.message.contains("twoByTwoGrid") == true)
    }

    @Test func rootTreeKeepsSlotOrder() throws {
        let layout = try map(.init(root: .split(direction: "vertical", children: [
            .split(direction: "horizontal", children: [.pane(.init(kind: "git-status")), .pane(.init(kind: "terminal"))]),
            .pane(.init(kind: "process-status")),
        ])))
        #expect(layout.panes.map(\.kind) == [.gitStatus, .terminal, .processStatus])
        #expect(layout.preset == nil)
    }

    @Test func tabsOnANonTerminalPaneFail() {
        #expect(error(.init(preset: "singlePane", panes: [.init(kind: "git-status", tabs: [.init()])]))?.path == "panes[0].tabs")
    }

    @Test func twoImageSourcesFail() {
        let doc = ProjectLayoutDocument(preset: "singlePane", panes: [.init(kind: "terminal", background: .init(id: "x", digest: "y"))])
        #expect(error(doc)?.path == "panes[0].background")
    }

    @Test func opacityOutOfRangeFails() {
        let doc = ProjectLayoutDocument(preset: "singlePane", panes: [.init(kind: "terminal", background: .init(digest: "y", opacity: 150))])
        #expect(error(doc)?.path == "panes[0].background.opacity")
    }

    @Test func focusedPaneOutOfRangeFails() {
        #expect(error(.init(preset: "horizontalSplit", focusedPane: 2))?.path == "focusedPane")
    }
}

@MainActor
struct ProjectWriteBuilderTests {
    private let base = Project(name: "P", rootPath: "/tmp", theme: ThemePair(dark: "D", light: "L"))

    private func apply(_ request: ProjectWriteRequest, to project: Project? = nil, imagePath: String?? = nil) throws(ProjectWriteError) -> Project {
        try ProjectWriteBuilder.apply(request, to: project ?? base, imagePath: imagePath)
    }

    @Test func themeSetsBothSlots() throws {
        #expect(try apply(ProjectWriteRequest(themeDark: "X", themeLight: "X")).theme == ThemePair(dark: "X", light: "X"))
    }

    @Test func themeDarkAndLightSetOne() throws {
        #expect(try apply(ProjectWriteRequest(themeDark: "X")).theme == ThemePair(dark: "X", light: "L"))
        #expect(try apply(ProjectWriteRequest(themeLight: "Y")).theme == ThemePair(dark: "D", light: "Y"))
    }

    @Test func clearThemeRemovesIt() throws {
        #expect(try apply(ProjectWriteRequest(clearTheme: true)).theme == nil)
    }

    @Test func badHexFails() {
        #expect(throws: ProjectWriteError.self) { try apply(ProjectWriteRequest(colorHex: "#12345")) }
    }

    @Test func unknownSymbolFails() {
        #expect(throws: ProjectWriteError.self) { try apply(ProjectWriteRequest(symbol: "rocket")) }
    }

    @Test func replacingAnImageKeepsItsOpacity() throws {
        var project = base
        project.background = TerminalBackgroundSettings(imagePath: "/a/old.png", imageOpacity: 0.4)
        let result = try apply(ProjectWriteRequest(), to: project, imagePath: .some("/a/new.png"))
        #expect(result.background?.imagePath == "/a/new.png" && result.background?.imageOpacity == 0.4)
    }

    @Test func firstImageGetsThirtyPercent() throws {
        let result = try apply(ProjectWriteRequest(), imagePath: .some("/a/new.png"))
        #expect(result.background?.imageOpacity == TerminalBackgroundSettings.cliFirstImageOpacity)
        #expect(result.background?.terminalOpacity == 1)
    }

    @Test func aFirstImageKeepsTheBasesTerminalOpacity() throws {
        var project = base
        project.background = TerminalBackgroundSettings(imagePath: nil, terminalOpacity: 0.7)
        let result = try apply(ProjectWriteRequest(), to: project, imagePath: .some("/a/new.png"))
        #expect(result.background?.imageOpacity == 0.3)
        #expect(result.background?.terminalOpacity == 0.7)
    }
}
