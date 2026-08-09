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
    public var kind: PaneContentKind

    public init(id: UUID = UUID(), isHidden: Bool = false, kind: PaneContentKind = .terminal) {
        self.id = id
        self.isHidden = isHidden
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, isHidden, kind
    }

    /// `kind` decodes leniently — absent because a snapshot predates this
    /// field, or because a future producer doesn't know about non-terminal
    /// kinds yet — as `.terminal`, the only kind that existed before this
    /// field did (`docs/pane-kinds.md` §4). `id`/`isHidden` still decode
    /// strictly; only the newly-added field needs tolerance.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        isHidden = try container.decode(Bool.self, forKey: .isHidden)
        kind = try container.decodeIfPresent(PaneContentKind.self, forKey: .kind) ?? .terminal
    }
    // Synthesized encode(to:) is fine — Codable's default memberwise
    // encoding always writes `kind`, so only decoding an old/absent field
    // needs the custom initializer above.
}
