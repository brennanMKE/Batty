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
}
