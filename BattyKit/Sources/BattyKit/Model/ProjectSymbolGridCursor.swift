// ProjectSymbolGridCursor.swift

import Foundation

/// Cursor arithmetic for the Project Editor's symbol grid: 36 symbols in
/// 6 columns by 6 rows, in catalog order. Moves clamp at every edge and
/// never wrap, and a vertical move keeps the column while a horizontal move
/// keeps the row.
struct ProjectSymbolGridCursor: Equatable {
    static let columns = 6
    static var count: Int { ProjectSymbol.allCases.count }
    static var rows: Int { (count + columns - 1) / columns }

    enum Direction: CaseIterable {
        case left, right, up, down
    }

    let index: Int

    init(_ index: Int) {
        self.index = min(max(index, 0), Self.count - 1)
    }

    init(_ symbol: ProjectSymbol) {
        self.init(ProjectSymbol.allCases.firstIndex(of: symbol) ?? 0)
    }

    var symbol: ProjectSymbol { ProjectSymbol.allCases[index] }

    func moved(_ direction: Direction) -> ProjectSymbolGridCursor {
        let row = index / Self.columns
        let column = index % Self.columns
        var newRow = row
        var newColumn = column
        switch direction {
        case .left: newColumn -= 1
        case .right: newColumn += 1
        case .up: newRow -= 1
        case .down: newRow += 1
        }
        guard (0..<Self.columns).contains(newColumn), (0..<Self.rows).contains(newRow) else { return self }
        let candidate = newRow * Self.columns + newColumn
        guard candidate < Self.count else { return self }
        return ProjectSymbolGridCursor(candidate)
    }
}

/// Cursor arithmetic for the filterable symbol list: a flat list laid out in
/// `columns` columns. Moves clamp at the edges and never wrap; a move down
/// from the last, partial row lands on the final entry.
struct ProjectSymbolListCursor: Equatable {
    static let columns = 9

    let index: Int
    let count: Int

    init(_ index: Int, count: Int) {
        self.count = max(count, 0)
        self.index = self.count == 0 ? 0 : min(max(index, 0), self.count - 1)
    }

    func moved(_ direction: ProjectSymbolGridCursor.Direction) -> ProjectSymbolListCursor {
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
