// ServerRegistry.swift

import Foundation
import Observation

/// Every server Batty tracks, app-wide: the toolbar's Servers list reads it
/// and the `server` CLI verbs write it. An entry ticks from `register` until
/// it stops or crashes, then leaves.
@MainActor
@Observable
public final class ServerRegistry {
    /// In registration order.
    public private(set) var entries: [ServerEntry] = []

    public init() {}

    public var activeEntries: [ServerEntry] {
        entries.filter { $0.state.isRunning }
    }

    public func entry(id: UUID) -> ServerEntry? {
        entries.first { $0.id == id }
    }

    /// Only one process can listen on a loopback port, so a port names at
    /// most one entry.
    public func entry(port: UInt16) -> ServerEntry? {
        entries.first { $0.port == port }
    }

    /// The in-app static server serving `rootRealPath`.
    public func entry(root rootRealPath: String) -> ServerEntry? {
        entries.first { ($0.backend as? InAppStaticServerBackend)?.root == rootRealPath }
    }

    public func register(_ entry: ServerEntry) {
        guard self.entry(id: entry.id) == nil else { return }
        entry.onFinished = { [weak self] finished in self?.remove(id: finished.id) }
        entries.append(entry)
        entry.setUp(visible: true)
    }

    public func remove(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        entry.onFinished = nil
        entry.tearDown()
    }
}
