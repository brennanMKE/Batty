// DirectoryChangeWatcher.swift

import CoreServices
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "DirectoryChangeWatcher")

public nonisolated protocol DirectoryChangeWatching: AnyObject, Sendable {
    func start(onChange: @escaping @Sendable ([String]) -> Void)
    func stop()
}

public nonisolated enum StaticChangeFilter {
    /// A change counts when it is under the root and no path component below
    /// the root starts with a dot (`.git/`, editor swap files).
    public static func isRelevant(path: String, root: String) -> Bool {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard trimmed == root || trimmed.hasPrefix(root + "/") else { return false }
        return !trimmed.dropFirst(root.count).split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

/// FSEvents on one root, delivered on the watcher's own queue (never the
/// main queue). `root` should be a `realpath`, since FSEvents reports real
/// paths.
public nonisolated final class FSEventsDirectoryWatcher: DirectoryChangeWatching, @unchecked Sendable {
    private let root: String
    private let queue = DispatchQueue(label: "co.sstools.Batty.DirectoryChangeWatcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var onChange: (@Sendable ([String]) -> Void)?

    public init(root: String) {
        self.root = root
    }

    public func start(onChange: @escaping @Sendable ([String]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FSEventsDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let array = unsafeBitCast(paths, to: NSArray.self)
                let list = (0..<count).compactMap { array[$0] as? String }
                watcher.deliver(list)
            },
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            flags
        ) else {
            logger.error("FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        lock.lock()
        let current = stream
        stream = nil
        onChange = nil
        lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }

    private func deliver(_ paths: [String]) {
        lock.lock()
        let handler = onChange
        lock.unlock()
        let relevant = paths.filter { StaticChangeFilter.isRelevant(path: $0, root: root) }
        if !relevant.isEmpty { handler?(relevant) }
    }

    deinit {
        stop()
    }
}
