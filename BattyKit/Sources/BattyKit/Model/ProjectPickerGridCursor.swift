// ProjectPickerGridCursor.swift

import Foundation

/// Cursor arithmetic for the Open Project picker: an ordered list of
/// sections, each a grid of `columns` columns holding `count` cards, indexed
/// by one flat position in reading order. Moves clamp at the first and last
/// card and never wrap.
struct ProjectPickerGridCursor: Equatable {
    struct Section: Equatable {
        let columns: Int
        let count: Int
    }

    let sections: [Section]

    init(sections: [Section]) {
        self.sections = sections.filter { $0.columns > 0 && $0.count > 0 }
    }

    var total: Int { sections.reduce(0) { $0 + $1.count } }

    /// The column of a section with `columns` columns whose horizontal centre
    /// is nearest the centre of column `column` in a section with
    /// `fromColumns` columns.
    static func mappedColumn(_ column: Int, from fromColumns: Int, to columns: Int) -> Int {
        ((2 * column + 1) * columns) / (2 * fromColumns)
    }

    func moved(from index: Int, _ direction: ProjectPickerDirection) -> Int {
        let total = total
        guard total > 0 else { return index }
        let current = min(max(index, 0), total - 1)
        switch direction {
        case .left: return max(current - 1, 0)
        case .right: return min(current + 1, total - 1)
        case .home: return 0
        case .end: return total - 1
        case .up: return vertical(from: current, step: -1)
        case .down: return vertical(from: current, step: 1)
        }
    }

    private func vertical(from index: Int, step: Int) -> Int {
        var start = 0
        for (position, section) in sections.enumerated() {
            guard index < start + section.count else {
                start += section.count
                continue
            }
            let local = index - start
            let row = local / section.columns
            let column = local % section.columns
            let rows = (section.count + section.columns - 1) / section.columns
            let targetRow = row + step
            if (0..<rows).contains(targetRow) {
                return start + min(targetRow * section.columns + column, section.count - 1)
            }
            let neighbour = position + step
            guard sections.indices.contains(neighbour) else { return index }
            let other = sections[neighbour]
            let otherStart = step > 0 ? start + section.count : start - other.count
            let mapped = Self.mappedColumn(column, from: section.columns, to: other.columns)
            let otherRow = step > 0 ? 0 : (other.count - 1) / other.columns
            let cardsInRow = min(other.columns, other.count - otherRow * other.columns)
            return otherStart + otherRow * other.columns + min(mapped, cardsInRow - 1)
        }
        return index
    }
}
