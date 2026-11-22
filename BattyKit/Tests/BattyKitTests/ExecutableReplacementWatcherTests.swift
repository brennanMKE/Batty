// ExecutableReplacementWatcherTests.swift

import BattyXPCCore
import Darwin
import Foundation
import Testing

/// Collects watcher callbacks and lets a test await the first one. The
/// timeout only guards against a regression that never calls back.
private nonisolated final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [UInt] = []
    private var waiter: CheckedContinuation<UInt?, Never>?

    var count: Int { lock.withLock { events.count } }

    func record(_ event: DispatchSource.FileSystemEvent) {
        let w: CheckedContinuation<UInt?, Never>? = lock.withLock {
            events.append(event.rawValue)
            let w = waiter
            waiter = nil
            return w
        }
        w?.resume(returning: event.rawValue)
    }

    func first() async -> DispatchSource.FileSystemEvent? {
        let raw = await withCheckedContinuation { (c: CheckedContinuation<UInt?, Never>) in
            let existing: UInt? = lock.withLock {
                if let e = events.first { return e }
                waiter = c
                return nil
            }
            if let existing {
                c.resume(returning: existing)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + TestBounds.hangGuard) { [self] in
                let w: CheckedContinuation<UInt?, Never>? = lock.withLock {
                    let w = waiter
                    waiter = nil
                    return w
                }
                w?.resume(returning: nil)
            }
        }
        return raw.map { DispatchSource.FileSystemEvent(rawValue: $0) }
    }
}

private nonisolated final class FakeEventSource: FileEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (DispatchSource.FileSystemEvent) -> Void)?
    private(set) var cancelCount = 0

    func start(handler: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void) throws {
        lock.withLock { self.handler = handler }
    }

    func cancel() {
        lock.withLock { cancelCount += 1 }
    }

    func send(_ event: DispatchSource.FileSystemEvent) {
        let h = lock.withLock { handler }
        h?(event)
    }
}

@Suite nonisolated struct ExecutableReplacementWatcherTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecutableReplacementWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func makeFile(_ relative: String, contents: String = "v1") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func watch(_ url: URL, _ recorder: EventRecorder) throws -> ExecutableReplacementWatcher {
        let watcher = ExecutableReplacementWatcher(
            path: url.path, queue: DispatchQueue(label: "ExecutableReplacementWatcherTests")
        ) { recorder.record($0) }
        try watcher.start()
        return watcher
    }

    @Test func deletingTheFileFiresDelete() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile("bin/x")
        let recorder = EventRecorder()
        let watcher = try watch(file, recorder)
        #expect(unlink(file.path) == 0)
        let event = await recorder.first()
        #expect(event?.contains(.delete) == true)
        #expect(watcher.isCancelled)
    }

    @Test func sparkleStyleBundleSwapFires() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try makeFile("A.app/bin/x", contents: "old")
        _ = try makeFile("B.app/bin/x", contents: "new")
        let recorder = EventRecorder()
        let watcher = try watch(old, recorder)
        let a = root.appendingPathComponent("A.app").path
        let b = root.appendingPathComponent("B.app").path
        #expect(renamex_np(a, b, UInt32(RENAME_SWAP)) == 0)
        try FileManager.default.removeItem(atPath: b)
        let event = await recorder.first()
        #expect(event != nil)
        #expect(watcher.isCancelled)
        #expect(try String(contentsOfFile: root.appendingPathComponent("A.app/bin/x").path, encoding: .utf8) == "new")
    }

    @Test func overwritingTheFileFiresWrite() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile("bin/x")
        let recorder = EventRecorder()
        let watcher = try watch(file, recorder)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("v2".utf8))
        try handle.close()
        let event = await recorder.first()
        #expect(event?.contains(.write) == true)
        _ = watcher
    }

    @Test func renamingTheFileFires() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile("bin/x")
        let recorder = EventRecorder()
        let watcher = try watch(file, recorder)
        #expect(rename(file.path, root.appendingPathComponent("bin/y").path) == 0)
        let event = await recorder.first()
        #expect(event?.contains(.rename) == true)
        _ = watcher
    }

    @Test func firesOnlyOnceAndCancelsTheSource() throws {
        let source = FakeEventSource()
        let recorder = EventRecorder()
        let watcher = ExecutableReplacementWatcher(path: "/x", source: source) { recorder.record($0) }
        try watcher.start()
        #expect(!watcher.isCancelled)
        source.send(.delete)
        #expect(recorder.count == 1)
        #expect(watcher.isCancelled)
        #expect(source.cancelCount == 1)
        source.send(.write)
        #expect(recorder.count == 1)
    }

    @Test func cancelledWatcherNeverCallsBack() throws {
        let source = FakeEventSource()
        let recorder = EventRecorder()
        let watcher = ExecutableReplacementWatcher(path: "/x", source: source) { recorder.record($0) }
        try watcher.start()
        watcher.cancel()
        source.send(.delete)
        #expect(recorder.count == 0)
        #expect(watcher.isCancelled)
    }

    @Test func startThrowsForAMissingPath() {
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = ExecutableReplacementWatcher(
            path: root.appendingPathComponent("missing").path, queue: DispatchQueue(label: "t")
        ) { _ in }
        #expect(throws: POSIXError.self) { try watcher.start() }
    }

    @Test func eventMaskCoversReplacement() {
        let mask = ExecutableReplacementWatcher.eventMask
        #expect(mask.contains(.delete))
        #expect(mask.contains(.rename))
        #expect(mask.contains(.revoke))
        #expect(mask.contains(.write))
    }

    @Test func ownExecutablePathIsAbsoluteAndExists() throws {
        let path = try #require(ExecutableReplacementWatcher.ownExecutablePath())
        #expect(path.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: path))
    }
}
