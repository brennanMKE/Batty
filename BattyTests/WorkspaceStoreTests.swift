// WorkspaceStoreTests.swift

import Foundation
import Testing
@testable import Batty

@MainActor
struct WorkspaceStoreTests {

    @Test func savesAtomicallyAndProducesValidJSON() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-store-\(UUID().uuidString)")
            .appendingPathComponent("workspace.json")
        let store = try WorkspaceStore(fileURL: tmp)
        let workspace = Workspace.empty()

        try store.save(workspace)

        let data = try Data(contentsOf: tmp)
        let decoded = try Workspace.decoder.decode(Workspace.self, from: data)
        #expect(decoded == workspace)

        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    }

    @Test func savesIntoMissingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-store-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("workspace.json")
        let store = try WorkspaceStore(fileURL: url)

        #expect(!FileManager.default.fileExists(atPath: dir.path))

        try store.save(Workspace.empty())

        #expect(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func saveOverwritesExistingFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-store-\(UUID().uuidString)")
            .appendingPathComponent("workspace.json")
        let store = try WorkspaceStore(fileURL: tmp)

        try store.save(Workspace.empty())

        var second = Workspace.empty()
        second.windows[0].sessions[0].title = "frontend"
        try store.save(second)

        let data = try Data(contentsOf: tmp)
        let decoded = try Workspace.decoder.decode(Workspace.self, from: data)
        #expect(decoded.windows[0].sessions[0].title == "frontend")

        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    }

    @Test func canonicalFileURLPointsAtApplicationSupportBatty() throws {
        let url = try WorkspaceStore.canonicalFileURL()
        #expect(url.lastPathComponent == "workspace.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Batty")
    }

    @Test func loadReturnsMissingWhenFileAbsent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-store-\(UUID().uuidString)")
            .appendingPathComponent("workspace.json")
        let store = try WorkspaceStore(fileURL: url)

        switch store.load() {
        case .missing:
            break
        default:
            Issue.record("expected .missing for absent file")
        }
    }

    @Test func loadReturnsLoadedAfterSave() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-store-\(UUID().uuidString)")
            .appendingPathComponent("workspace.json")
        let store = try WorkspaceStore(fileURL: url)

        var workspace = Workspace.empty()
        workspace.windows[0].sessions[0].title = "frontend"
        try store.save(workspace)

        switch store.load() {
        case .loaded(let w):
            #expect(w == workspace)
        default:
            Issue.record("expected .loaded after save")
        }

        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func loadRecoversFromCorruptFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-store-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not valid json {{{".utf8).write(to: url)

        let store = try WorkspaceStore(fileURL: url)
        let result = store.load()

        switch result {
        case .recovered(let defaultWorkspace, let brokenURL, _):
            #expect(defaultWorkspace.windows.count == 1)
            #expect(defaultWorkspace.windows[0].sessions.count == 1)
            #expect(defaultWorkspace.bellFeed.isEmpty)
            #expect(brokenURL.path != url.path)
            #expect(brokenURL.lastPathComponent.contains("broken-"))
            #expect(FileManager.default.fileExists(atPath: brokenURL.path))
            #expect(!FileManager.default.fileExists(atPath: url.path))
        default:
            Issue.record("expected .recovered for corrupt file")
        }

        try? FileManager.default.removeItem(at: dir)
    }

    @Test func loadResultWorkspaceFallsBackToEmptyForMissing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-store-\(UUID().uuidString)")
            .appendingPathComponent("workspace.json")
        let store = try WorkspaceStore(fileURL: url)
        let result = store.load()
        let workspace = result.workspace
        #expect(workspace.windows.count == 1)
        #expect(workspace.windows[0].sessions.count == 1)
        #expect(workspace.windows[0].sessions[0].root.firstPane.tabs.count == 1)
        #expect(workspace.bellFeed.isEmpty)
        #expect(workspace.schemaVersion == Workspace.currentSchemaVersion)
    }
}
