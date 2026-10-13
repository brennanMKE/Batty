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
