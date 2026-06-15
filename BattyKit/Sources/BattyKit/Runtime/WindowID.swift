// WindowID.swift

import Foundation

/// Stable identity for a content window. Wraps a UUID so the presented-value
/// namespace for `WindowGroup(for: WindowID.self)` cannot collide with other
/// `openWindow(value:)` call sites that present plain UUIDs.
public struct WindowID: Codable, Hashable, Sendable {
    public let value: UUID

    public init(_ value: UUID = UUID()) {
        self.value = value
    }
}
