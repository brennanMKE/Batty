// ProjectSymbolListCursor.swift

import Foundation

/// Cursor arithmetic for the filterable symbol list: a flat list laid out in
/// `columns` columns. Moves clamp at the edges and never wrap; a move down
/// from the last, partial row lands on the final entry.
struct ProjectSymbolListCursor: Equatable {
    static let columns = 9

    enum Direction: CaseIterable {
        case left, right, up, down
    }

    let index: Int
    let count: Int

    init(_ index: Int, count: Int) {
        self.count = max(count, 0)
        self.index = self.count == 0 ? 0 : min(max(index, 0), self.count - 1)
    }

    func moved(_ direction: Direction) -> ProjectSymbolListCursor {
        guard count > 0 else { return self }
        var next = index
        switch direction {
        case .left: if index % Self.columns > 0 { next -= 1 }
        case .right: if index % Self.columns < Self.columns - 1, index + 1 < count { next += 1 }
        case .up: if index >= Self.columns { next -= Self.columns }
        case .down:
            if index + Self.columns < count {
                next += Self.columns
            } else if index / Self.columns < (count - 1) / Self.columns {
                next = count - 1
            }
        }
        return ProjectSymbolListCursor(next, count: count)
    }
}
