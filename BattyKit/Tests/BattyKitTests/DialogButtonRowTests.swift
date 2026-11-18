// DialogButtonRowTests.swift

import Testing
@testable import BattyKit

@Suite struct DialogButtonRowLayoutTests {
    private typealias Placement = DialogButtonRowLayout.Placement

    @Test func orderIsAlternativeThenCancelThenConfirm() {
        let placements = DialogButtonRowLayout.placements(
            hasAlternative: true, hasCancel: true, hasConfirm: true, confirmIsDefault: true
        )
        #expect(placements.map(\.slot) == [.alternative, .cancel, .confirm])
    }

    @Test func cancelCarriesCancelActionAndConfirmCarriesDefaultAction() {
        let placements = DialogButtonRowLayout.placements(
            hasAlternative: false, hasCancel: true, hasConfirm: true, confirmIsDefault: true
        )
        #expect(placements == [
            Placement(slot: .cancel, key: .cancelAction),
            Placement(slot: .confirm, key: .defaultAction),
        ])
    }

    @Test func confirmThatIsNotDefaultCarriesNoShortcut() {
        let placements = DialogButtonRowLayout.placements(
            hasAlternative: true, hasCancel: true, hasConfirm: true, confirmIsDefault: false
        )
        #expect(placements.last == Placement(slot: .confirm, key: .none))
        #expect(!placements.contains { $0.key == .defaultAction })
        #expect(placements.contains(Placement(slot: .cancel, key: .cancelAction)))
    }

    @Test func alternativeNeverCarriesAShortcut() {
        for confirmIsDefault in [true, false] {
            for hasCancel in [true, false] {
                for hasConfirm in [true, false] {
                    let placements = DialogButtonRowLayout.placements(
                        hasAlternative: true,
                        hasCancel: hasCancel,
                        hasConfirm: hasConfirm,
                        confirmIsDefault: confirmIsDefault
                    )
                    #expect(placements.first == Placement(slot: .alternative, key: .none))
                }
            }
        }
    }

    @Test func absentSlotsAreSkippedWithoutReordering() {
        #expect(
            DialogButtonRowLayout.placements(
                hasAlternative: true, hasCancel: false, hasConfirm: true, confirmIsDefault: true
            ) == [Placement(slot: .alternative, key: .none), Placement(slot: .confirm, key: .defaultAction)]
        )
        #expect(
            DialogButtonRowLayout.placements(
                hasAlternative: false, hasCancel: true, hasConfirm: false, confirmIsDefault: true
            ) == [Placement(slot: .cancel, key: .cancelAction)]
        )
        #expect(
            DialogButtonRowLayout.placements(
                hasAlternative: false, hasCancel: false, hasConfirm: false, confirmIsDefault: true
            ).isEmpty
        )
    }
}
