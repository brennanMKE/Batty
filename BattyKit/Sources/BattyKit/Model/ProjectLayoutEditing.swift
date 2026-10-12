// ProjectLayoutEditing.swift

import CoreGraphics
import Foundation

extension ProjectLayoutNode {
    /// Rebuilds the node with each `.pane` leaf replaced by
    /// `transform(slot, pane)`, visiting leaves in slot order. The split
    /// structure is untouched.
    func mappingPanes(_ transform: (Int, ProjectPane) -> ProjectPane) -> ProjectLayoutNode {
        var slot = 0
        func walk(_ node: ProjectLayoutNode) -> ProjectLayoutNode {
            switch node {
            case .pane(let pane):
                defer { slot += 1 }
                return .pane(transform(slot, pane))
            case .split(let direction, let children):
                return .split(direction: direction, children: children.map(walk))
            }
        }
        return walk(self)
    }

    /// The same split structure with `panes[i]` in slot `i`. A short list
    /// leaves the remaining slots as they were.
    func withPanes(_ panes: [ProjectPane]) -> ProjectLayoutNode {
        mappingPanes { slot, existing in slot < panes.count ? panes[slot] : existing }
    }

    /// Each slot's frame inside the unit square, top-left origin, in slot
    /// order. Siblings of a split share its extent equally, which is the
    /// shape Panes open in (#0255 equalization); sizes are never stored.
    var slotFrames: [CGRect] {
        var frames: [CGRect] = []
        func walk(_ node: ProjectLayoutNode, in rect: CGRect) {
            switch node {
            case .pane:
                frames.append(rect)
            case .split(let direction, let children):
                let count = CGFloat(children.count)
                for (index, child) in children.enumerated() {
                    let i = CGFloat(index)
                    switch direction {
                    case .horizontal:
                        walk(child, in: CGRect(x: rect.minX + rect.width * i / count, y: rect.minY, width: rect.width / count, height: rect.height))
                    case .vertical:
                        walk(child, in: CGRect(x: rect.minX, y: rect.minY + rect.height * i / count, width: rect.width, height: rect.height / count))
                    }
                }
            }
        }
        walk(self, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return frames
    }
}

extension ProjectLayout {
    var slotFrames: [CGRect] { root.slotFrames }

    /// Thumbnail geometry for a topology that has no `PaneLayout` preset
    /// behind it. Slot 0 is the primary tint, as in the preset thumbnails.
    var thumbnailPanes: [PaneLayout.LayoutPane] {
        slotFrames.enumerated().map { PaneLayout.LayoutPane(frame: $1, isPrimary: $0 == 0) }
    }
}

enum ProjectPaneDirection: Sendable, Equatable {
    case left, right, up, down
}

enum ProjectLayoutGeometry {
    private static let epsilon: CGFloat = 0.0001

    /// The slot reached by an arrow key: the nearest frame beyond `slot` on
    /// that axis whose extent overlaps it on the other axis. Nil at an edge.
    static func neighbor(of slot: Int, in frames: [CGRect], toward direction: ProjectPaneDirection) -> Int? {
        guard frames.indices.contains(slot) else { return nil }
        let current = frames[slot]
        var best: (index: Int, gap: CGFloat, offset: CGFloat)?
        for (index, candidate) in frames.enumerated() where index != slot {
            let gap: CGFloat
            let overlap: CGFloat
            let offset: CGFloat
            switch direction {
            case .right:
                gap = candidate.minX - current.maxX
                overlap = min(candidate.maxY, current.maxY) - max(candidate.minY, current.minY)
                offset = abs(candidate.midY - current.midY)
            case .left:
                gap = current.minX - candidate.maxX
                overlap = min(candidate.maxY, current.maxY) - max(candidate.minY, current.minY)
                offset = abs(candidate.midY - current.midY)
            case .down:
                gap = candidate.minY - current.maxY
                overlap = min(candidate.maxX, current.maxX) - max(candidate.minX, current.minX)
                offset = abs(candidate.midX - current.midX)
            case .up:
                gap = current.minY - candidate.maxY
                overlap = min(candidate.maxX, current.maxX) - max(candidate.minX, current.minX)
                offset = abs(candidate.midX - current.midX)
            }
            guard gap > -epsilon, overlap > epsilon else { continue }
            if let b = best {
                if gap < b.gap - epsilon || (abs(gap - b.gap) <= epsilon && offset < b.offset) {
                    best = (index, gap, offset)
                }
            } else {
                best = (index, gap, offset)
            }
        }
        return best?.index
    }

    /// "Top", "Bottom left", "Middle", "Whole window": where a Pane sits,
    /// for the inspector's subtitle.
    static func positionDescription(of frame: CGRect) -> String {
        let fullWidth = frame.width > 1 - epsilon
        let fullHeight = frame.height > 1 - epsilon
        if fullWidth && fullHeight {
            return String(localized: "Whole window", comment: "Project Editor: a Pane that fills the window")
        }
        let vertical: String? = {
            guard !fullHeight else { return nil }
            if frame.midY < 1.0 / 3.0 { return String(localized: "Top", comment: "Project Editor: Pane position") }
            if frame.midY > 2.0 / 3.0 { return String(localized: "Bottom", comment: "Project Editor: Pane position") }
            return String(localized: "Middle", comment: "Project Editor: Pane position")
        }()
        let horizontal: String? = {
            guard !fullWidth else { return nil }
            if frame.midX < 1.0 / 3.0 { return String(localized: "left", comment: "Project Editor: Pane position, lowercase after Top/Bottom") }
            if frame.midX > 2.0 / 3.0 { return String(localized: "right", comment: "Project Editor: Pane position, lowercase after Top/Bottom") }
            return String(localized: "middle", comment: "Project Editor: Pane position, lowercase after Top/Bottom")
        }()
        switch (vertical, horizontal) {
        case let (v?, h?):
            return String(localized: "\(v) \(h)", comment: "Project Editor: Pane position, vertical part then horizontal part, such as Top left")
        case let (v?, nil):
            return v
        case let (nil, h?):
            return h.prefix(1).uppercased() + h.dropFirst()
        case (nil, nil):
            return ""
        }
    }
}
