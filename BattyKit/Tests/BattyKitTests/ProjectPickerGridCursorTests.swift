// ProjectPickerGridCursorTests.swift

import Testing
@testable import BattyKit

struct ProjectPickerGridCursorTests {
    private typealias Section = ProjectPickerGridCursor.Section

    private let twoTier = ProjectPickerGridCursor(sections: [Section(columns: 3, count: 3), Section(columns: 4, count: 6)])
    private let fewer = ProjectPickerGridCursor(sections: [Section(columns: 3, count: 2)])
    private let filtered = ProjectPickerGridCursor(sections: [Section(columns: 4, count: 5)])

    private func moves(_ cursor: ProjectPickerGridCursor, _ direction: ProjectPickerDirection) -> [Int] {
        (0..<cursor.total).map { cursor.moved(from: $0, direction) }
    }

    @Test func mappedColumnTables() {
        #expect((0..<3).map { ProjectPickerGridCursor.mappedColumn($0, from: 3, to: 4) } == [0, 2, 3])
        #expect((0..<4).map { ProjectPickerGridCursor.mappedColumn($0, from: 4, to: 3) } == [0, 1, 1, 2])
    }

    @Test func twoTierLeftAndRightCrossTheBoundaryAndClamp() {
        #expect(moves(twoTier, .left) == [0, 0, 1, 2, 3, 4, 5, 6, 7])
        #expect(moves(twoTier, .right) == [1, 2, 3, 4, 5, 6, 7, 8, 8])
    }

    @Test func twoTierHomeAndEndFromEveryCell() {
        #expect(moves(twoTier, .home) == Array(repeating: 0, count: 9))
        #expect(moves(twoTier, .end) == Array(repeating: 8, count: 9))
    }

    @Test func twoTierDown() {
        // Featured 0,1,2 -> compact columns 0,2,3 (indexes 3,5,6); compact row 0 -> row 1
        // (indexes 7,8 exist; columns 2 and 3 are short and land on the last card, 8); row 1 stays.
        #expect(moves(twoTier, .down) == [3, 5, 6, 7, 8, 8, 8, 7, 8])
    }

    @Test func twoTierUp() {
        // Compact row 0 columns 0,1,2,3 -> featured columns 0,1,1,2; compact row 1 -> row 0; featured row stays.
        #expect(moves(twoTier, .up) == [0, 1, 2, 0, 1, 1, 2, 3, 4])
    }

    @Test func fewerThanThreeFixture() {
        #expect(moves(fewer, .left) == [0, 0])
        #expect(moves(fewer, .right) == [1, 1])
        #expect(moves(fewer, .up) == [0, 1])
        #expect(moves(fewer, .down) == [0, 1])
        #expect(moves(fewer, .home) == [0, 0])
        #expect(moves(fewer, .end) == [1, 1])
    }

    @Test func filteredFixtureShortLastRow() {
        #expect(moves(filtered, .down) == [4, 4, 4, 4, 4])
        #expect(moves(filtered, .up) == [0, 1, 2, 3, 0])
        #expect(moves(filtered, .left) == [0, 0, 1, 2, 3])
        #expect(moves(filtered, .right) == [1, 2, 3, 4, 4])
        #expect(moves(filtered, .home) == Array(repeating: 0, count: 5))
        #expect(moves(filtered, .end) == Array(repeating: 4, count: 5))
    }

    @Test func downFromAFullRowIntoAShortLastRowLandsOnTheLastCard() {
        let cursor = ProjectPickerGridCursor(sections: [Section(columns: 4, count: 6)])
        #expect(cursor.moved(from: 3, .down) == 5)
        #expect(cursor.moved(from: 2, .down) == 5)
        #expect(cursor.moved(from: 1, .down) == 5)
    }

    @Test func crossingDownClampsToTheCardsInTheNextFirstRow() {
        let cursor = ProjectPickerGridCursor(sections: [Section(columns: 3, count: 3), Section(columns: 4, count: 2)])
        #expect((0..<5).map { cursor.moved(from: $0, .down) } == [3, 4, 4, 3, 4])
    }

    @Test func crossingUpClampsToTheCardsInThePreviousLastRow() {
        let cursor = ProjectPickerGridCursor(sections: [Section(columns: 3, count: 2), Section(columns: 4, count: 4)])
        #expect(cursor.moved(from: 5, .up) == 1, "compact column 3 maps to column 2, which a two-card row lacks")
        #expect(cursor.moved(from: 4, .up) == 1)
        #expect(cursor.moved(from: 3, .up) == 1)
        #expect(cursor.moved(from: 2, .up) == 0)
    }

    @Test func emptySectionsLeaveTheIndexUnchanged() {
        let empty = ProjectPickerGridCursor(sections: [])
        let zeroCount = ProjectPickerGridCursor(sections: [Section(columns: 3, count: 0), Section(columns: 4, count: 0)])
        for direction in [ProjectPickerDirection.left, .right, .up, .down, .home, .end] {
            #expect(empty.moved(from: 7, direction) == 7)
            #expect(zeroCount.moved(from: 2, direction) == 2)
        }
    }

    @Test func anEmptyLeadingSectionIsSkipped() {
        let cursor = ProjectPickerGridCursor(sections: [Section(columns: 3, count: 0), Section(columns: 4, count: 5)])
        #expect(cursor.moved(from: 1, .down) == 4)
        #expect(cursor.moved(from: 1, .up) == 1)
    }
}
