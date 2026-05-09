// SurfaceRegistry.swift

import Foundation
import GhosttyKit

public final class SurfaceRegistry {

    private var handles: [UUID: ghostty_surface_t] = [:]

    public init() {}

    @discardableResult
    public func register(_ surface: ghostty_surface_t) -> UUID {
        let id = UUID()
        handles[id] = surface
        return id
    }

    public func surface(for id: UUID) -> ghostty_surface_t? {
        handles[id]
    }

    public func contains(_ id: UUID) -> Bool {
        handles[id] != nil
    }

    @discardableResult
    public func unregister(_ id: UUID) -> ghostty_surface_t? {
        handles.removeValue(forKey: id)
    }

    public var count: Int { handles.count }

    public var ids: Set<UUID> { Set(handles.keys) }
}
