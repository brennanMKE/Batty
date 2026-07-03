// LayoutModel.swift

import Foundation

public enum SplitDirection: String, Codable, Sendable, Hashable {
    case horizontal
    case vertical
}

/// Codable snapshot of a single pane's layout-relevant state.
/// Mirrors `PaneRuntime` fields that must survive workspace persistence.
/// The split-tree structure itself is captured at the `SplitTree` level;
/// this type carries only the per-leaf properties that are not
/// reconstructed from the runtime on every launch.
public struct Pane: Codable, Sendable, Hashable {
    public var id: UUID
    public var isHidden: Bool

    public init(id: UUID = UUID(), isHidden: Bool = false) {
        self.id = id
        self.isHidden = isHidden
    }
}
