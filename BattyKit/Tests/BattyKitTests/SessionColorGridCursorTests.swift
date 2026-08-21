// SessionColorGridCursorTests.swift

import Foundation
import Testing
@testable import BattyKit

private enum Direction: Sendable {
    case left, right, up, down
}

private struct Transition: Sendable {
    let start: SessionColorGridCursor.Position
    let direction: Direction
    let expected: SessionColorGridCursor.Position
}

/// Table-driven coverage for `SessionColorGridCursor`, the value type
/// `SessionColorPickerView` lifted its arrow-key math into during #0336
/// review round 2. All 44 transitions across the 10 swatches (5 columns ×
/// 2 rows) plus "Automatic" — every direction from every position. This
/// table encodes exactly the behavior the round-2 reviewer hand-verified;
/// it is written to fail against the round-1 shape (modulo-11 arithmetic
/// over a 5-wide grid), where e.g. Down from index 9 landed on index 3
/// instead of `.automatic` — see `downFromLastSwatchRowGoesToAutomatic`
/// below for the direct regression check.
private struct SessionColorGridCursorTests {

    private nonisolated static let transitions: [Transition] = {
        var rows: [Transition] = []

        // Horizontal: column ±1, clamped to 0..<5, row always preserved.
        // Left from column 0 (indices 0, 5) and Right from column 4
        // (indices 4, 9) are no-ops.
        let horizontal: [Int: (left: Int, right: Int)] = [
            0: (0, 1), 1: (0, 2), 2: (1, 3), 3: (2, 4), 4: (3, 4),
            5: (5, 6), 6: (5, 7), 7: (6, 8), 8: (7, 9), 9: (8, 9),
        ]
        for (index, expectation) in horizontal.sorted(by: { $0.key < $1.key }) {
            rows.append(Transition(start: .swatch(index), direction: .left, expected: .swatch(expectation.left)))
            rows.append(Transition(start: .swatch(index), direction: .right, expected: .swatch(expectation.right)))
        }
        rows.append(Transition(start: .automatic, direction: .left, expected: .automatic))
        rows.append(Transition(start: .automatic, direction: .right, expected: .automatic))

        // Vertical: row 0 (0-4) Up is a no-op; row 1 (5-9) Up goes to the
        // same column in row 0. Row 0 Down goes to the same column in row
        // 1; row 1 Down goes to Automatic.
        let vertical: [Int: (up: Int, down: Int)] = [
            0: (0, 5), 1: (1, 6), 2: (2, 7), 3: (3, 8), 4: (4, 9),
        ]
        for (index, expectation) in vertical.sorted(by: { $0.key < $1.key }) {
            rows.append(Transition(start: .swatch(index), direction: .up, expected: .swatch(expectation.up)))
            rows.append(Transition(start: .swatch(index), direction: .down, expected: .swatch(expectation.down)))
        }
        for index in 5...9 {
            rows.append(Transition(start: .swatch(index), direction: .up, expected: .swatch(index - 5)))
            rows.append(Transition(start: .swatch(index), direction: .down, expected: .automatic))
        }

        // From Automatic: Up goes to index 5; Down/Left/Right (Left/Right
        // already covered above) are no-ops.
        rows.append(Transition(start: .automatic, direction: .up, expected: .swatch(5)))
        rows.append(Transition(start: .automatic, direction: .down, expected: .automatic))

        return rows
    }()

    private func move(_ cursor: SessionColorGridCursor, _ direction: Direction) -> SessionColorGridCursor {
        switch direction {
        case .left: cursor.moved(dx: -1)
        case .right: cursor.moved(dx: 1)
        case .up: cursor.moved(dy: -1)
        case .down: cursor.moved(dy: 1)
        }
    }

    @Test func allFortyFourTransitionsAreCovered() {
        #expect(Self.transitions.count == 44)
    }

    @Test(arguments: SessionColorGridCursorTests.transitions)
    func gridCursorTransition(_ transition: Transition) {
        let result = move(SessionColorGridCursor(transition.start), transition.direction)
        #expect(result.position == transition.expected)
    }

    // MARK: - Direct regression checks for the round-1 bug

    /// Round-1's modulo-11 implementation sent Down from index 9 to index
    /// 3 (`(9 + 5) % 11 == 3`) instead of Automatic. This is the case the
    /// reviewer cited as "the clearest" example of the column drift.
    @Test func downFromLastSwatchRowGoesToAutomatic() {
        let result = SessionColorGridCursor(.swatch(9)).moved(dy: 1)
        #expect(result.position == .automatic)
    }

    /// Round-1's modulo-11 implementation sent Up from index 0 to index 6
    /// (`(0 - 5 + 11) % 11 == 6`) instead of staying put — row 0 has
    /// nothing above it.
    @Test func upFromTopRowIsANoOp() {
        let result = SessionColorGridCursor(.swatch(0)).moved(dy: -1)
        #expect(result.position == .swatch(0))
    }

    @Test func upFromAutomaticGoesToIndexFive() {
        let result = SessionColorGridCursor(.automatic).moved(dy: -1)
        #expect(result.position == .swatch(5))
    }

    @Test func leftAndRightAtRowEdgesAreNoOps() {
        #expect(SessionColorGridCursor(.swatch(0)).moved(dx: -1).position == .swatch(0))
        #expect(SessionColorGridCursor(.swatch(4)).moved(dx: 1).position == .swatch(4))
        #expect(SessionColorGridCursor(.swatch(5)).moved(dx: -1).position == .swatch(5))
        #expect(SessionColorGridCursor(.swatch(9)).moved(dx: 1).position == .swatch(9))
    }
}
