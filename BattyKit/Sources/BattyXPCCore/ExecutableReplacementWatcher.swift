// ExecutableReplacementWatcher.swift

import Darwin
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ExecutableReplacementWatcher")

/// A source of file-system events for one file. `VnodeFileEventSource` is the
/// production implementation; tests inject their own to deliver events
/// directly.
public nonisolated protocol FileEventSource: AnyObject, Sendable {
    /// Starts delivering events to `handler`. Throws if the file can't be
    /// watched (for example, it doesn't exist).
    func start(handler: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void) throws
    /// Stops delivering events and releases the watch. Idempotent.
    func cancel()
}

/// Calls back once when a process's executable file is replaced on disk, so a
/// long-lived helper (the broker, BattyHost) can react to an app update before
/// clients reject it: the outgoing code-signing check (#0278) fails with
/// -67065 (`errSecCSNoSuchCode`) for a process whose code is gone from disk.
///
/// Usage:
/// ```swift
/// guard let path = ExecutableReplacementWatcher.ownExecutablePath() else { ... }
/// let watcher = ExecutableReplacementWatcher(path: path, queue: queue) { event in ... }
/// try watcher.start()
/// ```
/// Keep a strong reference for as long as the watch should last.
///
/// - The callback runs at most once, on the source's queue, for the first of
///   `eventMask` (delete, rename, revoke, write). The watch is then cancelled;
///   `isCancelled` reports it.
/// - Sparkle's update swaps the bundle and deletes the old one, which unlinks
///   the executable (`.delete`), whether or not it is mapped. An in-place
///   overwrite is `.write`, renaming the file itself is `.rename`, an
///   unmounted volume is `.revoke`.
/// - Renaming or moving an *ancestor* directory (the whole bundle) fires
///   nothing. That is intended: the file and its code are unchanged, so the
///   code-signing check still passes and nothing needs to restart.
/// - No debounce and no validity check: callers that need them (an in-place
///   restart) add them on top.
public nonisolated final class ExecutableReplacementWatcher: @unchecked Sendable {
    public static var eventMask: DispatchSource.FileSystemEvent { [.delete, .rename, .revoke, .write] }

    /// The absolute path of the running process's executable, from
    /// `proc_pidpath`. `CommandLine.arguments[0]` is not used: launchd's
    /// `BundleProgram` makes it relative to the bundle.
    public static func ownExecutablePath() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public let path: String
    private let source: FileEventSource
    private let onReplaced: @Sendable (DispatchSource.FileSystemEvent) -> Void
    private let lock = NSLock()
    private var fired = false
    private var cancelled = false

    /// Watches `path` with a vnode dispatch source whose handlers run on `queue`.
    public convenience init(
        path: String,
        queue: DispatchQueue,
        onReplaced: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void
    ) {
        self.init(path: path, source: VnodeFileEventSource(path: path, queue: queue), onReplaced: onReplaced)
    }

    /// Watches through an injected event source (tests).
    public init(
        path: String,
        source: FileEventSource,
        onReplaced: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void
    ) {
        self.path = path
        self.source = source
        self.onReplaced = onReplaced
    }

    deinit {
        source.cancel()
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    /// Starts the watch. Throws the source's error (a `POSIXError` for the
    /// vnode source) when the file can't be opened.
    public func start() throws {
        try source.start { [weak self] event in
            self?.handle(event)
        }
        logger.info("watching \(self.path, privacy: .public)")
    }

    public func cancel() {
        lock.withLock { cancelled = true }
        source.cancel()
    }

    private func handle(_ event: DispatchSource.FileSystemEvent) {
        let first: Bool = lock.withLock {
            guard !fired, !cancelled else { return false }
            fired = true
            cancelled = true
            return true
        }
        guard first else { return }
        source.cancel()
        logger.notice("executable replaced (\(Self.describe(event), privacy: .public)): \(self.path, privacy: .public)")
        onReplaced(event)
    }

    public static func describe(_ event: DispatchSource.FileSystemEvent) -> String {
        var names: [String] = []
        if event.contains(.delete) { names.append("delete") }
        if event.contains(.rename) { names.append("rename") }
        if event.contains(.revoke) { names.append("revoke") }
        if event.contains(.write) { names.append("write") }
        return names.isEmpty ? "0x\(String(event.rawValue, radix: 16))" : names.joined(separator: ",")
    }
}

/// A `DispatchSourceFileSystemObject` on a file opened `O_EVTONLY`, masked to
/// `ExecutableReplacementWatcher.eventMask`.
public nonisolated final class VnodeFileEventSource: FileEventSource, @unchecked Sendable {
    private let path: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var dispatchSource: DispatchSourceFileSystemObject?

    public init(path: String, queue: DispatchQueue) {
        self.path = path
        self.queue = queue
    }

    public func start(handler: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void) throws {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: ExecutableReplacementWatcher.eventMask, queue: queue)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            handler(source.data)
        }
        source.setCancelHandler { close(fd) }
        let previous: DispatchSourceFileSystemObject? = lock.withLock {
            let old = dispatchSource
            dispatchSource = source
            return old
        }
        previous?.cancel()
        source.resume()
    }

    public func cancel() {
        let source: DispatchSourceFileSystemObject? = lock.withLock {
            let s = dispatchSource
            dispatchSource = nil
            return s
        }
        source?.cancel()
    }
}
