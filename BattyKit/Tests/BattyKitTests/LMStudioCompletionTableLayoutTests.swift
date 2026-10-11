// LMStudioCompletionTableLayoutTests.swift

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BattyKit

@MainActor
struct LMStudioCompletionTableLayoutTests {
    /// #0457's stated content-fit minimum Pane width (220) minus the view's 12-point padding on each side.
    static let budget: CGFloat = 196

    private func record(model: String, stop: String) -> LMStudioCompletionRecord {
        LMStudioCompletionRecord(
            id: UUID(),
            completedAt: Date(),
            modelIdentifier: model,
            stats: LMStudioPredictionStats(
                stopReason: stop, tokensPerSecond: 133, timeToFirstTokenSec: 0.22,
                totalTimeSec: nil, promptTokensCount: nil, predictedTokensCount: nil, totalTokensCount: nil
            ),
            contextPressure: 0.5
        )
    }

    private func floorWidth(_ columns: LMStudioCompletionColumns, records: [LMStudioCompletionRecord]) -> CGFloat {
        let host = NSHostingController(rootView: LMStudioCompletionTable(records: records, forcedColumns: columns))
        return host.sizeThatFits(in: CGSize(width: 1, height: 1000)).width
    }

    @Test func leanestLayoutFitsTheNarrowestPaneEvenWithTheLongestBadge() {
        let records = [
            record(model: "ornith-1.5-35b-a3b-mlx-4bit-long-name", stop: "contextLengthReached"),
            record(model: "m", stop: "maxPredictedTokensReached"),
        ]
        #expect(floorWidth(.modelAndBadge, records: records) <= Self.budget)
    }

    @Test func fullLayoutDoesNotStretchToAWideProposal() {
        let records = [record(model: "ornith-1.5-35b-a3b-mlx", stop: "eosFound")]
        let host = NSHostingController(rootView: LMStudioCompletionTable(records: records, forcedColumns: .full))
        let wide = host.sizeThatFits(in: CGSize(width: 1000, height: 1000)).width
        // The width fitted to a 1-point proposal is the fixed columns plus the model column's 40-point minimum;
        // swapping that minimum for the cap gives the widest the table may be.
        let bound = floorWidth(.full, records: records) - 40 + LMStudioCompletionTable.modelColumnMaxWidth
        #expect(wide <= bound + 1)
        #expect(wide < 1000)
    }
}
