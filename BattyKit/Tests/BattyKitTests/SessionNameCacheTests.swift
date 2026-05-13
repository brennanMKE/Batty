// SessionNameCacheTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct SessionNameCacheTests {

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-name-cache-\(UUID().uuidString)")
            .appendingPathComponent("session-name-cache.json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func lookupReturnsNilForEmptyCache() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let cache = SessionNameCache(fileURL: url, debounce: .zero)
        #expect(cache.lookup(path: "/Users/test/Developer/Batty") == nil)
    }

    @Test func lookupReturnsNilForEmptyPath() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let cache = SessionNameCache(fileURL: url, debounce: .zero)
        cache.record(path: "/Users/test/Developer/Batty", name: "Batty")
        #expect(cache.lookup(path: "") == nil)
    }

    @Test func recordThenLookupRoundTripsName() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let cache = SessionNameCache(fileURL: url, debounce: .zero)
        cache.record(path: "/Users/test/Developer/Batty", name: "Batty")
        #expect(cache.lookup(path: "/Users/test/Developer/Batty") == "Batty")
    }

    @Test func recordIgnoresEmptyName() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let cache = SessionNameCache(fileURL: url, debounce: .zero)
        cache.record(path: "/Users/test/Developer/Batty", name: "")
        cache.record(path: "/Users/test/Developer/Batty", name: "   ")
        #expect(cache.lookup(path: "/Users/test/Developer/Batty") == nil)
    }

    @Test func recordIgnoresEmptyPath() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let cache = SessionNameCache(fileURL: url, debounce: .zero)
        cache.record(path: "", name: "Batty")
        #expect(cache.snapshot().isEmpty)
    }

    @Test func recordTrimsName() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let cache = SessionNameCache(fileURL: url, debounce: .zero)
        cache.record(path: "/p", name: "  Batty  ")
        #expect(cache.lookup(path: "/p") == "Batty")
    }

    @Test func savePersistsToDiskForFreshInstance() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let cache = SessionNameCache(fileURL: url, debounce: .zero)
        cache.record(path: "/Users/test/Developer/Batty", name: "Batty")
        cache.save()

        #expect(FileManager.default.fileExists(atPath: url.path))

        let reloaded = SessionNameCache(fileURL: url, debounce: .zero)
        #expect(reloaded.lookup(path: "/Users/test/Developer/Batty") == "Batty")
    }

    @Test func lruEvictsOldestWhenInsertingPastCap() {
        let url = makeTempURL()
        defer { cleanup(url) }
        var ticks: TimeInterval = 0
        let clock: () -> Date = {
            ticks += 1
            return Date(timeIntervalSince1970: ticks)
        }
        let cache = SessionNameCache(fileURL: url, debounce: .zero, clock: clock)

        for i in 0..<100 {
            cache.record(path: "/path/\(i)", name: "name-\(i)")
        }
        #expect(cache.entryCount == 100)
        #expect(cache.lookup(path: "/path/0") == "name-0")

        cache.record(path: "/path/100", name: "name-100")

        #expect(cache.entryCount == 100)
        #expect(cache.lookup(path: "/path/100") == "name-100")
    }

    @Test func lruEvictsEntryWithOldestLastUsedAt() {
        let url = makeTempURL()
        defer { cleanup(url) }
        var ticks: TimeInterval = 0
        let clock: () -> Date = {
            ticks += 1
            return Date(timeIntervalSince1970: ticks)
        }
        let cache = SessionNameCache(fileURL: url, debounce: .zero, clock: clock)

        cache.record(path: "/a", name: "a")
        cache.record(path: "/b", name: "b")
        for i in 0..<98 {
            cache.record(path: "/path/\(i)", name: "name-\(i)")
        }
        #expect(cache.entryCount == 100)

        _ = cache.lookup(path: "/a")

        cache.record(path: "/new", name: "new")

        #expect(cache.entryCount == 100)
        #expect(cache.lookup(path: "/a") == "a")
        #expect(cache.lookup(path: "/b") == nil)
        #expect(cache.lookup(path: "/new") == "new")
    }

    @Test func corruptFileRecoversToEmptySilently() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("not valid json {{{".utf8).write(to: url)

        let cache = SessionNameCache(fileURL: url, debounce: .zero)

        #expect(cache.entryCount == 0)
        #expect(cache.lookup(path: "/anywhere") == nil)

        cache.record(path: "/p", name: "n")
        cache.save()
        #expect(FileManager.default.fileExists(atPath: url.path))

        let reloaded = SessionNameCache(fileURL: url, debounce: .zero)
        #expect(reloaded.lookup(path: "/p") == "n")
    }

    @Test func missingFileTreatedAsEmpty() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let cache = SessionNameCache(fileURL: url, debounce: .zero)
        #expect(cache.entryCount == 0)
    }

    @Test func renameOfDefaultNamedSessionStillWritesCacheForNonDefaultNewTitle() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let cache = SessionNameCache(fileURL: url, debounce: .zero)
        let store = AppStateStore(nameCache: cache)
        let session = store.sessions[0]
        session.tree.root.firstLeafPane.tabs[0].terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"

        store.renameSession(id: session.id, to: "Batty")

        #expect(cache.lookup(path: "/Users/test/Developer/Batty") == "Batty")
    }

    @Test func renameToDefaultNameDoesNotWriteCache() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let cache = SessionNameCache(fileURL: url, debounce: .zero)
        let store = AppStateStore(nameCache: cache)
        let session = store.sessions[0]
        session.tree.root.firstLeafPane.tabs[0].terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"

        store.renameSession(id: session.id, to: "Session 7")

        #expect(cache.lookup(path: "/Users/test/Developer/Batty") == nil)
    }

    @Test func renameWithEmptyCWDDoesNotWriteCache() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let cache = SessionNameCache(fileURL: url, debounce: .zero)
        let store = AppStateStore(nameCache: cache)
        let session = store.sessions[0]

        store.renameSession(id: session.id, to: "Batty")

        #expect(cache.snapshot().isEmpty)
    }

    @Test func addSessionAppliesCachedNameOnCWDHit() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let cache = SessionNameCache(fileURL: url, debounce: .zero)
        cache.record(path: "/Users/test/Developer/Batty", name: "Batty")
        let store = AppStateStore(nameCache: cache)
        let source = store.sessions[0]
        source.focusedPane.activeTab?.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"

        let created = store.addSession()

        #expect(created.title == "Batty")
    }

    @Test func addSessionUsesDefaultTitleOnCacheMiss() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let cache = SessionNameCache(fileURL: url, debounce: .zero)
        let store = AppStateStore(nameCache: cache)
        let source = store.sessions[0]
        source.focusedPane.activeTab?.terminal.configuration.workingDirectory = "/Users/test/Unknown"

        let created = store.addSession()

        #expect(created.title == "Session 2")
    }

    @Test func addSessionRespectsExplicitTitleOverCache() {
        let url = makeTempURL()
        defer { cleanup(url) }
        let cache = SessionNameCache(fileURL: url, debounce: .zero)
        cache.record(path: "/Users/test/Developer/Batty", name: "Batty")
        let store = AppStateStore(nameCache: cache)
        let source = store.sessions[0]
        source.focusedPane.activeTab?.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"

        let created = store.addSession(title: "Custom")

        #expect(created.title == "Custom")
    }

    @Test func isDefaultSessionTitleRecognizesPatterns() {
        #expect(AppStateStore.isDefaultSessionTitle("Session 1"))
        #expect(AppStateStore.isDefaultSessionTitle("Session 42"))
        #expect(!AppStateStore.isDefaultSessionTitle("Batty"))
        #expect(!AppStateStore.isDefaultSessionTitle("Session"))
        #expect(!AppStateStore.isDefaultSessionTitle("session 1"))
        #expect(!AppStateStore.isDefaultSessionTitle("Session 1 Copy"))
    }
}
