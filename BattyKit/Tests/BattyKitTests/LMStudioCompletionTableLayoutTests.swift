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
}
