// LMStudioCompletionTable.swift

import AppKit
import SwiftUI

enum LMStudioCompletionColumns: CaseIterable {
    case full, noContext, minimal, noTime, modelAndBadge
}

/// Live Requests rows as a column-aligned `Grid`. The model column is capped
/// at `modelColumnMaxWidth` so the grid is intrinsically sized and the stats
/// sit directly after it at wide Pane widths. `ViewThatFits` walks the
/// layouts from richest to leanest, dropping whole columns; the last one
/// (model + badge) always fits the minimum Pane width.
struct LMStudioCompletionTable: View {
    static let modelColumnMaxWidth: CGFloat = 240

    let records: [LMStudioCompletionRecord]
    var forcedColumns: LMStudioCompletionColumns?

    var body: some View {
        if let forcedColumns {
            grid(forcedColumns)
        } else {
            ViewThatFits(in: .horizontal) {
                grid(.full)
                grid(.noContext)
                grid(.minimal)
                grid(.noTime)
                grid(.modelAndBadge)
            }
        }
    }

    private func grid(_ columns: LMStudioCompletionColumns) -> some View {
        let showTime = columns != .noTime && columns != .modelAndBadge
        let showTokens = columns != .modelAndBadge
        let showTTFT = columns == .full
        let showContext = columns == .full || columns == .noContext
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            ForEach(records) { record in
                GridRow {
                    if showTime {
                        Text(record.completedAt, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Text(record.modelIdentifier)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 40, idealWidth: 100, maxWidth: Self.modelColumnMaxWidth, alignment: .leading)
                        .gridColumnAlignment(.leading)
                    if showTokens {
                        Text(record.stats?.tokensPerSecond.map { String(format: "%.0f tok/s", $0) } ?? "")
                            .font(.caption.monospacedDigit())
                            .lineLimit(1)
                            .fixedSize()
                            .gridColumnAlignment(.trailing)
                    }
                    if showTTFT {
                        Text(record.stats?.timeToFirstTokenSec.map { String(format: "TTFT %.2fs", $0) } ?? "")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .gridColumnAlignment(.trailing)
                    }
                    stopReasonBadge(record.stats?.stopReason)
                    if showContext {
                        Text(record.contextPressure.map { "\(Int($0 * 100))% ctx" } ?? "")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle((record.contextPressure ?? 0) > 0.9 ? .red : .secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .gridColumnAlignment(.trailing)
                    }
                }
                .contextMenu {
                    Button("Copy Model Identifier") {
                        copyToPasteboard(record.modelIdentifier)
                    }
                    Button("Copy Stats as JSON") {
                        copyToPasteboard(statsJSON(record.stats))
                    }
                }
                .accessibilityIdentifier("lmstudio-completion-row.\(record.id.uuidString)")
            }
        }
    }

    @ViewBuilder
    private func stopReasonBadge(_ stopReason: String?) -> some View {
        if let stopReason {
            StatusBadge(text: LMStudioDashboardFormatting.stopReasonDisplayName(stopReason), color: .secondary)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func statsJSON(_ stats: LMStudioPredictionStats?) -> String {
        guard let stats,
              let data = try? JSONEncoder().encode(stats),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
